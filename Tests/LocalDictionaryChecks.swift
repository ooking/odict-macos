import Foundation
import AppKit
import zlib

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "LocalDictionaryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private final class FakeOnline: DictionaryServing {
    var entries = 0, candidates = 0, searches = 0
    func entry(_ word: String) async throws -> Entry {
        entries += 1
        return Entry(id: 1, word: word, phonetic: nil, definition: "fixture", translation: "模拟在线释义", tags: [], partsOfSpeech: [], inflections: [])
    }
    func suggestions(_ query: String) async throws -> [Suggestion] { candidates += 1; return [] }
    func search(_ query: String, translation: Bool) async throws -> [Suggestion] { searches += 1; return [] }
}

/// Small independently written MDX fixtures exercise block boundaries and routing
/// without relying on the user's dictionary contents or production preferences.
private enum Fixture {
    static func number(_ n: UInt64, _ count: Int = 8) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: n >> (8 * $0)) })
    }
    static func compressed(_ data: Data) -> Data {
        var size = compressBound(uLong(data.count)), encoded = Data(count: Int(compressBound(uLong(data.count))))
        let status = encoded.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compress2(output.bindMemory(to: Bytef.self).baseAddress!, &size, input.bindMemory(to: Bytef.self).baseAddress!, uLong(data.count), 6)
            }
        }
        precondition(status == Z_OK)
        return Data([2,0,0,0]) + number(UInt64(MDXCompression.checksum(data)), 4) + encoded.prefix(Int(size))
    }
    static func write(_ records: [(String, String)], to url: URL) throws {
        let xml = "<Dictionary GeneratedByEngineVersion=\"2.0\" Encoding=\"UTF-8\" Encrypted=\"0\" KeyCaseSensitive=\"No\" StripKey=\"No\" Title=\"Fixture\"/>\0"
        let header = xml.data(using: .utf16LittleEndian)!
        var bytes = number(UInt64(header.count), 4) + header
        var checksum = MDXCompression.checksum(header).littleEndian
        bytes += withUnsafeBytes(of: &checksum) { Data($0) }
        var body = Data(), keys = Data()
        for (word, html) in records {
            keys += number(UInt64(body.count)) + Data(word.utf8) + Data([0])
            body += Data(html.utf8) + Data([0])
        }
        let keyData = compressed(keys)
        let first = Data(records.first!.0.utf8), last = Data(records.last!.0.utf8)
        let info = number(UInt64(records.count)) + number(UInt64(first.count),2) + first + Data([0])
            + number(UInt64(last.count),2) + last + Data([0]) + number(UInt64(keyData.count)) + number(UInt64(keys.count))
        let infoData = compressed(info)
        let keyHeader = number(1) + number(UInt64(records.count)) + number(UInt64(info.count))
            + number(UInt64(infoData.count)) + number(UInt64(keyData.count))
        bytes += keyHeader + number(UInt64(MDXCompression.checksum(keyHeader)),4) + infoData + keyData
        // Deliberately divide a definition across two compressed record blocks.
        let mid = max(1,body.count/2)
        let parts = [Data(body.prefix(mid)),Data(body.dropFirst(mid))]
        let blocks = parts.map(compressed)
        bytes += number(2) + number(UInt64(records.count)) + number(32) + number(UInt64(blocks.reduce(0){$0+$1.count}))
        for i in 0..<2 { bytes += number(UInt64(blocks[i].count)) + number(UInt64(parts[i].count)) }
        for block in blocks { bytes += block }
        try bytes.write(to:url)
    }
}

