import AppKit
import SwiftUI
import WebKit

#if ODICT_CHECKS
/// Weak probes are compiled only into the isolated validation app, never Release.
enum LocalRendererDiagnostics {
    final class Reference {
        weak var view: WKWebView?
        init(_ view: WKWebView) { self.view = view }
    }
    private static var views: [Reference] = []
    static func track(_ view: WKWebView) {
        views.removeAll { $0.view == nil }
        views.append(Reference(view))
    }
    static var liveCount: Int { views.filter { $0.view != nil }.count }
}
#endif

/// Local presentation has its own lifecycle. It never consumes or mutates Entry,
/// and never rewrites dictionary-specific tags, classes, or definition content.
struct LocalArticleView: View {
    let article: LocalArticle
    let lookup: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("来源：\(article.dictionary.name) · 本地")
                if !article.correspondingHeadwords.isEmpty {
                    Text("\(article.word) → \(article.correspondingHeadwords.joined(separator: "、"))（词典对应词条）")
                }
            }
            .font(.system(size: 11)).foregroundColor(.secondary)
            .textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 8)
            LocalArticleWebView(article: article, lookup: lookup).id(article.id)
        }
    }
}

private struct LocalArticleWebView: NSViewRepresentable {
    let article: LocalArticle
    let lookup: (String) -> Void
    func makeCoordinator() -> LocalWebCoordinator { LocalWebCoordinator(article: article, lookup: lookup) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: LocalWebCoordinator.scheme)
        // Generic attachment points only. Styling and optional behavior are authored
        // in files beside the dictionary, not dictionary-specific Swift adaptations.
        let script = """
        (() => {
          const css = document.createElement('link');
          css.rel = 'stylesheet'; css.href = '/odict-overrides.css';
          (document.head || document.documentElement).appendChild(css);
          const js = document.createElement('script'); js.src = '/odict-overrides.js';
          (document.body || document.documentElement).appendChild(js);
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        #if ODICT_CHECKS
        LocalRendererDiagnostics.track(view)
        #endif
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: context.coordinator.pageURL))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: LocalWebCoordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeAllUserScripts()
        coordinator.cancelAll()
    }
}

private final class LocalWebCoordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    static let scheme = "odict-local"
    let article: LocalArticle
    let lookup: (String) -> Void
    let pageURL: URL
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var audio: NSSound?
    private var audioTask: Task<Void, Never>?

    init(article: LocalArticle, lookup: @escaping (String) -> Void) {
        self.article = article; self.lookup = lookup
        pageURL = URL(string: "\(Self.scheme)://\(article.dictionary.id.uuidString.lowercased())/__odict_article.html")!
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let url = urlSchemeTask.request.url, url.host == pageURL.host else {
            urlSchemeTask.didFailWithError(LocalDictionaryError.missingResource); return
        }
        let article = article
        requests[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.requests[id] = nil }
            do {
                let data: Data, mime: String
                if url.path == self.pageURL.path {
                    // A transport document supplies resource isolation. The dictionary's
                    // HTML itself passes through unchanged, with no per-dictionary parsing.
                    let policy = "default-src 'none'; img-src \(Self.scheme): data:; style-src \(Self.scheme): 'unsafe-inline'; font-src \(Self.scheme): data:; script-src \(Self.scheme): 'unsafe-inline'; media-src \(Self.scheme): data:; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
                    let document = "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"></head><body>" + article.html + "</body></html>"
                    data = Data(document.utf8); mime = "text/html"
                } else {
                    data = try await LocalDictionaryLibrary.shared.resource(url.path, in: article.dictionary)
                    mime = Self.mime(url.pathExtension)
                }
                try Task.checkCancellation()
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                    textEncodingName: mime.hasPrefix("text/") || mime == "application/javascript" ? "utf-8" : nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch is CancellationError { /* WebKit has already stopped this request. */ }
            catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
    }
    func cancelAll() {
        requests.values.forEach { $0.cancel() }; requests.removeAll()
        audioTask?.cancel(); audioTask = nil; audio?.stop(); audio = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == Self.scheme, url.host == pageURL.host, navigationAction.targetFrame?.isMainFrame == true {
            // Same-page anchors are allowed; other local HTML stays within this renderer.
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        guard navigationAction.navigationType == .linkActivated else { return }
        switch url.scheme?.lowercased() {
        case "entry", "bword", "gdlookup":
            let word = Self.target(url).components(separatedBy: "#")[0]
            if !word.isEmpty, word.count <= 255 { lookup(word) }
        case "sound": play(Self.target(url))
        case "https", "http": NSWorkspace.shared.open(url)
        default: break
        }
    }
    private static func target(_ url: URL) -> String {
        let value = url.absoluteString
        let raw = value.components(separatedBy: "://").dropFirst().joined(separator: "://")
        return raw.removingPercentEncoding ?? raw
    }
    private func play(_ path: String) {
        audioTask?.cancel(); audio?.stop(); audio = nil
        let dictionary = article.dictionary
        audioTask = Task { @MainActor [weak self] in
            guard let data = try? await LocalDictionaryLibrary.shared.resource(path, in: dictionary), !Task.isCancelled else { return }
            self?.audio = NSSound(data: data)
            self?.audio?.play()
        }
    }
    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "html", "htm": return "text/html"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
