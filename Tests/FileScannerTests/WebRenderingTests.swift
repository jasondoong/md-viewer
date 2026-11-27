import Foundation
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import FileScannerCore

/// Serves the repository's actual bundled Web assets through the app's scheme in tests.
@MainActor
private final class TestWebAssets: NSObject, WKURLSchemeHandler {
    let webRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web")
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "app",
              let data = try? Data(contentsOf: webRoot.appendingPathComponent(url.lastPathComponent)) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class WebRenderingTests: XCTestCase {
    func testCoordinatorRendersMarkdownAndJSONInRealWebKit() async throws {
        let (webView, coordinator) = makePreview()
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript("typeof window.MDP?.render === 'function'") as? Bool) == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let markdownID = Workspace.DocumentID.pasted(UUID())
        coordinator.render(fileURL: nil, markdown: "# Hello WebKit\n\n**bold**", documentKind: .markdown,
                           documentID: markdownID, version: 2, jsonTreeCommand: nil)
        var markdownOK = false
        for _ in 0..<100 {
            markdownOK = (try? await webView.evaluateJavaScript("document.querySelector('#content h1')?.textContent === 'Hello WebKit' && document.querySelector('#content strong')?.textContent === 'bold'") as? Bool) == true
            if markdownOK { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(markdownOK, "Markdown was not rendered in WKWebView")
        coordinator.render(fileURL: nil, markdown: "{\"answer\":42}", documentKind: .json,
                           documentID: .pasted(UUID()), version: 3, jsonTreeCommand: nil)
        var jsonOK = false
        for _ in 0..<100 {
            jsonOK = (try? await webView.evaluateJavaScript("document.querySelector('#content .json-tree button.json-object')?.getAttribute('aria-label') === 'Object, 1 key'") as? Bool) == true
            if jsonOK { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(jsonOK, "JSON was not rendered in WKWebView")
        let treeID = Workspace.DocumentID.pasted(UUID())
        coordinator.render(fileURL: nil, markdown: "{\"answer\":42}", documentKind: .json,
                           documentID: treeID, version: 4, jsonTreeCommand: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        let collapse = Workspace.JSONTreeCommand(id: UUID(), documentID: treeID, renderVersion: 4, expanded: false)
        coordinator.render(fileURL: nil, markdown: "{\"answer\":42}", documentKind: .json,
                           documentID: treeID, version: 4, jsonTreeCommand: collapse)
        try await Task.sleep(nanoseconds: 100_000_000)
        let collapsed = try await webView.evaluateJavaScript("document.querySelector('#content button.json-object')?.getAttribute('aria-expanded')") as? String
        XCTAssertEqual(collapsed, "false")
        coordinator.render(fileURL: nil, markdown: "{invalid", documentKind: .json,
                           documentID: .pasted(UUID()), version: 5, jsonTreeCommand: nil)
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript("document.querySelector('.json-error')?.textContent.includes('Invalid JSON') && document.querySelector('.json-source')?.textContent === '{invalid'") as? Bool) == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Invalid JSON did not show an error and original source")
    }

    func testMarkdownReloadKeepsScrollAndDocumentSwitchResetsIt() async throws {
        let (webView, coordinator) = makePreview()
        let first = URL(fileURLWithPath: "/first.md")
        let second = URL(fileURLWithPath: "/second.md")
        let paragraphs = (1...100).map { "Paragraph \($0) with enough text to read." }.joined(separator: "\n\n")

        func render(_ file: URL, heading: String, version: Int) {
            coordinator.render(fileURL: file, markdown: "# \(heading)\n\n" + paragraphs,
                               documentKind: .markdown, documentID: .file(path: file.path), version: version,
                               jsonTreeCommand: nil)
        }

        render(first, heading: "Original", version: 2)
        try await waitForScript("document.querySelector('article h1')?.textContent === 'Original'", in: webView)
        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 800); true")
        try await waitForScript("Math.abs(window.scrollY - 800) <= 1", in: webView)

        render(first, heading: "Reloaded", version: 3)
        try await waitForScript("document.querySelector('article h1')?.textContent === 'Reloaded' && Math.abs(window.scrollY - 800) <= 1", in: webView)

        render(second, heading: "Different document", version: 4)
        try await waitForScript("document.querySelector('article h1')?.textContent === 'Different document' && window.scrollY === 0", in: webView)
    }

    private func waitForScript(_ script: String, in webView: WKWebView) async throws {
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript(script) as? Bool) == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "WebRenderingTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "WebKit did not satisfy: " + script])
    }

    private func makePreview() -> (WKWebView, MarkdownWebView.Coordinator) {
        let parent = MarkdownWebView(fileURL: nil, rootURL: nil, markdown: "# Initial", documentKind: .markdown,
                                     documentID: .pasted(UUID()), version: 1, zoom: 1, jsonTreeCommand: nil,
                                     onLinkClicked: { _ in }, onZoomBy: { _ in })
        let coordinator = parent.makeCoordinator()
        let configuration = WKWebViewConfiguration()
        let assets = TestWebAssets()
        configuration.setURLSchemeHandler(assets, forURLScheme: "mdpreview")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        webView.load(URLRequest(url: LocalSchemeHandler.pageURL))
        return (webView, coordinator)
    }

}
