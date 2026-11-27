import Foundation
import WebKit
import XCTest
@testable import FileScannerCore

private final class SchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var data = Data()
    var error: Error?
    var finished = false

    init(_ url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}

@MainActor
final class LocalSchemeHandlerTests: XCTestCase {
    func testServesFileInsideRootAndRejectsSiblingAndMissingRoot() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdpreview-scheme-" + UUID().uuidString, isDirectory: true)
        let sibling = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sibling)
        }
        let inside = root.appendingPathComponent("image.png")
        let outside = sibling.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: inside)
        try Data([4]).write(to: outside)
        func schemeURL(_ file: URL) -> URL {
            var parts = URLComponents()
            parts.scheme = "mdpreview"
            parts.host = "file"
            parts.path = file.path
            return parts.url!
        }
        let handler = LocalSchemeHandler()
        let webView = WKWebView(frame: .zero)
        handler.rootURL = root
        let allowed = SchemeTask(schemeURL(inside))
        handler.webView(webView, start: allowed)
        XCTAssertTrue(allowed.finished)
        XCTAssertEqual(allowed.data, Data([1, 2, 3]))
        XCTAssertEqual((allowed.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((allowed.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "image/png")
        let rejected = SchemeTask(schemeURL(outside))
        handler.webView(webView, start: rejected)
        XCTAssertFalse(rejected.finished)
        XCTAssertEqual((rejected.error as? URLError)?.code, .fileDoesNotExist)
        let link = root.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escaped = SchemeTask(schemeURL(link))
        handler.webView(webView, start: escaped)
        XCTAssertEqual((escaped.error as? URLError)?.code, .fileDoesNotExist)
        let innerLink = root.appendingPathComponent("inside-link.png")
        try FileManager.default.createSymbolicLink(at: innerLink, withDestinationURL: inside)
        let linkedInside = SchemeTask(schemeURL(innerLink))
        handler.webView(webView, start: linkedInside)
        XCTAssertEqual(linkedInside.data, Data([1, 2, 3]))
        XCTAssertTrue(linkedInside.finished)
        handler.rootURL = nil
        let noRoot = SchemeTask(schemeURL(inside))
        handler.webView(webView, start: noRoot)
        XCTAssertEqual((noRoot.error as? URLError)?.code, .fileDoesNotExist)
    }
}
