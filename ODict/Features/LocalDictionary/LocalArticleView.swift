import AppKit
import SwiftUI
import WebKit
import os

#if DEBUG
/// Logs actual object destruction without keeping a global registry or owning
/// the view from a diagnostic task. The production renderer stays WKWebView.
private final class ProfiledArticleWebView: WKWebView {
    private let memory = MemoryPhaseDiagnostics.Span("webview.lifetime")
    deinit { memory.mark("deinit") }
}
#endif

/// Local presentation has its own lifecycle. It never consumes or mutates Entry,
/// and preserves dictionary-specific tags, classes, and definition content.
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
        #if DEBUG
        let memory = MemoryPhaseDiagnostics.Span("webview.create")
        defer { memory.mark("finished") }
        #endif
        let coordinator = LocalWebCoordinator()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator, forURLScheme: LocalWebCoordinator.scheme)
        let view: WKWebView
        #if DEBUG
        view = ProfiledArticleWebView(frame: .zero, configuration: configuration)
        #else
        view = WKWebView(frame: .zero, configuration: configuration)
        #endif
        #if DEBUG
        LocalDictionaryDebug.trace("renderer.created", articleID: article.id)
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
        #if DEBUG
        let memory = MemoryPhaseDiagnostics.Span("webview.release")
        defer { memory.mark("finished") }
        LocalDictionaryDebug.trace("renderer.release")
        #endif
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
    static let scheme = LocalArticleDocument.scheme
    private static let log = Logger(subsystem: "com.touchany.odict.mac", category: "LocalArticle")
    private var article: LocalArticle?
    private var lookup: ((String) -> Void)?
    private var pageURL: URL?
    private var activeNavigation: WKNavigation?
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var audio: NSSound?
    private var audioTask: Task<Void, Never>?
    #if DEBUG
    private var renderingMemory: MemoryPhaseDiagnostics.Span?
    #endif

    func update(_ view: WKWebView, article: LocalArticle, lookup: @escaping (String) -> Void) {
        self.lookup = lookup
        guard self.article?.id != article.id else { return }
        #if DEBUG
        renderingMemory?.mark("superseded")
        renderingMemory = MemoryPhaseDiagnostics.Span("article.render")
        #endif
        // Hide the previous surface synchronously before starting another navigation.
        view.isHidden = true
        #if DEBUG
        LocalDictionaryDebug.trace("page.hidden.switch", articleID: article.id,
                                   "previous=\(self.article?.id.uuidString.lowercased() ?? "-")")
        #endif
        activeNavigation = nil
        view.stopLoading()
        cancelAll()
        self.article = article
        // A fresh origin for every document rejects late requests from old pages,
        // even when two consecutive entries come from the same dictionary.
        let url = URL(string: "\(Self.scheme)://\(article.id.uuidString.lowercased())/__odict_article.html")!
        pageURL = url
        activeNavigation = view.load(URLRequest(url: url))
        #if DEBUG
        LocalDictionaryDebug.trace("navigation.started", articleID: article.id)
        #endif
    }

    func clear(_ view: WKWebView, unloadDocument: Bool = true) {
        #if DEBUG
        renderingMemory?.mark("cleared")
        renderingMemory = nil
        LocalDictionaryDebug.trace("page.hidden.clear", articleID: article?.id, "unloadDocument=\(unloadDocument)")
        #endif
        // Hide the previous surface synchronously before starting another navigation.
        view.isHidden = true
        activeNavigation = nil
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
            #if DEBUG
            LocalDictionaryDebug.trace("resource.rejected.stale", "origin=\(urlSchemeTask.request.url?.host ?? "-")")
            #endif
            urlSchemeTask.didFailWithError(LocalDictionaryError.missingResource); return
        }
        #if DEBUG
        LocalDictionaryDebug.trace("resource.request", articleID: article.id, "path=\(String(reflecting: url.path))")
        #endif
        requests[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.requests[id] = nil
                #if DEBUG
                MemoryPhaseDiagnostics.snapshot("webview.resource.finished", pendingRequests: self.requests.count)
                #endif
            }
            do {
                let data: Data, mime: String
                if url.path == pageURL.path {
                    data = try await LocalDictionaryLibrary.shared.document(article)
                    mime = "text/html"
                } else {
                    data = try await LocalDictionaryLibrary.shared.resource(url.path, in: article.dictionary)
                    mime = Self.mime(url.pathExtension)
                }
                try Task.checkCancellation()
                #if DEBUG
                MemoryPhaseDiagnostics.snapshot("webview.resource.delivering", pendingRequests: self.requests.count,
                                                payloadBytes: data.count)
                #endif
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                    textEncodingName: mime.hasPrefix("text/") || mime == "application/javascript" ? "utf-8" : nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                #if DEBUG
                LocalDictionaryDebug.trace("resource.delivered", articleID: article.id,
                                           "path=\(String(reflecting: url.path)) type=\(mime) bytes=\(data.count)")
                #endif
            } catch is CancellationError {
                #if DEBUG
                LocalDictionaryDebug.trace("resource.cancelled", articleID: article.id, "path=\(String(reflecting: url.path))")
                #endif
            }
            catch {
                if !Task.isCancelled {
                    // No headwords, HTML, file paths or script contents in logs.
                    Self.report(error, event: "resource.failed", kind: Self.mime(url.pathExtension))
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
        #if DEBUG
        MemoryPhaseDiagnostics.snapshot("webview.resource.started", pendingRequests: requests.count)
        #endif
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // about:blank and superseded documents must never reveal an old surface.
        guard let navigation, navigation === activeNavigation, let pageURL,
              LocalArticleLink.isSameDocument(webView.url, as: pageURL) else {
            #if DEBUG
            LocalDictionaryDebug.trace("navigation.finished.ignored", articleID: article?.id,
                                       "origin=\(webView.url?.host ?? "-") sameNavigation=\(navigation != nil && navigation === activeNavigation)")
            #endif
            return
        }
        #if DEBUG
        LocalDictionaryDebug.trace("navigation.finished", articleID: article?.id, "checkingFinalStyles=true")
        #endif
        // A previous navigation's completion can arrive after webView.url already
        // points at the next document. Check navigation identity again after JS,
        // and flush layout with the final inline stylesheet before showing it.
        let ready = """
        (() => {
          if (document.readyState !== 'complete' || !document.getElementById('odict-local-overrides')?.sheet) return false;
          void document.documentElement.offsetHeight;
          return true;
        })()
        """
        webView.evaluateJavaScript(ready) { [weak self, weak webView] result, error in
            guard let self, let webView, navigation === self.activeNavigation,
                  self.pageURL == pageURL, LocalArticleLink.isSameDocument(webView.url, as: pageURL) else {
                #if DEBUG
                LocalDictionaryDebug.trace("page.ready.ignored.stale", articleID: UUID(uuidString: pageURL.host ?? ""))
                #endif
                return
            }
            if let error { Self.report(error, event: "document.readiness.failed", kind: "document"); return }
            guard result as? Bool == true else {
                #if DEBUG
                LocalDictionaryDebug.trace("page.notReady", articleID: self.article?.id)
                #endif
                return
            }
            self.activeNavigation = nil
            webView.isHidden = false
            #if DEBUG
            self.renderingMemory?.mark("visible")
            self.renderingMemory = nil
            LocalDictionaryDebug.trace("page.visible", articleID: self.article?.id, "finalStylesReady=true")
            #endif
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.report(error, event: "navigation.failed", kind: "document")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.report(error, event: "navigation.failed", kind: "provisional")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("event=webcontent.terminated")
    }
    private static func report(_ error: Error, event: String, kind: String) {
        let error = error as NSError
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
        log.error("event=\(event, privacy: .public) kind=\(kind, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code)")
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        #if DEBUG
        LocalDictionaryDebug.trace("resource.stopped", articleID: UUID(uuidString: urlSchemeTask.request.url?.host ?? ""),
                                   "path=\(String(reflecting: urlSchemeTask.request.url?.path ?? ""))")
        #endif
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
    }
    func cancelAll() {
        #if DEBUG
        if !requests.isEmpty || audioTask != nil {
            LocalDictionaryDebug.trace("requests.cancelAll", articleID: article?.id, "pending=\(requests.count)")
        }
        #endif
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
        // Programmatic .other navigations may still report the previous source
        // frame while a new article is replacing it. Only user links need this gate.
        if navigationAction.navigationType == .linkActivated,
           let source = navigationAction.sourceFrame.request.url,
           source.scheme == Self.scheme, source.host != pageURL.host {
            decisionHandler(.cancel); return
        }
        if url.scheme == Self.scheme, url.host == pageURL.host, navigationAction.targetFrame?.isMainFrame == true {
            // Same-page anchors are allowed; other local HTML stays within this renderer.
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        guard navigationAction.navigationType == .linkActivated else { return }
        switch url.scheme?.lowercased() {
        case "entry", "bword", "gdlookup":
            switch LocalArticleLink.target(url) {
            case .word(let word): lookup?(word)
            case .anchor(let anchor):
                guard LocalArticleLink.isSameDocument(webView.url, as: pageURL),
                      let script = LocalArticleLink.anchorScript(anchor) else { return }
                webView.evaluateJavaScript(script) { _, error in
                    if let error { Self.report(error, event: "anchor.failed", kind: "navigation") }
                }
            case nil: break
            }
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
