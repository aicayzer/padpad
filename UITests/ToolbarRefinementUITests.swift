import AppKit
import XCTest

@MainActor
final class ToolbarRefinementUITests: XCTestCase {
    func testCompactTitleAndFormattingMenu() {
        let restoreClipboard = clipboardRestoration()
        defer { restoreClipboard() }
        let app = launchPad(format: "md")
        defer { app.terminate() }
        let toggle = app.menuButtons["formattingMenu"].firstMatch
        expectReady(toggle)
        let frame = app.dialogs.firstMatch.frame
        XCTAssertEqual(frame.width, 740, accuracy: 1)
        XCTAssertEqual(frame.height, 480, accuracy: 1)
        app.typeText("Selected words")
        let title = app.staticTexts["documentTitle"].firstMatch
        title.doubleClick()
        let name = app.textFields["Name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(name.value as? String, "Untitled")
        XCTAssertFalse(app.staticTexts[".md"].exists, "Rename edits only the name")
        app.typeText("Small")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Small.md"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        for level in 1...3 {
            for _ in 0..<2 {
                toggle.click()
                app.menuItems["Headings"].firstMatch.click()
                let command = app.menuItems["Heading \(level)"].firstMatch
                XCTAssertTrue(command.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertFalse(app.menuItems["Body"].exists)
                command.click()
            }
        }
        toggle.click()
        app.menuItems["Text style"].firstMatch.click()
        app.menuItems["Bold"].firstMatch.click()
        // Menu actions retain the selected text and restore editing focus.
        app.typeText("Replacement")
        app.typeKey("c", modifierFlags: [.command, .shift])
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSPasteboard.general.string(forType: .string) == "Replacement"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed)
        attach(app.dialogs.firstMatch.screenshot(), name: "Bare toolbar selected formatting")
    }

    func testFormatSwitchVisibilityKeepsPlainTextAndNativeEditing() {
        let restoreClipboard = clipboardRestoration()
        defer { restoreClipboard() }
        let app = launchPad(format: "txt")
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        let source = "First short line\nSecond line\n\nWrapped text that stays editable."
        app.typeText(source)
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeKey(.downArrow, modifierFlags: [.shift, .command])
        attach(app.dialogs.firstMatch.screenshot(), name: "TXT selected paragraphs hug text")
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), source)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.toolbars.buttons["Files"].click()
        let option = settings.switches["showFormatToggle"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.click()
        XCTAssertFalse(app.menuButtons["documentFormat"].exists)
        XCTAssertEqual(editor.value as? String, source)
        option.click()
        XCTAssertTrue(app.menuButtons["documentFormat"].exists)
        XCTAssertEqual(app.menuButtons["documentFormat"].value as? String, "TXT")
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Changed")
        expectValue("Changed", in: editor)
        app.typeKey("z", modifierFlags: .command)
        expectValue(source, in: editor)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" é")
        expectValue(source + " é", in: editor)
        attach(app.dialogs.firstMatch.screenshot(), name: "TXT native undo and accented editing")
    }

    func testLongFilenameAndFormattingMenuAtEveryWidth() {
        for appearance in ["light", "dark"] {
            let app = launchPad(format: "md", appearance: appearance)
            let toggle = app.menuButtons["formattingMenu"].firstMatch
            expectReady(toggle)
            app.typeText("A selected paragraph")
            app.staticTexts["documentTitle"].firstMatch.doubleClick()
            app.typeText(String(repeating: "Long filename ", count: 8))
            app.typeKey(.return, modifierFlags: [])
            app.typeKey("a", modifierFlags: .command)
            let window = app.dialogs.firstMatch
            for width in [820.0, 700.0, 520.0] {
                let frame = window.frame
                app.activate()
                let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                    .withOffset(CGVector(dx: 1, dy: 0))
                let destination = window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: width + 1, dy: frame.height / 2))
                edge.click(forDuration: 0.2, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.2)
                XCTAssertEqual(window.frame.width, width, accuracy: 4)
                let title = app.staticTexts["documentTitle"].firstMatch
                XCTAssertLessThan(title.frame.maxX, toggle.frame.minX)
                XCTAssertTrue(toggle.isHittable)
                XCTAssertTrue(app.buttons["Save"].firstMatch.isHittable)
                XCTAssertFalse(app.menuButtons["formattingOverflow"].exists)
                toggle.click()
                XCTAssertTrue(app.menuItems["Quote"].firstMatch.waitForExistence(timeout: 5))
                app.typeKey(.escape, modifierFlags: [])
                attach(window.screenshot(), name: "\(appearance) long title and formatting at \(Int(width)) points")
                title.doubleClick()
                let field = app.textFields["Name"].firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts[".md"].exists)
                XCTAssertLessThan(field.frame.maxX, toggle.frame.minX)
                app.typeKey(.escape, modifierFlags: [])
            }
            app.terminate()
        }
    }

    private func clipboardRestoration() -> @MainActor () -> Void {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        return {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

    private func launchPad(format: String, appearance: String = "dark") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-pad.onboardingCompleted", "YES", "-pad.format", format,
                               "-pad.saveAutomatically", "NO", "-pad.floating", "NO",
                               "-quickPadWidth", "740", "-quickPadHeight", "480",
                               "-showInDock", "YES", "-menuBarItem", "NO", "-showFormatToggle", "YES", "-appearance", appearance]
        app.launchArguments += sharedUITestLaunchArguments
        app.launch()
        app.typeKey("n", modifierFlags: .command)
        return app
    }

    private func expectReady(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    private func expectValue(_ value: String, in element: XCUIElement) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed, element.debugDescription)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
