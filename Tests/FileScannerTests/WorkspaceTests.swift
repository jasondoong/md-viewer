import Foundation
import XCTest
@testable import FileScannerCore

final class WorkspaceTests: XCTestCase {
    private var root: URL!
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["lastFolder", "lastFile", "zoomLevel"]

    override func setUpWithError() throws {
        for key in keys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdpreview-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String = "") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @MainActor
    private func waitForScan(_ workspace: Workspace, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if !workspace.isScanning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Scan did not finish", file: file, line: line)
    }

    @MainActor
    func testSelectionReloadAndMermaidConversion() async throws {
        let markdown = try write("README.md", "first")
        let mermaid = try write("diagram.mmd", "graph TD; A-->B")
        let workspace = Workspace()
        workspace.open(folder: root)
        try await waitForScan(workspace)
        XCTAssertEqual(workspace.selection?.lastPathComponent, "README.md")
        XCTAssertEqual(workspace.markdown, "first")
        let version = workspace.renderVersion
        try Data("updated".utf8).write(to: markdown)
        workspace.reloadAll()
        XCTAssertEqual(workspace.markdown, "updated")
        XCTAssertGreaterThan(workspace.renderVersion, version)
        workspace.select(mermaid)
        XCTAssertEqual(workspace.documentKind, .markdown)
        XCTAssertEqual(workspace.markdown, "```mermaid\ngraph TD; A-->B\n```")
        XCTAssertNil(workspace.loadError)
    }

    @MainActor
    func testPasteIdentityReselectionAndCommands() throws {
        let workspace = Workspace()
        workspace.selectPastedJSON()
        XCTAssertNil(workspace.documentID)
        workspace.submitPastedJSON("{\"a\":1}")
        let firstID = workspace.documentID
        XCTAssertEqual(workspace.documentKind, .json)
        XCTAssertEqual(workspace.markdown, "{\"a\":1}")
        XCTAssertNil(workspace.selection)
        workspace.requestJSONTreeExpandAll()
        XCTAssertEqual(workspace.jsonTreeCommand?.documentID, firstID)
        XCTAssertEqual(workspace.jsonTreeCommand?.renderVersion, workspace.renderVersion)
        XCTAssertEqual(workspace.jsonTreeCommand?.expanded, true)
        let commandID = workspace.jsonTreeCommand?.id
        workspace.requestJSONTreeCollapseAll()
        XCTAssertNotEqual(workspace.jsonTreeCommand?.id, commandID)
        XCTAssertEqual(workspace.jsonTreeCommand?.expanded, false)
        workspace.selectPastedJSON()
        XCTAssertEqual(workspace.documentID, firstID)
        workspace.submitPastedJSON("[]")
        XCTAssertNotEqual(workspace.documentID, firstID)
        workspace.reloadAll()
        XCTAssertEqual(workspace.markdown, "[]")
        XCTAssertTrue(workspace.recentFiles.isEmpty)
    }

    @MainActor
    func testSearchNavigationAndExpandedRows() async throws {
        _ = try write("README.md", "readme")
        let nested = try write("docs/guide.md", "guide")
        _ = try write("notes.md", "notes")
        let workspace = Workspace()
        workspace.open(folder: root)
        try await waitForScan(workspace)
        XCTAssertEqual(workspace.relativePath(of: nested), "docs/guide.md")
        XCTAssertEqual(workspace.relativeDirectory(of: nested), "docs")
        XCTAssertEqual(workspace.visibleRows.map(\.depth), [0, 0, 0])
        workspace.toggleExpanded(root.appendingPathComponent("docs"))
        XCTAssertEqual(workspace.visibleRows.map(\.depth), [0, 1, 0, 0])
        workspace.filter = " GUIDE "
        XCTAssertEqual(workspace.filteredFiles.map(\.lastPathComponent), ["guide.md"])
        XCTAssertEqual(workspace.quickOpenResults(for: "gd").map(\.lastPathComponent), ["guide.md"])
        workspace.select(nested)
        XCTAssertTrue(workspace.isExpanded(root.appendingPathComponent("docs")))
        XCTAssertEqual(workspace.quickOpenResults(for: "").first?.lastPathComponent, "guide.md")
        workspace.selectAdjacent(1)
        XCTAssertEqual(workspace.selection?.lastPathComponent, "notes.md")
        workspace.selectAdjacent(-1)
        XCTAssertEqual(workspace.selection?.lastPathComponent, "guide.md")
    }

