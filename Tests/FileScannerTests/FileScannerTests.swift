import Foundation
import XCTest
@testable import FileScannerCore

final class FileScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, data: Data = Data()) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func testRecognizesSupportedExtensionsCaseInsensitively() {
        for ext in ["md", "markdown", "mdown", "mkd", "mkdn", "mdx", "mmd"] {
            XCTAssertTrue(FileScanner.isMarkdown(root.appendingPathComponent("file.\(ext.uppercased())")), ext)
        }
        XCTAssertTrue(FileScanner.isJSON(root.appendingPathComponent("file.JSON")))
        XCTAssertTrue(FileScanner.isPreviewable(root.appendingPathComponent("file.json")))
        XCTAssertFalse(FileScanner.isMarkdown(root.appendingPathComponent("file.json")))
        XCTAssertFalse(FileScanner.isPreviewable(root.appendingPathComponent("file.txt")))
    }

    func testScanOrdersFoldersFirstAndFlattensDepthFirst() throws {
        let nested = try write("folder/nested.md")
        let second = try write("file2.md")
        let tenth = try write("file10.json")
        _ = try write("ignored.txt")
        let result = FileScanner.scan(root)
        XCTAssertEqual(result.tree.map(\.name), ["folder", "file2.md", "file10.json"])
        XCTAssertEqual(result.files.map { $0.resolvingSymlinksInPath().path }, [nested, second, tenth].map { $0.resolvingSymlinksInPath().path })
    }

    func testScanSkipsHiddenAndBuildDirectoriesAndEmptyFolders() throws {
        _ = try write(".hidden.md")
        _ = try write(".hidden/inside.md")
        _ = try write("node_modules/dependency.md")
        _ = try write("build/output.json")
        _ = try write("empty/readme.txt")
        let visible = try write("visible.md")
        XCTAssertEqual(FileScanner.scan(root).files.map { $0.resolvingSymlinksInPath().path }, [visible.resolvingSymlinksInPath().path])
        XCTAssertEqual(FileScanner.scan(root).tree.map(\.name), ["visible.md"])
    }

    func testReadTextUsesLossyUTF8ForInvalidBytes() throws {
        let valid = try write("valid.md", data: Data("你好".utf8))
        let invalid = try write("invalid.md", data: Data([0x61, 0xff, 0x62]))
        XCTAssertEqual(try FileScanner.readText(valid), "你好")
        XCTAssertEqual(try FileScanner.readText(invalid), "a\u{FFFD}b")
        XCTAssertThrowsError(try FileScanner.readText(root.appendingPathComponent("missing.md")))
    }

    func testJSONSizeLimitAllowsBoundaryAndRejectsLargerFile() throws {
        let url = try write("large.json")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(FileScanner.jsonSizeLimit))
        XCTAssertEqual(FileScanner.checkJSONSize(url), .withinLimit)
        let larger = try write("larger.json")
        let largerHandle = try FileHandle(forWritingTo: larger)
        defer { try? largerHandle.close() }
        try largerHandle.truncate(atOffset: UInt64(FileScanner.jsonSizeLimit + 1))
        XCTAssertEqual(FileScanner.checkJSONSize(larger), .exceedsLimit(actualSize: FileScanner.jsonSizeLimit + 1, limit: FileScanner.jsonSizeLimit))
        XCTAssertEqual(FileScanner.checkJSONSize(root.appendingPathComponent("missing.json")), .withinLimit)
    }
    func testScanDepthLimitAndSymbolicLinks() throws {
        let target = try write("target.md")
        let linkedFile = root.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: target)
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data().write(to: outside.appendingPathComponent("external.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder"), withDestinationURL: outside)
        let insideLimit = (1..<FileScanner.maxDepth).map { "d\($0)" }.joined(separator: "/")
        _ = try write(insideLimit + "/included.md")
        _ = try write(insideLimit + "/too-deep/excluded.md")
        let names = FileScanner.scan(root).files.map(\.lastPathComponent)
        XCTAssertTrue(names.contains("target.md"))
        XCTAssertTrue(names.contains("linked.md"))
        XCTAssertTrue(names.contains("included.md"))
        XCTAssertFalse(names.contains("external.md"))
        XCTAssertFalse(names.contains("excluded.md"))
    }

}
