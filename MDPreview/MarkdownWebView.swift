import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Renders markdown in a WKWebView. The HTML shell + JS (marked, highlight.js) is loaded once;
/// switching files or reloading only swaps the content via JavaScript, so it's fast and keeps
/// the scroll position on live reload.
struct MarkdownWebView: NSViewRepresentable {
    let fileURL: URL
    let rootURL: URL?
    let markdown: String
    let version: Int
    let zoom: Double
    let onLinkClicked: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: LocalSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "linkClicked")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        // Let folder/file drops fall through to SwiftUI's .dropDestination instead of WebKit.
        webView.unregisterDraggedTypes()
        webView.pageZoom = zoom
        context.coordinator.webView = webView

        webView.load(URLRequest(url: LocalSchemeHandler.pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.schemeHandler.rootURL = rootURL
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        coordinator.render(fileURL: fileURL, markdown: markdown, version: version)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "linkClicked")
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownWebView
        weak var webView: WKWebView?
        let schemeHandler = LocalSchemeHandler()

        private var pageLoaded = false
        private var pending: (url: URL, markdown: String, version: Int)?
        private var renderedURL: URL?
        private var renderedVersion = -1

        init(parent: MarkdownWebView) {
            self.parent = parent
            super.init()
            schemeHandler.rootURL = parent.rootURL
        }

        func render(fileURL: URL, markdown: String, version: Int) {
            pending = (fileURL, markdown, version)
            flush()
        }

        private func flush() {
            guard pageLoaded, let webView, let job = pending else { return }
            pending = nil
            guard job.url != renderedURL || job.version != renderedVersion else { return }

            let isNewFile = job.url != renderedURL
            renderedURL = job.url
            renderedVersion = job.version

            let payload: [String: Any] = [
                "markdown": job.markdown,
                "base": LocalSchemeHandler.baseURL(forDirectoryOf: job.url),
                "resetScroll": isNewFile,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.MDP.render(\(json));") { _, error in
                if let error { NSLog("MDPreview render error: \(error)") }
            }
        }

        // Only the bundled shell page may load in the frame; everything else is handled natively.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            if url.scheme == LocalSchemeHandler.scheme, url.host == LocalSchemeHandler.appHost {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated {
                    parent.onLinkClicked(url)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            // Force a render after (re)load even if the version didn't change.
            renderedURL = nil
            renderedVersion = -1
            if pending == nil {
                pending = (parent.fileURL, parent.markdown, parent.version)
            }
            flush()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            pageLoaded = false
            webView.load(URLRequest(url: LocalSchemeHandler.pageURL))
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "linkClicked",
                  let string = message.body as? String,
                  let url = URL(string: string) else { return }
            parent.onLinkClicked(url)
        }
    }
}

// MARK: - Custom URL scheme

/// Serves `mdpreview://app/<name>` from the bundled Web folder and
/// `mdpreview://file/<absolute path>` from disk (restricted to the opened folder),
/// so relative image paths in markdown just work.
@MainActor
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdpreview"
    static let appHost = "app"
    static let fileHost = "file"
    static let pageURL = URL(string: "\(scheme)://\(appHost)/index.html")!

    /// Files outside this folder are not served. `nil` = serve nothing from disk.
    var rootURL: URL?

    static func baseURL(forDirectoryOf fileURL: URL) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = fileHost
        let dir = fileURL.deletingLastPathComponent().path
        components.path = dir.hasSuffix("/") ? dir : dir + "/"
        return components.url?.absoluteString ?? "\(scheme)://\(fileHost)/"
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            return task.didFailWithError(URLError(.badURL))
        }

        let fileURL: URL?
        switch url.host {
        case Self.appHost:
            fileURL = Bundle.main.url(forResource: url.lastPathComponent, withExtension: nil, subdirectory: "Web")
        case Self.fileHost:
            let candidate = URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL
            if let root = rootURL?.standardizedFileURL, candidate.path.hasPrefix(root.path + "/") {
                fileURL = candidate
            } else {
                fileURL = nil
            }
        default:
            fileURL = nil
        }

        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }

        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