    @MainActor
    func testJSONSizeAndExternalSymlinkAreRejected() async throws {
        let large = try write("large.json")
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(FileScanner.jsonSizeLimit + 1))
        try handle.close()
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{}".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let workspace = Workspace()
        workspace.open(folder: root)
        try await waitForScan(workspace)
        workspace.select(large)
        XCTAssertEqual(workspace.jsonSizeLimitExceeded?.actualSize, FileScanner.jsonSizeLimit + 1)
        XCTAssertTrue(workspace.markdown.isEmpty)
        XCTAssertNotNil(workspace.loadError)
        workspace.select(link)
        XCTAssertNil(workspace.jsonSizeLimitExceeded)
        XCTAssertNotNil(workspace.loadError)
        XCTAssertTrue(workspace.markdown.isEmpty)
    }

    @MainActor
    func testZoomClampAndPasteByteLimit() {
        let workspace = Workspace()
        workspace.zoom(by: 100)
        XCTAssertEqual(workspace.zoomLevel, 3)
        workspace.zoom(by: -100)
        XCTAssertEqual(workspace.zoomLevel, 0.5)
        workspace.resetZoom()
        XCTAssertEqual(workspace.zoomLevel, 1)
        XCTAssertFalse(Workspace.exceedsPasteSizeLimit(String(repeating: "a", count: Workspace.pasteInputSizeLimit)))
        XCTAssertTrue(Workspace.exceedsPasteSizeLimit(String(repeating: "a", count: Workspace.pasteInputSizeLimit) + "é"))
    }

    func testByteFormattingAndFuzzyMatching() {
        XCTAssertEqual(ByteFormat.humanReadableBytes(1023), "1023 B")
        XCTAssertEqual(ByteFormat.humanReadableBytes(1024), "1.0 KiB")
        XCTAssertEqual(ByteFormat.humanReadableBytes(50 * 1024 * 1024), "50.0 MiB")
        XCTAssertEqual(FuzzyMatcher.score("", in: "abc"), 0)
        XCTAssertNil(FuzzyMatcher.score("xyz", in: "abc"))
        XCTAssertNotNil(FuzzyMatcher.score("GD", in: "guide.md"))
        XCTAssertGreaterThan(FuzzyMatcher.score("ab", in: "ab")!, FuzzyMatcher.score("ab", in: "axxb")!)
    }
    @MainActor
    func testLocalResourceBaseURLEncodesDirectory() {
        let file = URL(fileURLWithPath: "/Users/example/a folder/document.md")
        XCTAssertEqual(LocalSchemeHandler.baseURL(forDirectoryOf: file), "mdpreview://file/Users/example/a%20folder/")
    }

    @MainActor
    func testMissingFileErrorClearsOnSwitchAndPasteCanBeRestored() async throws {
        let good = try write("good.json", "{\"ok\":true}")
        let workspace = Workspace()
        workspace.open(folder: root)
        try await waitForScan(workspace)
        workspace.select(root.appendingPathComponent("missing.md"))
        XCTAssertNotNil(workspace.loadError)
        XCTAssertEqual(workspace.markdown, "")
        XCTAssertEqual(workspace.documentKind, .markdown)
        workspace.submitPastedJSON("[]")
        let pasteID = workspace.documentID
        XCTAssertNil(workspace.loadError)
        workspace.select(good)
        XCTAssertEqual(workspace.documentKind, .json)
        XCTAssertEqual(workspace.markdown, "{\"ok\":true}")
        XCTAssertFalse(workspace.isPastedSelected)
        workspace.selectPastedJSON()
        XCTAssertEqual(workspace.documentID, pasteID)
        XCTAssertEqual(workspace.markdown, "[]")
    }

    @MainActor
    func testDropAndRecentFilesBehavior() async throws {
        let first = try write("first.md", "1")
        let second = try write("second.json", "2")
        let invalid = try write("ignored.txt", "3")
        let workspace = Workspace()
        XCTAssertFalse(workspace.handleDrop([]))
        XCTAssertFalse(workspace.handleDrop([invalid]))
        XCTAssertTrue(workspace.handleDrop([first]))
        try await waitForScan(workspace)
        XCTAssertEqual(workspace.selection?.lastPathComponent, "first.md")
        XCTAssertTrue(workspace.handleDrop([second]))
        workspace.select(first)
        XCTAssertEqual(workspace.recentFiles.map(\.lastPathComponent), ["first.md", "second.json"])
        XCTAssertEqual(workspace.quickOpenResults(for: "", limit: 1).map(\.lastPathComponent), ["first.md"])
    }

    @MainActor
    func testFileChangeReloadsSelectionAndNewFileAppears() async throws {
        let selected = try write("README.md", "before")
        let workspace = Workspace()
        workspace.open(folder: root)
        try await waitForScan(workspace)
        try await Task.sleep(nanoseconds: 300_000_000)
        try Data("after".utf8).write(to: selected)
        _ = try write("added.md", "new")
        for _ in 0..<100 {
            if workspace.markdown == "after" && workspace.allFiles.contains(where: { $0.lastPathComponent == "added.md" }) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("FSEvents did not reload the selected file and tree")
    }

}
