import AppKit
import Carbon
import XCTest

final class MDPreviewUITests: XCTestCase {
    func testQuickOpenSwitchesPreview() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdpreview-ui-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# UI Test".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Second".write(to: root.appendingPathComponent("second.md"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments += ["-lastFolder", root.path, "-lastFile", ""]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["README.md"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["quickOpenButton"].click()
        let result = app.sheets.firstMatch.staticTexts["second.md"]
        guard result.waitForExistence(timeout: 10) else {
            XCTFail("Expected second.md in Quick Open")
            return
        }
        result.click()
        XCTAssertTrue(app.webViews.staticTexts["Second"].firstMatch.waitForExistence(timeout: 10))
    }

    func testQuickOpenSearchSubmitsWithReturn() throws {
        // typeText generates key events, so the active IME can compose or change the query.
        let originalInput = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let asciiInput = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(asciiInput), noErr)
        defer { TISSelectInputSource(originalInput) }
        let root = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Starting document".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Keyboard result".write(to: root.appendingPathComponent("keyboard.md"), atomically: true, encoding: .utf8)
        let app = launch(in: root)
        defer { app.terminate() }
        XCTAssertTrue(app.webViews.staticTexts["Starting document"].firstMatch.waitForExistence(timeout: 10))

        app.buttons["quickOpenButton"].click()
        let sheet = app.sheets.firstMatch
        let search = sheet.textFields["quickOpenSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let initialResult = sheet.staticTexts["README.md"]
        XCTAssertTrue(initialResult.waitForExistence(timeout: 5))
        search.click()
        search.typeText("keyboard")
        guard initialResult.waitForNonExistence(timeout: 5) else {
            XCTFail("Quick Open did not filter the original result (query: \(search.value ?? ""))")
            return
        }
        XCTAssertTrue(sheet.staticTexts["keyboard.md"].exists)
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.webViews.staticTexts["Keyboard result"].firstMatch.waitForExistence(timeout: 10))
    }

    func testMarkdownLoadsLocalImageAndFollowsRelativeLink() throws {
        let root = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        var pixel = [255, 0, 255, 255]
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                bitmap.setPixel(&pixel, atX: x, y: y)
            }
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: assets.appendingPathComponent("test image.png"))
        try """
        # Resource preview

        ![Local image fixture](assets/test%20image.png)

        [Open linked document](linked.md)
        """.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Relative link destination".write(to: root.appendingPathComponent("linked.md"), atomically: true, encoding: .utf8)

        let app = launch(in: root)
        defer { app.terminate() }
        let preview = app.webViews.firstMatch
        let image = preview.images["Local image fixture"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        let imageLoaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // An image can be exposed to accessibility even while its pixels are missing.
            guard let screenshot = NSBitmapImageRep(data: preview.screenshot().pngRepresentation) else {
                return false
            }
            for y in stride(from: 0, to: screenshot.pixelsHigh, by: 12) {
                for x in stride(from: 0, to: screenshot.pixelsWide, by: 12) {
                    guard let color = screenshot.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                        continue
                    }
                    if color.redComponent > 0.8 && color.greenComponent < 0.35 && color.blueComponent > 0.8 {
                        return true
                    }
                }
            }
            return false
        }, object: nil)
        let loadResult = XCTWaiter.wait(for: [imageLoaded], timeout: 5)
        if loadResult != .completed {
            add(XCTAttachment(screenshot: preview.screenshot()))
        }
        XCTAssertEqual(loadResult, .completed, "Expected the local PNG's pixels")

        let link = preview.links["Open linked document"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.click()
        XCTAssertTrue(app.webViews.staticTexts["Relative link destination"].firstMatch.waitForExistence(timeout: 10))
    }

    func testPasteJSONSheet() {
        let app = XCUIApplication()
        app.launchArguments += ["-lastFolder", "", "-lastFile", ""]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.buttons["pasteJSONButton"].click()
        XCTAssertTrue(app.buttons["Preview"].waitForExistence(timeout: 5))
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("{\"test\":1}")
        app.buttons["Preview"].click()
        XCTAssertTrue(app.staticTexts["Pasted JSON"].waitForExistence(timeout: 5))
    }
    func testOpenFileThroughLaunchServices() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdpreview-open-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("finder-open.md")
        try "# Finder open".write(to: file, atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments += ["-lastFolder", "", "-lastFile", ""]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.dakastar.MDPreview.UITesting").first)
        let bundleURL = try XCTUnwrap(running.bundleURL)
        let opened = expectation(description: "Launch Services opened the file")
        NSWorkspace.shared.open([file], withApplicationAt: bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        XCTAssertTrue(app.staticTexts["finder-open.md"].firstMatch.waitForExistence(timeout: 10))
    }

    private func makeFixtureFolder() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mdpreview-ui-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func launch(in root: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-lastFolder", root.path, "-lastFile", ""]
        app.launch()
        return app
    }

}
