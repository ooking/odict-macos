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
    let renderer: LocalArticleRenderer
    let lookup: (String) -> Void
    var body: some View {
        LocalArticleWebView(article: article, renderer: renderer, lookup: lookup)
    }
}

/// One renderer per lookup window, retained across the temporary empty/loading view.
/// The window releases it when hidden; there is no global WebView pool.
final class LocalArticleRenderer: ObservableObject {
    fileprivate var view: WKWebView?
    fileprivate var coordinator: LocalWebCoordinator?

    fileprivate func acquire(article: LocalArticle, lookup: @escaping (String) -> Void) -> WKWebView {
        if let view, let coordinator {
            coordinator.update(view, article: article, lookup: lookup)
            return view
        }
        let coordinator = LocalWebCoordinator()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator, forURLScheme: LocalWebCoordinator.scheme)
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
        view.navigationDelegate = coordinator
        view.setValue(false, forKey: "drawsBackground")
        self.view = view
        self.coordinator = coordinator
        coordinator.update(view, article: article, lookup: lookup)
        return view
    }

    func release() {
        guard let view else { return }
        coordinator?.clear(view, unloadDocument: false)
        view.navigationDelegate = nil
        view.configuration.userContentController.removeAllUserScripts()
        self.view = nil
        coordinator = nil
    }
}

private struct LocalArticleWebView: NSViewRepresentable {
    let article: LocalArticle
    let renderer: LocalArticleRenderer
    let lookup: (String) -> Void
    func makeCoordinator() -> LocalArticleRenderer { renderer }
    func makeNSView(context: Context) -> WKWebView {
        renderer.acquire(article: article, lookup: lookup)
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        _ = renderer.acquire(article: article, lookup: lookup)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: LocalArticleRenderer) {
        // Drop the document and audio during loading, but keep the engine reusable.
        // A hide may have already released this renderer before SwiftUI dismantles it.
        if coordinator.view === view { coordinator.coordinator?.clear(view) }
    }
}

fileprivate final class LocalWebCoordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    static let scheme = "odict-local"
    private var article: LocalArticle?
    private var lookup: ((String) -> Void)?
    private var pageURL: URL?
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var audio: NSSound?
    private var audioTask: Task<Void, Never>?

    func update(_ view: WKWebView, article: LocalArticle, lookup: @escaping (String) -> Void) {
        self.lookup = lookup
        guard self.article?.id != article.id else { return }
        view.stopLoading()
        cancelAll()
        self.article = article
        // A fresh origin for every document rejects late requests from old pages,
        // even when two consecutive entries come from the same dictionary.
        let url = URL(string: "\(Self.scheme)://\(article.id.uuidString.lowercased())/__odict_article.html")!
        pageURL = url
        view.load(URLRequest(url: url))
    }

    func clear(_ view: WKWebView, unloadDocument: Bool = true) {
        view.stopLoading()
        cancelAll()
        article = nil
        lookup = nil
        pageURL = nil
        if unloadDocument { view.loadHTMLString("", baseURL: nil) }
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let article, let pageURL, let url = urlSchemeTask.request.url,
              url.host == pageURL.host else {
            urlSchemeTask.didFailWithError(LocalDictionaryError.missingResource); return
        }
        requests[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.requests[id] = nil }
            do {
                let data: Data, mime: String
                if url.path == pageURL.path {
                    // A transport document supplies resource isolation. The dictionary's
                    // HTML itself passes through unchanged, with no per-dictionary parsing.
                    let policy = "default-src 'none'; img-src \(Self.scheme): data:; style-src \(Self.scheme): 'unsafe-inline'; font-src \(Self.scheme): data:; script-src \(Self.scheme): 'unsafe-inline'; media-src \(Self.scheme): data:; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
                    // A low-priority native reading baseline. Dictionary styles and
                    // user overrides retain control over specialized typography.
                    let typography = "<style>:where(body) { font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'PingFang SC', sans-serif; font-size: 15px; line-height: 1.6; }</style>"
                    let document = "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + typography + "</head><body>" + article.html + Self.sourceFooter(article) + "</body></html>"
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
        if url.absoluteString == "about:blank", navigationAction.navigationType == .other {
            decisionHandler(.allow); return
        }
        guard let pageURL else { decisionHandler(.cancel); return }
        if url.scheme == Self.scheme, url.host == pageURL.host, navigationAction.targetFrame?.isMainFrame == true {
            // Same-page anchors are allowed; other local HTML stays within this renderer.
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        if let source = navigationAction.sourceFrame.request.url,
           source.scheme == Self.scheme, source.host != pageURL.host { return }
        guard navigationAction.navigationType == .linkActivated else { return }
        switch url.scheme?.lowercased() {
        case "entry", "bword", "gdlookup":
            let word = Self.target(url).components(separatedBy: "#")[0]
            if !word.isEmpty, word.count <= 255 { lookup?(word) }
        case "sound": play(Self.target(url))
        case "https", "http": NSWorkspace.shared.open(url)
        default: break
        }
    }
    /// Transport metadata follows all dictionary content and scrolls with it.
    private static func sourceFooter(_ article: LocalArticle) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        var lines = ["来源：\(article.dictionary.name) · 本地"]
        if !article.correspondingHeadwords.isEmpty {
            lines.append("\(article.word) → \(article.correspondingHeadwords.joined(separator: "、"))（词典对应词条）")
        }
        let content = lines.map { "<div>\(escape($0))</div>" }.joined()
        return "<footer id=\"odict-source-footer\" style=\"display:block;clear:both;margin-top:24px;padding:12px 0 4px;border-top:1px solid var(--odict-rule,rgba(128,128,128,.25));font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:12px;line-height:1.6;font-weight:400;color:var(--odict-secondary,GrayText);overflow-wrap:anywhere;\">" + content + "</footer>"
    }

    private static func target(_ url: URL) -> String {
        let value = url.absoluteString
        let raw = value.components(separatedBy: "://").dropFirst().joined(separator: "://")
        return raw.removingPercentEncoding ?? raw
    }
    private func play(_ path: String) {
        audioTask?.cancel(); audio?.stop(); audio = nil
        guard let dictionary = article?.dictionary else { return }
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
