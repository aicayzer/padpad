import AppKit
import XCTest

@MainActor
final class MarkdownUITests: XCTestCase {
    func testMarkdownPasteFormattingSaveReopenAndSettingsReturn() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launchPad()
        defer { app.terminate() }
        waitForEditor(app)
        XCTAssertFalse(app.buttons["Bold"].exists, "Formatting starts hidden")

        let source = "# Disposable Markdown\n\nPasted **bold** and _italic_.\n\n- First item\n- Second item\n\nFinal paragraph"
        paste(source, into: app)
        attach(app.screenshot(), name: "Markdown pasted as formatted content")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["Disposable Markdown"].firstMatch.exists ||
                      web.textViews.firstMatch.exists, app.debugDescription)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("b", modifierFlags: .command)
        app.typeText("Bold keyboard text")
        app.typeKey("b", modifierFlags: .command)
        app.typeText(" ")
        app.typeKey("i", modifierFlags: .command)
        app.typeText("Italic keyboard text")
        app.typeKey("i", modifierFlags: .command)
        app.typeText(" Example")
        app.typeKey(.leftArrow, modifierFlags: [.option, .shift])
        app.typeKey("k", modifierFlags: .command)
        let urlField = app.textFields["Link URL"].firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), app.debugDescription)
        urlField.click()
        paste("https://example.com/padpad-ui-test", into: app)
        XCTAssertEqual(urlField.value as? String, "https://example.com/padpad-ui-test")
        let addLink = app.buttons["Add Link"].firstMatch
        XCTAssertTrue(addLink.isEnabled, app.debugDescription)
        addLink.click()
        attach(app.screenshot(), name: "Markdown toolbar and keyboard formatting")

        let saved = try saveAs(app, directory: directory)
        var contents = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertEqual(saved.pathExtension, "md")
        XCTAssertTrue(contents.contains("# Disposable Markdown"), contents)
        XCTAssertTrue(contents.contains("**bold**"), contents)
        XCTAssertTrue(contents.contains("**Bold keyboard text**"), contents)
        XCTAssertTrue(contents.contains("*Italic keyboard text*"), contents)
        XCTAssertTrue(contents.contains("https://example.com/padpad-ui-test"), contents)

        XCTAssertFalse(app.buttons["documentFormat"].exists, "Saving locks the quick pad to its file type")
        app.typeKey("n", modifierFlags: .command)
        waitForEditor(app)
        app.typeText("New document must not leak")
        app.typeKey("o", modifierFlags: .command)
        open(saved, in: app)
        let fileWindow = app.windows[saved.lastPathComponent].firstMatch
        XCTAssertTrue(fileWindow.waitForExistence(timeout: 10), app.debugDescription)
        waitForEditor(app, in: fileWindow)
        XCTAssertFalse(fileWindow.buttons["documentFormat"].exists, "Opened files retain their file type")
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("\nAfter reopen")
        app.typeKey("s", modifierFlags: .command)
        waitForFile(saved, containing: "After reopen")
        contents = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertFalse(contents.contains("New document must not leak"), contents)
        attach(app.screenshot(), name: "Saved Markdown reopened and edited")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        let files = settings.toolbars.buttons["Files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5), app.debugDescription)
        files.click()
        attach(settings.screenshot(), name: "Settings while formatted Markdown is open")
        settings.buttons["_XCUI:CloseWindow"].click()
        fileWindow.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)).click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("\nAfter Settings")
        app.typeKey("s", modifierFlags: .command)
        waitForFile(saved, containing: "After Settings")
        attach(app.screenshot(), name: "Formatted Markdown retained after Settings")
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Quick Pad"].firstMatch.click()
        app.typeKey("c", modifierFlags: [.command, .shift])
        waitForClipboard("New document must not leak")
        fileWindow.click()
        app.typeKey(.downArrow, modifierFlags: .command)

        let undoText = " Undoable addition"
        app.typeText(undoText)
        app.typeKey("s", modifierFlags: .command)
        waitForFile(saved, containing: undoText)
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("s", modifierFlags: .command)
        let undone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: saved, encoding: .utf8).contains(undoText)) == false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 5), .completed)
        app.typeKey("z", modifierFlags: [.command, .shift])
        app.typeKey("s", modifierFlags: .command)
        waitForFile(saved, containing: undoText)

        app.typeKey(",", modifierFlags: .command)
        settings.toolbars.buttons["General"].click()
        let appearance = settings.popUpButtons["appearance"].firstMatch
        let originalAppearance = try XCTUnwrap(appearance.value as? String)
        appearance.click()
        app.menuItems["Dark"].click()
        attach(app.screenshot(), name: "Formatted editor and Settings in Dark appearance")
        appearance.click()
        app.menuItems[originalAppearance].click()
    }

    func testImmediateTypingSavingAndNewDocumentIsolation() throws {
        let firstDirectory = try temporaryDirectory()
        let secondDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let app = launchPad()
        defer { app.terminate() }
        // No editor click or readiness wait: launch and document replacement own initial focus.
        let suffix = " Immediate Markdown \(UUID().uuidString)"
        let firstText = "é" + suffix
        app.typeKey("e", modifierFlags: .option)
        app.typeKey("e", modifierFlags: [])
        app.typeText(suffix)
        let first = try saveAs(app, directory: firstDirectory)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), firstText)

        app.typeKey("n", modifierFlags: .command)
        let secondText = "Second isolated Markdown \(UUID().uuidString)"
        app.typeText(secondText)
        let second = try saveAs(app, directory: secondDirectory)
        let contents = try String(contentsOf: second, encoding: .utf8)
        XCTAssertEqual(contents.trimmingCharacters(in: .whitespacesAndNewlines), secondText)
        XCTAssertFalse(contents.contains(firstText))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), firstText)
        attach(app.screenshot(), name: "Immediate Markdown typing and saved document isolation")
    }

    func testFormattingMenuPreservesSelectionAndEditorLayout() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launchPad()
        defer { app.terminate() }
        waitForEditor(app)
        app.typeText("Selected text")
        app.typeKey("a", modifierFlags: .command)
        let editorFrame = app.webViews.firstMatch.frame
        app.menuButtons["formattingMenu"].firstMatch.click()
        app.menuItems["Text style"].firstMatch.click()
        let bold = app.menuItems["Bold"].firstMatch
        XCTAssertTrue(bold.waitForExistence(timeout: 5), app.debugDescription)
        bold.click()
        XCTAssertEqual(app.webViews.firstMatch.frame.minY, editorFrame.minY, accuracy: 1)
        XCTAssertEqual(app.webViews.firstMatch.frame.height, editorFrame.height, accuracy: 1)
        // Choosing formatting must preserve the selected range and keyboard focus.
        app.typeText("Replacement")
        let saved = try saveAs(app, directory: directory)
        let replacement = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertEqual(replacement.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines), "Replacement")
    }

    func testNarrowFormattingMenuFormatsSelectedParagraphAndSaves() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launchPad()
        defer { app.terminate() }
        waitForEditor(app)
        app.typeText("Keep plain\n\nSelected text")
        app.typeKey(.leftArrow, modifierFlags: [.command, .shift])
        let toggle = app.menuButtons["formattingMenu"].firstMatch

        let window = app.dialogs.firstMatch
        let originalFrame = window.frame
        // Activate before dragging the outside resize edge of this nonactivating panel.
        app.activate()
        let resizeHandle = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 1, dy: 0))
        let narrowEdge = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 521, dy: originalFrame.height / 2))
        resizeHandle.hover()
        resizeHandle.click(forDuration: 0.2, thenDragTo: narrowEdge,
                           withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertLessThanOrEqual(window.frame.width, 540, "The window must reach its narrow layout")

        XCTAssertTrue(toggle.isHittable)
        XCTAssertFalse(app.menuButtons["formattingOverflow"].exists)
        XCTAssertTrue(app.buttons["Save"].firstMatch.isHittable)
        toggle.click()
        let quote = app.menuItems["Quote"].firstMatch
        XCTAssertTrue(quote.waitForExistence(timeout: 5), app.debugDescription)
        quote.click()

        let saved = try saveAs(app, directory: directory)
        let contents = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertEqual(contents.trimmingCharacters(in: .whitespacesAndNewlines), "Keep plain\n\n<br />\n\n> Selected text")
    }

    func testAuthoredBlankParagraphsSurviveFileSwitchAndRepeatedReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launchPad()
        defer { app.terminate() }
        waitForEditor(app)
        app.typeText("- First item")
        for _ in 0..<4 { app.typeKey(.return, modifierFlags: []) }
        app.typeText("- Second item")
        for _ in 0..<4 { app.typeKey(.return, modifierFlags: []) }
        attach(app.dialogs.firstMatch.screenshot(), name: "Authored blank paragraphs between lists and at the end")
        let saved = try saveAs(app, directory: directory)
        let original = try String(contentsOf: saved, encoding: .utf8)
        let spacers = original.components(separatedBy: "<br />").count - 1
        XCTAssertGreaterThanOrEqual(spacers, 4, original)
        XCTAssertTrue(original.contains("- First item"), original)
        XCTAssertTrue(original.contains("- Second item"), original)

        for cycle in 1...2 {
            app.typeKey("n", modifierFlags: .command)
            if cycle > 1 {
                let discard = app.buttons["Discard Changes"].firstMatch
                XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
                discard.click()
            }
            waitForEditor(app)
            app.typeText("A different disposable draft")
            app.typeKey("o", modifierFlags: .command)
            open(saved, in: app)
            let fileWindow = app.windows[saved.lastPathComponent].firstMatch
            XCTAssertTrue(fileWindow.waitForExistence(timeout: 10), app.debugDescription)
            waitForEditor(app, in: fileWindow)
            app.typeKey(.downArrow, modifierFlags: .command)
            app.typeText("Continued editing")
            app.typeKey("s", modifierFlags: .command)
            waitForFile(saved, containing: "Continued editing")
            let edited = try String(contentsOf: saved, encoding: .utf8)
            XCTAssertEqual(edited.components(separatedBy: "<br />").count - 1, spacers - 1, edited)
            // Restore the trailing empty paragraph and force a fresh serialization.
            app.typeKey(.leftArrow, modifierFlags: [.command, .shift])
            app.typeKey(.delete, modifierFlags: [])
            app.typeKey("s", modifierFlags: .command)
            let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (try? String(contentsOf: saved, encoding: .utf8)) == original
            }, object: nil)
            _ = XCTWaiter.wait(for: [stable], timeout: 5)
            let restored = try String(contentsOf: saved, encoding: .utf8)
            if restored != original {
                let evidence = XCTAttachment(string: "Expected: \(String(reflecting: original))\nActual: \(String(reflecting: restored))")
                evidence.name = "Exact Markdown after reopen cycle \(cycle)"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
            XCTAssertEqual(restored, original, "Authored spacing changed on reopen cycle \(cycle)")
            attach(fileWindow.screenshot(), name: "Blank paragraphs retained after reopen cycle \(cycle)")
        }
    }

    func testPasteAsPlainTextKeepsMarkdownCharactersLiteral() throws {
        let restore = restoreClipboardAfterTest()
        defer { restore() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launchPad()
        defer { app.terminate() }
        waitForEditor(app)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("**literal** & `code`", forType: .string)
        app.typeKey("v", modifierFlags: [.command, .option, .shift])
        let saved = try saveAs(app, directory: directory)
        let source = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(source.contains("\\*\\*literal\\*\\*"), source)
        XCTAssertTrue(source.contains("\\`code\\`"), source)
        app.typeKey("c", modifierFlags: [.command, .shift])
        waitForClipboard("**literal** & `code`")
        XCTAssertFalse(NSPasteboard.general.string(forType: .html)?.contains("<strong>") == true)
    }

    func testTableMenuCreatesEditableCellsAndSavesTheirStructure() throws {
        let restore = restoreClipboardAfterTest()
        defer { restore() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launchPad()
        defer { app.terminate() }
        waitForEditor(app)
        app.dialogs.firstMatch.menuButtons["formattingMenu"].firstMatch.click()
        app.menuItems["Table"].firstMatch.click()
        app.menuItems["Insert Table"].firstMatch.click()
        app.typeText("Name")
        app.typeKey(.tab, modifierFlags: [])
        app.typeText("Value")
        app.typeKey(.tab, modifierFlags: [])
        app.typeText("Alice")
        app.typeKey(.tab, modifierFlags: [])
        app.typeText("42")
        let saved = try saveAs(app, directory: directory)
        let source = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(source.contains("Name") && source.contains("Value"), source)
        XCTAssertTrue(source.range(of: #"\|\s*Alice\s*\|\s*42\s*\|"#, options: .regularExpression) != nil, source)
        app.typeKey("c", modifierFlags: [.command, .shift])
        let richTable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSPasteboard.general.string(forType: .html)?.contains("<table") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [richTable], timeout: 5), .completed)
    }

    private func restoreClipboardAfterTest() -> () -> Void {
        let previous = (NSPasteboard.general.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        return {
            NSPasteboard.general.clearContents()
            if !previous.isEmpty { NSPasteboard.general.writeObjects(previous) }
        }
    }

    func testCopyAndCopyAllKeepReadableCharactersFormattingAndSelection() throws {
        let previous = (NSPasteboard.general.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(previous)
        }
        let app = launchPad()
        defer { app.terminate() }
        waitForEditor(app)
        let source = "it;s removed? & other chars\n\nAnother **bold** line; literal `&#x20;` and target"
        let visible = "it;s removed? & other chars \n\nAnother bold line; literal &#x20; and target"
        paste(source, into: app)
        // Author a trailing space: Markdown parsing legitimately trims source whitespace.
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeText(" ")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        waitForClipboard(visible)
        XCTAssertTrue(NSPasteboard.general.string(forType: .html)?.contains("<strong>bold</strong>") == true)

        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.leftArrow, modifierFlags: [.option, .shift])
        NSPasteboard.general.clearContents()
        app.typeKey("c", modifierFlags: [.command, .shift])
        waitForClipboard(visible)
        XCTAssertTrue(NSPasteboard.general.string(forType: .html)?.contains("<strong>bold</strong>") == true)
        app.typeText("replacement")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        waitForClipboard(visible.replacingOccurrences(of: "target", with: "replacement"))
        attach(app.dialogs.firstMatch.screenshot(), name: "Copy All retains formatting and the selected replacement range")
    }

    func testPlainTextSoftLineBreaksSurviveFormatSwitchEditingAndReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launchPad()
        defer { app.terminate() }
        waitForEditor(app)
        let format = app.buttons["documentFormat"].firstMatch
        format.click()
        let plain = app.textViews.firstMatch
        XCTAssertTrue(plain.waitForExistence(timeout: 5), app.debugDescription)
        let source = "sdfsdf\n\nsadfsdfasdf\n\nasdfasdf\nsadfasdf"
        paste(source, into: app)
        app.typeKey("c", modifierFlags: [.command, .shift])
        waitForClipboard(source)
        format.click()
        waitForEditor(app)
        app.typeKey("c", modifierFlags: [.command, .shift])
        waitForClipboard(source)
        attach(app.dialogs.firstMatch.screenshot(), name: "TXT to Markdown keeps the final two lines separate")
        let html = try XCTUnwrap(NSPasteboard.general.string(forType: .html))
        XCTAssertTrue(html.contains("asdfasdf<br"), html)
        format.click()
        XCTAssertTrue(plain.waitForExistence(timeout: 5))
        XCTAssertEqual(plain.value as? String, source, "Untouched Markdown must retain exact TXT source")
        format.click()
        waitForEditor(app)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" edited")
        let saved = try saveAs(app, directory: directory)
        let expected = source + " edited"
        let persisted = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(persisted.contains("asdfasdf\nsadfasdf edited"), persisted)
        app.typeKey("n", modifierFlags: .command)
        waitForEditor(app)
        app.typeKey("o", modifierFlags: .command)
        open(saved, in: app)
        let fileWindow = app.windows[saved.lastPathComponent].firstMatch
        XCTAssertTrue(fileWindow.waitForExistence(timeout: 10), app.debugDescription)
        waitForEditor(app, in: fileWindow)
        app.typeKey("c", modifierFlags: [.command, .shift])
        waitForClipboard(expected)
        attach(fileWindow.screenshot(), name: "Edited Markdown reopened with separate soft-break lines")
    }

    private func waitForClipboard(_ expected: String) {
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSPasteboard.general.string(forType: .string) == expected
        }, object: nil)
        _ = XCTWaiter.wait(for: [copied], timeout: 5)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
    }

    private func launchPad() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-pad.onboardingCompleted", "YES", "-pad.format", "md", "-pad.saveAutomatically", "NO", "-pad.floating", "NO",
                               "-showInDock", "YES", "-menuBarItem", "NO", "-pad.editingShortcuts", "invalid"]
        app.launch()
        app.typeKey("n", modifierFlags: .command)
        return app
    }

    private func waitForEditor(_ app: XCUIApplication, in window: XCUIElement? = nil) {
        let surface = window ?? app.dialogs.firstMatch
        XCTAssertTrue(surface.webViews.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let toggle = surface.menuButtons["formattingMenu"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
    }

    private func paste(_ source: String, into app: XCUIApplication) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        app.typeKey("v", modifierFlags: .command)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pad-markdown-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func saveAs(_ app: XCUIApplication, directory: URL) throws -> URL {
        app.typeKey("s", modifierFlags: [.command, .shift])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(directory.path)
        app.typeKey(.return, modifierFlags: [])
        let save = sheet.buttons["OKButton"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        save.click()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed, app.debugDescription)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try XCTUnwrap(files.first { $0.pathExtension == "md" })
    }

    private func open(_ file: URL, in app: XCUIApplication) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(file.path)
        app.typeKey(.return, modifierFlags: [])
        let open = sheet.buttons["OKButton"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), app.debugDescription)
        open.click()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed, app.debugDescription)
    }

    private func waitForFile(_ file: URL, containing text: String) {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8).contains(text)) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed, "Saved Markdown did not contain \(text)")
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