@main private struct LocalDictionaryChecks {
    static func main() async {
        do { try await run(); print("PASS: local dictionary checks") }
        catch { print("FAIL:",error.localizedDescription); exit(1) }
    }
    static func run() async throws {
        try LocalArticleDocumentChecks.run()
        let oxford = """
        <div class="def-g"><span class="oalecd8e_chn">进化</span></div>
        <div class="x-g"><span class="oalecd8e_chn">不应收录的例句</span></div>
        <div class="ids-g"><span class="def-g"><span class="oalecd8e_chn">不应收录的习语</span></span></div>
        <div class="def-g"><span class="oalecd8e_chn">发展</span></div>
        <div class="def-g"><span class="oalecd8e_chn">进化</span></div>
        """
        try require(LocalArticleSummary.extract(from: oxford) == "进化；发展", "Oxford history meanings without examples")
        let longman = """
        <div class="example"><span class="def"><tran>例句译文</tran></span></div>
        <span class="sense"><span class="lexunit">a phrase</span><span class="def"><TRAN>短语释义</TRAN></span></span>
        <span class="def"><en>change</en><tran>变化 &amp; <b>发展</b></tran></span>
        """
        let longmanSummary = LocalArticleSummary.extract(from: longman)
        try require(longmanSummary == "变化 & 发展", "Longman nested text and entities: \(longmanSummary ?? "nil")")
        let bing = """
        <div class="bdy" id="ecdict"><div class="ctn">
          <div class="hwd">hello</div><div class="frq">考试词频</div>
          <div class="gdc">
            <div class="dcb"><span class="dnt">[网络]</span><span class="dne">网络译文</span></div>
            <div class="dcb"><span class="pos">n.</span><span class="dcn">表示问候， 惊奇或唤起注意时的用语</span></div>
            <div class="dcb"><span class="deq">不应收录的中文例句</span></div>
            <div class="dcb"><span class="pos">int.</span><span class="dcn">喂；<b>哈罗</b></span></div>
            <div class="dcb"><span class="dcn">人名</span></div>
          </div>
        </div></div>
        """
        try require(LocalArticleSummary.extract(from: bing) == "表示问候， 惊奇或唤起注意时的用语；喂；哈罗",
                    "Concise Bing prefers two ordinary meanings over network meanings and examples")
        let bingNetwork = """
        <div id="ecdict"><div class="gdc">
          <div class="dcb"><span class="dcn">English only</span><span class="deq"><span class="dcn">中文例句</span></span></div>
          <div class="dcb"><span class="dnt">[网络]</span><span class="dne">第44号</span></div>
        </div></div>
        """
        try require(LocalArticleSummary.extract(from: bingNetwork) == "第44号", "Concise Bing Chinese network fallback")
        try require(LocalArticleSummary.extract(from: "<div id='ecdict'><div class='gdc'><div class='dcb'><span class='dcn'>English only</span><span class='deq'>中文例句</span></div></div></div>") == nil,
                    "Concise Bing does not use examples as Chinese meanings")
        try require(LocalArticleSummary.extract(from: "<div class='gdc'><div class='dcb'><span class='dcn'>无关内容</span></div></div><div id='ecdict'><span class='dcn'>非释义区域</span></div>") == nil,
                    "Concise Bing markers require dictionary and definition ancestors")
        try require(LocalArticleSummary.extract(from: "<nav>词典导航</nav><p>中文例句</p>") == nil, "No arbitrary Chinese fallback")
        try require(LocalArticleSummary.extract(from: "<span class='def'><tran>English only</tran></span>") == nil, "No invented Chinese summary")
        try require(LocalArticleSummary.extract(from: String(repeating: "x", count: 512 * 1024 + 1)) == nil, "Summary input bound")
        try require(LocalArticleSummary.extract(from: "<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/hosts'>]><x>&x;</x>") == nil, "Reject entity declarations")
        let vectors = [("","cdf26213a150dc3ecb610f18f6b38b46"),("a","86be7afa339d0fc7cfc785e72f578d33"),("abc","c14a12199c66e4ba84636b0f69144c77")]
        for (input, expected) in vectors {
            let value = RIPEMD128.digest(Data(input.utf8)).map { String(format:"%02x",$0) }.joined()
            try require(value == expected,"RIPEMD-128 known vector")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ODictChecks-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let firstPath = folder.appendingPathComponent("first.mdx"), secondPath = folder.appendingPathComponent("second.mdx")
        try Fixture.write([("apple","<p>first</p>"),("apply","<p>apply</p>"),("cycle","@@@LINK=cycle"),("redirect","@@@LINK=apple")],to:firstPath)
        try Fixture.write([("app","<p>exact</p>"),("apple","<p>second</p>")],to:secondPath)
        let reader = try MDXReader(url:firstPath)
        let firstArticle = try reader.articles("APPLE")
        try require(firstArticle.first?.1 == "<p>first</p>","case-insensitive cross-block read")
        let redirect = try reader.articles("redirect")
        try require(redirect.first?.1 == "<p>first</p>","redirect target")
        let cycle = try reader.articles("cycle")
        try require(cycle.isEmpty,"redirect cycle terminates")
        let prefix = try reader.words("ap",prefix:true,limit:1)
        try require(prefix == ["apple"],"bounded prefix")
        let missing = try reader.articles("missing")
        try require(missing.isEmpty,"true miss")
        let defaultsName = "ODict.LocalChecks."+UUID().uuidString
        let defaults = UserDefaults(suiteName:defaultsName)!
        defer { defaults.removePersistentDomain(forName:defaultsName) }
        let store = LocalDictionaryStore(defaults:defaults)
        let first = LocalDictionaryConfiguration(id:UUID(),name:"first",mdxPath:firstPath.path,resources:[],enabled:true)
        let second = LocalDictionaryConfiguration(id:UUID(),name:"second",mdxPath:secondPath.path,resources:[],enabled:true)
        let fake = FakeOnline(), library = LocalDictionaryLibrary()
        let router = DictionaryRouter(remote:fake,local:library,store:store)
        try store.save([first,second],mode:.localFirst)
        var value = try await router.entry("apple")
        try require(value.local?.dictionary.id == first.id && fake.entries == 0,"first hit stops before online")
        let redirected = try await router.entry("redirect")
        try require(redirected.word == "redirect" && redirected.local?.headwords == ["apple"],
                    "redirect retains selected word separately from terminal headword")
        try store.save([second,first],mode:.localFirst)
        value = try await router.entry("apple")
        try require(value.local?.dictionary.id == second.id,"order changes source")
        try store.save([first,second],mode:.localFirst)
        let exact = try await router.suggestions("app")
        try require(exact.first?.word == "app" && fake.candidates == 0,"later exact before earlier prefix")
        value = try await router.entry("zzzz-missing")
        try require(value.remote != nil && fake.entries == 1,"online fallback")
        var broken = first; broken = LocalDictionaryConfiguration(id:broken.id,name:broken.name,mdxPath:folder.appendingPathComponent("absent.mdx").path,resources:[],enabled:true)
        try store.save([second,broken],mode:.localFirst)
        value = try await router.entry("apple")
        try require(value.notice == nil,"does not access lower broken dictionary after hit")
        try store.save([broken,second],mode:.localFirst)
        value = try await router.entry("apple")
        try require(value.local?.dictionary.id == second.id && value.notice != nil,"unavailable source reported")
        try store.save([broken],mode:.onlineOnly)
        value = try await router.entry("apple")
        try require(value.remote != nil && value.notice == nil,"online-only skips local reader")
        let before = fake.searches
        _ = try await router.search("zzzz",translation:false)
        _ = try await router.search("中文",translation:true)
        try require(fake.searches == before+2,"preserve online search endpoint")
        try LocalDictionaryOverrides.create(in:folder)
        let css = folder.appendingPathComponent(LocalDictionaryOverrides.cssName)
        try "/* custom */".write(to:css,atomically:true,encoding:.utf8)
        try LocalDictionaryOverrides.create(in:folder)
        let cssText = try String(contentsOf:css,encoding:.utf8)
        try require(cssText == "/* custom */","do not overwrite custom CSS")
        try await expectMissing(library,"../private",in:first)
        let link = folder.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:FileManager.default.temporaryDirectory)
        try await expectMissing(library,"outside/some-file",in:first)
        let cancelled = Task { try Task.checkCancellation(); return try await library.article("apple",in:first) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw NSError(domain:"Checks",code:1,userInfo:[NSLocalizedDescriptionKey:"cancelled query succeeded"]) }
        catch is CancellationError {}
        await library.release()
        #if ODICT_CHECKS
        let retained = await library.readerCountForChecks()
        try require(retained == 0,"release reader/file-handle caches")
        #endif
        print("PASS: crypto vectors; cross-block; redirects; prefix cap; routing order/stop/fallback/online-only; unavailable sources; endpoint preservation; CSS ownership; path confinement; cancellation")
        if CommandLine.arguments.count > 1 { try await realDictionaries(root:URL(fileURLWithPath:CommandLine.arguments[1])) }
    }
    static func expectMissing(_ library: LocalDictionaryLibrary,_ path: String,in dictionary: LocalDictionaryConfiguration) async throws {
        do { _ = try await library.resource(path,in:dictionary); throw NSError(domain:"Checks",code:1,userInfo:[NSLocalizedDescriptionKey:"path escaped dictionary folder"]) }
        catch LocalDictionaryError.missingResource {}
    }
    static func realDictionaries(root:URL) async throws {
        let library = LocalDictionaryLibrary()
        let bing = try LocalDictionaryDiscovery.discover(root.appendingPathComponent("concise-bing"))[0]
        let bingMeanings: [(String, String?)] = [
            ("apple", "苹果，苹果树，苹果似的东西；[美俚]炸弹，手榴弹，（棒球的）球；[美俚]人，家伙。"),
            ("hello", "表示问候， 惊奇或唤起注意时的用语；喂；哈罗"),
            ("44th", "第44号"),
            ("Yoga Pants", nil)
        ]
        for (word, expected) in bingMeanings {
            let article = try await library.article(word, in: bing)
            try require(article != nil && article?.summary == expected, "real Concise Bing summary \(word)")
        }
        await library.release()
        let names = ["oxford-advanced-learner-dictionary-8","LDOCE6++.En-Cn.V3-0"]
        let words = ["hello","apple","computer","recording","run","running","test","what","book","world","learn","word","dictionary","language","good","time","people","work","life","day"]
        for name in names {
            let dictionary = try LocalDictionaryDiscovery.discover(root.appendingPathComponent(name))[0]
            for word in ["evolution", "apple", "computer"] {
                let article = try await library.article(word, in: dictionary)
                try require(article?.summary?.isEmpty == false, "real Chinese history summary \(name)/\(word)")
                if word == "apple" { try require(article?.summary == "苹果", "exclude idiom senses from real apple summary") }
                print("SUMMARY \(name)/\(word): \(article?.summary ?? "nil")")
            }
            await library.release()
            let start = Date()
            let hello = try await library.article("hello",in:dictionary)
            try require(hello?.html.contains("hello") == true,"real hello entry")
            let cold = Date().timeIntervalSince(start)*1000
            var timings: [Double] = []
            for _ in 0..<5 {
                for word in words {
                    let t = Date()
                    let article = try await library.article(word,in:dictionary)
                    try require(article?.html.isEmpty == false,"missing real word \(name)/\(word)")
                    timings.append(Date().timeIntervalSince(t)*1000)
                }
            }
            timings.sort()
            let paths = name.hasPrefix("oxford") ? ["oalecd8e.css","jquery.js","oalecd8e.js","uk_pron.png","uk/hello__gb_1.mp3"] : ["ldoce6ec.css","ldoce6ec.js","b.png","img/spkr_r.png","hwd/bre/7/hello0205.mp3"]
            for path in paths {
                let data = try await library.resource(path,in:dictionary)
                try require(!data.isEmpty,"empty real resource \(path)")
                if path.hasSuffix(".mp3") { try require(NSSound(data:data) != nil,"audio decoding") }
                if path.hasSuffix(".png") { try require(data.starts(with:[137,80,78,71]),"PNG signature") }
            }
            print(String(format:"REAL %@: cold %.2f ms, median %.2f ms, p95 %.2f ms (%d queries); %d resources",name,cold,timings[timings.count/2],timings[Int(Double(timings.count)*0.95)],timings.count,paths.count))
            let miss = try await library.article("zzzz_odict_missing_123",in:dictionary)
            try require(miss == nil,"real miss")
        }
        await library.release()
    }
}
