import AppKit
import XCTest
@testable import FileScannerCore

@MainActor
final class OpenRequestsTests: XCTestCase {
    func testAppDelegateQueuesFinderOpenRequestsAndTakeConsumesThem() {
        let requests = OpenRequests.shared
        _ = requests.take()
        let oldWindowCount = requests.liveWindowCount
        requests.liveWindowCount = 1
        defer { requests.liveWindowCount = oldWindowCount; _ = requests.take() }
        let urls = [URL(fileURLWithPath: "/tmp/example.md"), URL(fileURLWithPath: "/tmp/example.json")]
        AppDelegate().application(NSApplication.shared, open: urls)
        XCTAssertEqual(requests.pending, urls)
        requests.submit([])
        XCTAssertEqual(requests.pending, urls)
        XCTAssertEqual(requests.take(), urls)
        XCTAssertTrue(requests.take().isEmpty)
    }
}
