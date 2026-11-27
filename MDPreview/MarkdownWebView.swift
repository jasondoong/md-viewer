import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Renders markdown in a WKWebView. The HTML shell + JS (marked, highlight.js) is loaded once;
/// switching files or reloading only swaps the content via JavaScript, so it's fast and keeps
/// the scroll position on live reload.
struct MarkdownWebView: NSViewRepresentable {
    /// `nil` for an in-memory pasted document, which has no file location. The web layer
    /// uses this only to derive the resource base URL; a pasted JSON document has no base
    /// (no file, no local resource URL) and never loads one.
    let fileURL: URL?
    let rootURL: URL?
    let markdown: String
    /// The current document kind (`.markdown` or `.json`). The same `markdown` field
    /// carries the raw content for both kinds; the web layer routes JSON to its own
    /// branch and Markdown to the marked pipeline.
    let documentKind: Workspace.DocumentKind?
    /// The document identity sent to the web layer ("file:" + path). A change to this
    /// string resets the scroll position; the same identity with a new version keeps it.
    let documentID: Workspace.DocumentID?
    let version: Int
    let zoom: Double
    let jsonTreeCommand: Workspace.JSONTreeCommand?
    let onLinkClicked: (URL) -> Void
    /// Called with a zoom step (±0.1) when the user does Ctrl + scroll-wheel, so the host
    /// can update its persisted `zoomLevel`. Plain scroll scrolls natively; Shift scrolls horizontally.
    let onZoomBy: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ZoomScrollWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: LocalSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "linkClicked")

        let webView = ZoomScrollWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        // Let folder/file drops fall through to SwiftUI's .dropDestination instead of WebKit.
        webView.unregisterDraggedTypes()
        webView.pageZoom = zoom
        // Ctrl + scroll-wheel reports a zoom step to the host's persisted zoomLevel.
        webView.onZoomBy = { [weak coordinator = context.coordinator] delta in
            coordinator?.onZoomBy?(delta)
        }
        context.coordinator.webView = webView

        webView.load(URLRequest(url: LocalSchemeHandler.pageURL))
        return webView
    }

    func updateNSView(_ webView: ZoomScrollWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.schemeHandler.rootURL = rootURL
        if webView.pageZoom != zoom {
            webView.pageZoom = zoom
            webView.evaluateJavaScript("window.MDP?.setControlScale(\(zoom))", completionHandler: nil)
        }
        coordinator.onZoomBy = { [weak coordinator] delta in
            coordinator?.parent.onZoomBy(delta)
        }
        coordinator.render(
            fileURL: fileURL,
            markdown: markdown,
            documentKind: documentKind,
            documentID: documentID,
            version: version,
            jsonTreeCommand: jsonTreeCommand
        )
    }

    static func dismantleNSView(_ webView: ZoomScrollWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "linkClicked")
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownWebView
        weak var webView: WKWebView?
        var onZoomBy: ((Double) -> Void)?
        let schemeHandler = LocalSchemeHandler()

        private var pageLoaded = false
        private var pending: (url: URL?, markdown: String, kind: Workspace.DocumentKind?, id: Workspace.DocumentID?, version: Int, jsonTreeCommand: Workspace.JSONTreeCommand?)?
        private var renderedDocumentID: String?
        private var renderedVersion = -1
        private var lastJSONTreeCommandID: UUID?

        init(parent: MarkdownWebView) {
            self.parent = parent
            super.init()
            schemeHandler.rootURL = parent.rootURL
        }

        func render(fileURL: URL?, markdown: String, documentKind: Workspace.DocumentKind?, documentID: Workspace.DocumentID?, version: Int, jsonTreeCommand: Workspace.JSONTreeCommand?) {
            pending = (fileURL, markdown, documentKind, documentID, version, jsonTreeCommand)
            flush()
        }

        private func flush() {
            guard pageLoaded, let webView, let job = pending else { return }
            pending = nil
            // Identity (documentID) drives both the dedup and the scroll reset: a new
            // identity resets scroll; the same identity re-rendered (version bump) keeps
            // the position. Falls back to nil when no document is selected.
            let id = job.id?.payloadString
            if id != renderedDocumentID || job.version != renderedVersion {
                let isNewIdentity = id != renderedDocumentID
                renderedDocumentID = id
                renderedVersion = job.version

                // Keep the legacy web payload fields (base / resetScroll / markdown) and add
                // the new kind + documentID + json fields. Web with an old payload (no kind)
                // takes the Markdown path, so this stays backward compatible.
                let kind = (job.kind == .json) ? "json" : "markdown"
                // A pasted document has no file, hence no base. Markdown derives its base from
                // the file's directory; JSON never loads a base, so an empty base is correct.
                let base = job.url.map { LocalSchemeHandler.baseURL(forDirectoryOf: $0) } ?? ""
                var payload: [String: Any] = [
                    "kind": kind,
                    "base": base,
                    "resetScroll": isNewIdentity,
                ]
                if let id {
                    payload["documentID"] = id
                }
                if kind == "json" {
                    payload["json"] = job.markdown
                } else {
                    payload["markdown"] = job.markdown
                }
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let json = String(data: data, encoding: .utf8) else { return }
                webView.evaluateJavaScript("window.MDP.render(\(json));") { _, error in
                    if let error { NSLog("MDPreview render error: \(error)") }
                }
            }

            // Dispatch JSON tree expand/collapse command if the command state changed.
            if let cmd = job.jsonTreeCommand, cmd.id != self.lastJSONTreeCommandID {
                self.lastJSONTreeCommandID = cmd.id
                // Gate on document identity and render version to ensure we target the correct view
                if cmd.documentID?.payloadString == id && cmd.renderVersion == job.version {
                    webView.evaluateJavaScript("window.MDP?.setJSONTreeExpanded(\(cmd.expanded));", completionHandler: nil)
                }
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
            webView.evaluateJavaScript("window.MDP?.setControlScale(\(webView.pageZoom))", completionHandler: nil)
            // Force a render after (re)load even if the version didn't change.
            renderedDocumentID = nil
            renderedVersion = -1
            if pending == nil {
                pending = (
                    parent.fileURL,
                    parent.markdown,
                    parent.documentKind,
                    parent.documentID,
                    parent.version,
                    parent.jsonTreeCommand
                )
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

// MARK: - Scroll/zoom web view

/// Routes scroll-wheel gestures by modifier key so the preview offers editor-like
/// navigation without needing a trackpad:
///   - plain wheel    → vertical scroll (WebKit-native, keeps momentum)
///   - Shift + wheel  → horizontal scroll
///   - Control + wheel→ zoom in/out (reported via `onZoomBy` to the host's zoomLevel)
final class ZoomScrollWebView: WKWebView {
    /// Invoked with a zoom step (positive = in, negative = out) on Ctrl + scroll-wheel.
    var onZoomBy: ((Double) -> Void)?

    private enum ScrollMode {
        case normal, horizontal, zoom
    }

    // Remember the mode for momentum events, which may no longer carry modifier flags.
    private var gestureMode: ScrollMode = .normal
    private var zoomAccumulator = 0.0

    private func zoom(at event: NSEvent, steps: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let x = point.x / pageZoom
        let y = (isFlipped ? point.y : bounds.height - point.y) / pageZoom
        evaluateJavaScript("window.MDP?.zoomMermaidAt(\(x), \(y), \(steps)) ?? false") { [weak self] result, _ in
            if (result as? Bool) != true {
                self?.onZoomBy?(Double(steps) * 0.1)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) {
            gestureMode = .normal
            zoomAccumulator = 0
        }

        let mode: ScrollMode
        if !event.momentumPhase.isEmpty {
            mode = gestureMode
        } else if event.modifierFlags.contains(.control) {
            mode = .zoom
        } else if event.modifierFlags.contains(.shift) {
            mode = .horizontal
        } else {
            mode = .normal
        }

        if event.momentumPhase.isEmpty {
            if mode != gestureMode { zoomAccumulator = 0 }
            gestureMode = mode
        }

        switch mode {
        case .normal:
            super.scrollWheel(with: event)
        case .zoom:
            // Do not continue zooming after the fingers leave the trackpad.
            guard event.momentumPhase.isEmpty else { return }
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard delta != 0 else { return }
            if event.hasPreciseScrollingDeltas {
                zoomAccumulator += delta
                let pointsPerStep = 20.0
                let steps = Int(zoomAccumulator / pointsPerStep)
                if steps != 0 {
                    zoomAccumulator -= Double(steps) * pointsPerStep
                    zoom(at: event, steps: steps)
                }
            } else {
                zoom(at: event, steps: delta > 0 ? 1 : -1)
            }
        case .horizontal:
            let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return }
            // AppKit deltas describe content movement; DOM scroll offsets have the opposite sign.
            // Non-precise mouse wheels report lines rather than points.
            let distance = -delta * (event.hasPreciseScrollingDeltas ? 1 : 40) / pageZoom
            let point = convert(event.locationInWindow, from: nil)
            let x = point.x / pageZoom
            let y = (isFlipped ? point.y : bounds.height - point.y) / pageZoom
            evaluateJavaScript("""
                (() => {
                  let element = document.elementFromPoint(\(x), \(y));
                  while (element && element !== document.documentElement) {
                    const overflow = getComputedStyle(element).overflowX;
                    if ((overflow === 'auto' || overflow === 'scroll') &&
                        element.scrollWidth > element.clientWidth) {
                      element.scrollLeft += \(distance);
                      return;
                    }
                    element = element.parentElement;
                  }
                  window.scrollBy(\(distance), 0);
                })();
                """, completionHandler: nil)
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
            let candidate = URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL.resolvingSymlinksInPath()
            if let root = rootURL?.standardizedFileURL.resolvingSymlinksInPath() {
                let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                fileURL = candidate.path.hasPrefix(prefix) ? candidate : nil
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
