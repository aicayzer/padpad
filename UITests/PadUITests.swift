import AppKit
import XCTest

@MainActor
final class PadUITests: XCTestCase {
    func testRejectedRenameKeepsTitleAndReturnsTypingToEditor() {
        let app = launchPad()
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("Original text")
        app.typeKey("r", modifierFlags: .command)
        let name = app.textFields["Name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(name.value as? String, "Untitled")
        app.typeText("Invalid/name")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Untitled"].firstMatch.waitForExistence(timeout: 5))
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 5), .completed)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" still editable")
        expectValue("Original text still editable", in: editor)
    }

    func testRenameCommitsOnOutsideClickAndEscapeCancels() {
        let app = launchPad()
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.typeText("Keep this text")
        let stem = "Rename-\(UUID().uuidString)"
        app.typeKey("r", modifierFlags: .command)
        let name = app.textFields["Name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.typeText(stem)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).click()
        XCTAssertTrue(app.staticTexts["\(stem).txt"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(name.exists)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" still editable")
        expectValue("Keep this text still editable", in: editor)

        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.typeText("Cancel this name")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["\(stem).txt"].firstMatch.waitForExistence(timeout: 5))

        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.typeText("Invalid/name")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).click()
        let error = app.staticTexts["documentError"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["\(stem).txt"].firstMatch.exists)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" after error")
        expectValue("Keep this text still editable after error", in: editor)
    }

    func testSettingsPreservesScratchAndEditorAcceptsInput() throws {
        let app = launchPad()
        defer { app.terminate() }

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        attach(app.screenshot(), name: "Pad editor before input")
        var original = "Disposable Pad UI test \(UUID().uuidString)"
        // Do not click the editor first: launch must establish its keyboard focus.
        app.typeText(original)
        expectValue(original, in: editor)
        attach(app.screenshot(), name: "Pad editor after launch")

        app.staticTexts["Untitled"].firstMatch.doubleClick()
        app.typeText("UI Test Draft")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["UI Test Draft.txt"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.downArrow, modifierFlags: .command)
        let afterRename = "\nTyping after rename."
        app.typeText(afterRename)
        original += afterRename
        expectValue(original, in: editor)
        attach(app.screenshot(), name: "Pad title rename and continued input")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        selectTab("General", in: settings)
        let login = settings.staticTexts["Open at login"].firstMatch
        XCTAssertTrue(login.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(login.isHittable, app.debugDescription)
        expectValue(original, in: editor)
        attach(settings.screenshot(), name: "Pad Settings General")

        selectTab("Files", in: settings)
        XCTAssertTrue(settings.staticTexts["Save automatically"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        expectValue(original, in: editor)
        attach(settings.screenshot(), name: "Pad Settings Files")

        selectTab("Shortcuts", in: settings)
        XCTAssertTrue(settings.staticTexts["Show or hide PadPad Dev"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        expectValue(original, in: editor)
        attach(settings.screenshot(), name: "Pad Settings Shortcuts")

        // A native click returns from Settings without invoking document replacement or save.
        XCTAssertTrue(editor.exists, app.debugDescription)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        app.typeKey(.downArrow, modifierFlags: .command)
        let suffix = "\nStill editing after Settings."
        app.typeText(suffix)
        expectValue(original + suffix, in: editor)
        attach(app.screenshot(), name: "Pad editor after Settings")

        app.typeKey("n", modifierFlags: .command)
        let discard = app.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
        discard.click()
        expectValue("", in: editor)
        XCTAssertTrue(app.staticTexts["Untitled"].firstMatch.exists, app.debugDescription)
        app.typeText("Fresh disposable scratch")
        expectValue("Fresh disposable scratch", in: editor)
        attach(app.screenshot(), name: "Pad fresh file from Command N")

        app.typeKey(.escape, modifierFlags: [])
        let close = app.buttons["Close PadPad"].firstMatch
        let dismissed = NSPredicate(format: "exists == false OR hittable == false")
        expectation(for: dismissed, evaluatedWith: close)
        waitForExpectations(timeout: 5)
    }

    func testFloatingFolderSheetCancellationAndMouseClose() {
        let app = launchPad(floating: true)
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        let draft = "Disposable floating dialog draft"
        app.typeText(draft)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        selectTab("Files", in: settings)
        settings.buttons["saveFolderOptions"].click()
        app.menuItems["Choose Folder…"].click()
        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        let cancel = sheet.buttons["CancelButton"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(cancel.isHittable, app.debugDescription)
        attach(XCUIScreen.main.screenshot(), name: "Folder sheet above floating Settings and Pad")
        cancel.click()
        expectValue(draft, in: editor)
        let close = app.buttons["Close PadPad"].firstMatch
        // Settings remains key: the first click must work on Pad's inactive toolbar.
        XCTAssertTrue(close.isEnabled, app.debugDescription)
        XCTAssertTrue(close.isHittable, app.debugDescription)
        close.click()
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, app.debugDescription)
    }

    func testSavedFileHidesWithoutPromptAndReplacementOffersSave() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pad-ui-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = launchPad(floating: true)
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("Saved content")
        app.typeKey("s", modifierFlags: [.command, .shift])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(directory.path)
        app.typeKey(.return, modifierFlags: [])
        let save = sheet.buttons["OKButton"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        save.click()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" with unsaved changes")
        let close = app.buttons["Close PadPad"].firstMatch
        close.click()
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["Discard Changes"].firstMatch.exists)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        finder.menuBars.firstMatch.typeKey("p", modifierFlags: [.control, .option, .shift, .command])
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        expectValue("Saved content with unsaved changes", in: editor)
        let saved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "Saved content")

        app.typeKey("n", modifierFlags: .command)
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Save Changes"].firstMatch.isHittable)
        let alert = app.dialogs.containing(.button, identifier: "Discard Changes").firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        let screen = try XCTUnwrap(NSScreen.main)
        XCTAssertEqual(alert.frame.midX, screen.visibleFrame.midX, accuracy: 3)
        XCTAssertEqual(alert.frame.midY, screen.frame.maxY - screen.visibleFrame.midY, accuracy: 3)
        attach(XCUIScreen.main.screenshot(), name: "Centered save decision above floating Pad")
        cancel.click()
        expectValue("Saved content with unsaved changes", in: editor)
        app.typeKey("n", modifierFlags: .command)
        app.buttons["Save Changes"].firstMatch.click()
        expectValue("", in: editor)
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "Saved content with unsaved changes")
    }

    func testGlobalShortcutOpensOverFinderAndReturnsFocus() {
        let app = launchPad()
        defer { app.terminate() }
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        selectTab("Shortcuts", in: settings)
        expectValue("⌃⌥⇧⌘P", in: settings.searchFields.firstMatch)
        attach(settings.screenshot(), name: "Effective development shortcut")
        let shortcutDescription = XCTAttachment(string: settings.debugDescription)
        shortcutDescription.name = "Effective shortcut accessibility state"
        shortcutDescription.lifetime = .keepAlways
        add(shortcutDescription)
        settings.buttons["_XCUI:CloseWindow"].click()
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        let close = app.buttons["Close PadPad"].firstMatch
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)

        // Finder can have no window; use its on-screen menu bar as the event target.
        let finderMenuBar = finder.menuBars.firstMatch
        XCTAssertTrue(finderMenuBar.waitForExistence(timeout: 5), finder.debugDescription)
        XCTAssertGreaterThan(finderMenuBar.frame.width, 0)
        finderMenuBar.typeKey("p", modifierFlags: [.control, .option, .command, .shift])
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, app.debugDescription)
        attach(app.screenshot(), name: "Pad opened with development global shortcut")
        finderMenuBar.typeKey("p", modifierFlags: [.control, .option, .command, .shift])
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
    }

    func testCancelingNativeFilePanelsAndSharingPreservesScratch() {
        let app = launchPad(floating: true)
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        var expected = "Disposable dialog test \(UUID().uuidString)"
        app.typeText(expected)
        expectValue(expected, in: editor)

        app.typeKey("s", modifierFlags: [.command, .shift])
        let saveCancel = app.buttons["CancelButton"].firstMatch
        XCTAssertTrue(saveCancel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(saveCancel.isHittable, app.debugDescription)
        saveCancel.click()
        expectValue(expected, in: editor)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("\nAfter canceled Save As.")
        expected += "\nAfter canceled Save As."
        expectValue(expected, in: editor)

        app.typeKey("o", modifierFlags: .command)
        let openCancel = app.buttons["CancelButton"].firstMatch
        XCTAssertTrue(openCancel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(openCancel.isHittable, app.debugDescription)
        openCancel.click()
        expectValue(expected, in: editor)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("\nAfter canceled Open.")
        expected += "\nAfter canceled Open."
        expectValue(expected, in: editor)

        app.buttons["Share"].firstMatch.click()
        let picker = app.popovers["ShareSheet.Popover"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(picker.frame.width, 0)
        let sharingState = XCTAttachment(string: app.debugDescription)
        sharingState.name = "Native sharing picker accessibility state"
        sharingState.lifetime = .keepAlways
        add(sharingState)
        attach(XCUIScreen.main.screenshot(), name: "Native sharing picker")
        app.typeKey(.escape, modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        expectValue(expected, in: editor)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("\nAfter canceled Share.")
        expected += "\nAfter canceled Share."
        expectValue(expected, in: editor)
        attach(app.screenshot(), name: "Scratch preserved after native dialogs and sharing")
    }

    func testCustomEditingShortcutAndRestoreDefaults() {
        let app = launchPad()
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.typeText("Disposable shortcut draft")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        selectTab("Shortcuts", in: settings)
        let recorder = settings.searchFields["editingShortcut.newFile"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 5), settings.debugDescription)
        expectValue("⌘N", in: recorder)
        recorder.click()
        app.typeKey("b", modifierFlags: [.command, .shift])
        expectValue("⇧⌘B", in: recorder)
        attach(settings.screenshot(), name: "Custom local editing shortcut")
        settings.buttons["_XCUI:CloseWindow"].click()
        editor.click()
        app.typeKey("n", modifierFlags: .command)
        expectValue("Disposable shortcut draft", in: editor)
        app.typeKey("b", modifierFlags: [.command, .shift])
        let discard = app.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
        discard.click()
        expectValue("", in: editor)
        app.typeText("Draft after custom shortcut")
        expectValue("Draft after custom shortcut", in: editor)

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        selectTab("Shortcuts", in: settings)
        settings.buttons["Restore Defaults"].click()
        expectValue("⌘N", in: recorder)
        settings.buttons["_XCUI:CloseWindow"].click()
        editor.click()
        app.typeKey("b", modifierFlags: [.command, .shift])
        expectValue("Draft after custom shortcut", in: editor)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
        discard.click()
        expectValue("", in: editor)
        attach(app.screenshot(), name: "Restored New Draft shortcut")
    }

    func testDockToggleKeepsSettingsAndDraftUsable() throws {
        let app = launchPad()
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let draft = "Disposable Dock visibility draft"
        app.typeText(draft)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        selectTab("General", in: settings)
        let dock = settings.popUpButtons["appAccess"]
        XCTAssertTrue(dock.waitForExistence(timeout: 5), settings.debugDescription)
        let testBundleID = try XCTUnwrap(Bundle(for: Self.self).bundleIdentifier)
        XCTAssertTrue(testBundleID.hasSuffix(".uitests"))
        let targetBundleID = String(testBundleID.dropLast(".uitests".count))
        let matchingProcesses = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID)
        XCTAssertEqual(matchingProcesses.count, 1)
        let process = try XCTUnwrap(matchingProcesses.first)
        let initialRegular = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "activationPolicy == %d", NSApplication.ActivationPolicy.regular.rawValue),
            object: process)
        XCTAssertEqual(XCTWaiter.wait(for: [initialRegular], timeout: 5), .completed)
        dock.click()
        app.menuItems["Menu bar"].click()
        let accessory = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "activationPolicy == %d", NSApplication.ActivationPolicy.accessory.rawValue),
            object: process)
        XCTAssertEqual(XCTWaiter.wait(for: [accessory], timeout: 5), .completed)
        let staysActive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "active == true"), object: process)
        XCTAssertEqual(XCTWaiter.wait(for: [staysActive], timeout: 5), .completed,
                       "Changing access must keep Settings active without a test-driven activation")
        XCTAssertTrue(editor.exists, "Changing access must not dismiss the draft behind Settings")
        selectTab("Files", in: settings)
        XCTAssertTrue(settings.staticTexts["Save automatically"].firstMatch.waitForExistence(timeout: 5))
        expectValue(draft, in: editor)
        selectTab("General", in: settings)
        attach(settings.screenshot(), name: "Settings remains usable without Dock icon")
        dock.click()
        app.menuItems["Dock"].click()
        let regular = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "activationPolicy == %d", NSApplication.ActivationPolicy.regular.rawValue),
            object: process)
        XCTAssertEqual(XCTWaiter.wait(for: [regular], timeout: 5), .completed)
        dock.click()
        app.menuItems["Dock and menu bar"].click()
        let bothRegular = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "activationPolicy == %d", NSApplication.ActivationPolicy.regular.rawValue),
            object: process)
        XCTAssertEqual(XCTWaiter.wait(for: [bothRegular], timeout: 5), .completed)
        expectValue("Dock and menu bar", in: dock)
        attach(settings.screenshot(), name: "Dock and menu bar access selected")
        selectTab("Shortcuts", in: settings)
        XCTAssertTrue(settings.staticTexts["Show or hide PadPad Dev"].firstMatch.waitForExistence(timeout: 5))
        settings.buttons["_XCUI:CloseWindow"].click()
        editor.click()
        expectValue(draft, in: editor)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" still editing")
        expectValue(draft + " still editing", in: editor)
        attach(app.screenshot(), name: "Draft preserved through Dock visibility changes")
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        let close = app.buttons["Close PadPad"].firstMatch
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "A real departure must still dismiss the draft after the access transition")
    }

    func testSettingsPagesLightDarkAndInactiveAppearance() throws {
        let app = launchPad()
        defer { app.terminate() }
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeText("Disposable Settings appearance draft")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        selectTab("General", in: settings)
        let appearance = settings.popUpButtons["appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), settings.debugDescription)
        let originalAppearance = try XCTUnwrap(appearance.value as? String)
        XCTAssertTrue(["System", "Light", "Dark"].contains(originalAppearance))
        defer {
            app.activate()
            selectTab("General", in: settings)
            appearance.click()
            app.menuItems[originalAppearance].click()
        }
        // Availability is covered here; changing login registration needs a separate installed-app check.
        XCTAssertTrue(settings.staticTexts["Open at login"].firstMatch.exists, settings.debugDescription)
        for mode in ["Light", "Dark"] {
            selectTab("General", in: settings)
            appearance.click()
            app.menuItems[mode].click()
            expectValue(mode, in: appearance)
            XCTAssertTrue(appearance.isEnabled)
            attach(settings.screenshot(), name: "Settings General \(mode)")
            selectTab("Files", in: settings)
            XCTAssertTrue(settings.staticTexts["Save automatically"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(settings.popUpButtons["draftLifetime"].firstMatch.isEnabled)
            attach(settings.screenshot(), name: "Settings Files \(mode)")
            selectTab("Shortcuts", in: settings)
            XCTAssertTrue(settings.staticTexts["Show or hide PadPad Dev"].firstMatch.waitForExistence(timeout: 5))
            attach(settings.screenshot(), name: "Settings Shortcuts \(mode)")
            selectTab("About", in: settings)
            XCTAssertTrue(settings.staticTexts["A place for text and Markdown."].firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(settings.staticTexts["Open at login"].firstMatch.exists)
            attach(settings.screenshot(), name: "Settings About \(mode)")
        }
        selectTab("General", in: settings)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(settings.exists, app.debugDescription)
        XCTAssertTrue(appearance.isEnabled, "Inactive appearance must not disable Settings controls")
        attach(settings.screenshot(), name: "Inactive Settings retains enabled controls")
        app.activate()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        selectTab("Files", in: settings)
        XCTAssertTrue(settings.buttons["saveFolderOptions"].firstMatch.isEnabled)
        attach(settings.screenshot(), name: "Settings active again after Finder")
    }

    func testMinimizedSettingsDoesNotChangeMenuBarActivationPolicy() throws {
        let app = launchPad()
        defer { app.terminate() }
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        selectTab("General", in: settings)
        let minimize = settings.buttons["_XCUI:MinimizeWindow"].firstMatch
        guard minimize.exists, minimize.isEnabled else {
            attach(settings.screenshot(), name: "Settings does not offer minimization")
            throw XCTSkip("Settings does not offer an enabled minimize control; minimized-window Dock behavior was not exercised.")
        }
        let bundleID = try XCTUnwrap(Bundle(for: Self.self).bundleIdentifier)
        XCTAssertTrue(bundleID.hasSuffix(".uitests"))
        let target = String(bundleID.dropLast(".uitests".count))
        let process = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: target).first)
        let access = settings.popUpButtons["appAccess"]
        access.click()
        app.menuItems["Menu bar"].click()
        expectValue("Menu bar", in: access)
        XCTAssertEqual(process.activationPolicy, .accessory)
        minimize.click()
        let minimized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: access)
        XCTAssertEqual(XCTWaiter.wait(for: [minimized], timeout: 5), .completed)
        // A minimized-window thumbnail is independent of a running-app Dock icon.
        XCTAssertEqual(process.activationPolicy, .accessory)
        attach(XCUIScreen.main.screenshot(), name: "Minimized Settings with accessory activation policy")
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: access)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed, app.debugDescription)
        XCTAssertEqual(process.activationPolicy, .accessory)
        expectValue("Menu bar", in: access)
        attach(settings.screenshot(), name: "Settings reopened with menu bar access unchanged")
    }

    func testMenuBarOnlyFloatingStartupStaysOutOfRunningDockItems() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-pad.onboardingCompleted", "YES", "-pad.format", "txt", "-pad.saveAutomatically", "NO", "-pad.floating", "YES",
                               "-showInDock", "NO", "-menuBarItem", "YES", "-pad.editingShortcuts", "invalid",
                               "-KeyboardShortcuts_pad", #""{\"carbonKeyCode\":11,\"carbonModifiers\":6400}""#]
        app.launch()
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertFalse(editor.exists, "Initial launch must keep the draft hidden")
        let testBundle = try XCTUnwrap(Bundle(for: Self.self).bundleIdentifier)
        XCTAssertTrue(testBundle.hasSuffix(".uitests"))
        let target = String(testBundle.dropLast(".uitests".count))
        let process = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: target).first)
        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        let targetName = try XCTUnwrap(process.localizedName)
        let matchingDockItems = dock.descendants(matching: .dockItem).matching(NSPredicate(format: "label == %@", targetName))

        func checkDock(_ stage: String) {
            let accessory = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "activationPolicy == %d", NSApplication.ActivationPolicy.accessory.rawValue),
                object: process)
            XCTAssertEqual(XCTWaiter.wait(for: [accessory], timeout: 5), .completed, stage)
            let preferences = UserDefaults(suiteName: "com.apple.dock")
            func recorded(_ key: String) -> Bool {
                let tiles = preferences?.array(forKey: key) as? [[String: Any]] ?? []
                return tiles.contains { tile in
                    let data = tile["tile-data"] as? [String: Any] ?? [:]
                    return data["bundle-identifier"] as? String == target || data["file-label"] as? String == targetName
                }
            }
            let pinned = recorded("persistent-apps")
            let recent = recorded("recent-apps")
            if !pinned && !recent {
                let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: matchingDockItems)
                XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 5), .completed,
                               "Unexpected unpinned application Dock item at \(stage)")
            }
            let details = "Stage: \(stage)\nActivation policy: \(process.activationPolicy.rawValue) (accessory expected)\nPinned: \(pinned)\nRecent: \(recent)\nExact application-name items: \(matchingDockItems.count)\n" +
                matchingDockItems.allElementsBoundByIndex.map { $0.debugDescription }.joined(separator: "\n")
            let evidence = XCTAttachment(string: details)
            evidence.name = "Dock classification - \(stage)"
            evidence.lifetime = .keepAlways
            add(evidence)
            attach(XCUIScreen.main.screenshot(), name: "Menu bar startup - \(stage)")
        }

        checkDock("hidden launch")
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        let finderMenu = finder.menuBars.firstMatch
        XCTAssertTrue(finderMenu.waitForExistence(timeout: 5))
        finderMenu.typeKey("b", modifierFlags: [.control, .option, .command])
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        checkDock("first shortcut opening")
        let draft = "Disposable menu bar floating startup draft"
        app.typeText(draft)
        expectValue(draft, in: editor)
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        let close = app.buttons["Close PadPad"].firstMatch
        for iteration in 1...3 {
            finderMenu.typeKey("b", modifierFlags: [.control, .option, .command])
            let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, app.debugDescription)
            expectValue(draft, in: editor)
            checkDock("shortcut opened \(iteration)")
            finderMenu.typeKey("b", modifierFlags: [.control, .option, .command])
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, app.debugDescription)
            XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
            checkDock("shortcut hidden \(iteration)")
        }
        finderMenu.typeKey("b", modifierFlags: [.control, .option, .command])
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        selectTab("General", in: settings)
        expectValue("Menu bar", in: settings.popUpButtons["appAccess"])
        XCTAssertTrue(settings.staticTexts["Open at login"].firstMatch.exists)
        XCTAssertTrue(settings.staticTexts["Keep quick pad on top"].firstMatch.exists)
        checkDock("Settings open")
        selectTab("Shortcuts", in: settings)
        expectValue("⌃⌥⌘B", in: settings.searchFields.firstMatch)
        settings.buttons["_XCUI:CloseWindow"].click()
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        expectValue(draft, in: editor)
        checkDock("Settings returned to editor")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        finderMenu.typeKey("b", modifierFlags: [.control, .option, .command])
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        checkDock("shortcut after Settings")

        // Login registration is intentionally untouched. A real login launch requires separate verification.
        app.terminate()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "terminated == true"), object: process)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        let afterQuit = XCTAttachment(string: "Exact application-name Dock items after termination: \(matchingDockItems.count)\n" +
            matchingDockItems.allElementsBoundByIndex.map { $0.debugDescription }.joined(separator: "\n"))
        afterQuit.name = "Dock item persistence after app termination"
        afterQuit.lifetime = .keepAlways
        add(afterQuit)
    }

    func testSavedMenuBarAccessSurvivesColdLaunch() throws {
        let app = launchPad(floating: true)
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        selectTab("General", in: settings)
        settings.popUpButtons["appAccess"].click()
        app.menuItems["Menu bar"].click()
        expectValue("Menu bar", in: settings.popUpButtons["appAccess"])
        app.terminate()

        // A stored preference must work without the launch overrides used by the other scenarios.
        for key in ["-showInDock", "-menuBarItem"] {
            if let index = app.launchArguments.firstIndex(of: key) {
                app.launchArguments.removeSubrange(index...index + 1)
            }
        }
        app.launch()
        XCTAssertEqual(app.windows.count, 0, "Cold launch must not restore an editor or Settings window")
        let bundleID = try XCTUnwrap(Bundle(for: Self.self).bundleIdentifier)
        let process = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: String(bundleID.dropLast(".uitests".count))).first)
        let accessory = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "activationPolicy == %d", NSApplication.ActivationPolicy.accessory.rawValue),
            object: process)
        XCTAssertEqual(XCTWaiter.wait(for: [accessory], timeout: 5), .completed)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        finder.menuBars.firstMatch.typeKey("p", modifierFlags: [.control, .option, .command, .shift])
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(process.activationPolicy, .accessory)
        attach(app.screenshot(), name: "Stored menu bar access after cold launch and shortcut")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        selectTab("General", in: settings)
        settings.popUpButtons["appAccess"].click()
        app.menuItems["Dock and menu bar"].click()
    }

    func testOptionShiftBReopensHiddenMarkdownFromFinder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-pad.onboardingCompleted", "YES", "-pad.format", "md",
                               "-pad.saveAutomatically", "NO", "-pad.floating", "YES",
                               "-showInDock", "YES", "-menuBarItem", "NO",
                               "-KeyboardShortcuts_pad", #""{\"carbonKeyCode\":11,\"carbonModifiers\":2560}""#]
        app.launch()
        defer { app.terminate() }
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let close = app.buttons["Close PadPad"].firstMatch
        XCTAssertFalse(close.exists)
        finder.activate()
        finder.typeKey("b", modifierFlags: [.option, .shift])
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.menuButtons["formattingMenu"].firstMatch.waitForExistence(timeout: 10))
        app.typeText("Retained Markdown")
        finder.activate()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        finder.typeKey("b", modifierFlags: [.option, .shift])
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The shortcut must show hidden Markdown before snapshotting")
    }

    func testFirstSaveRequestsFolderAndRemembersAccessAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pad-folder-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launchPad()
        app.terminate()
        app.launchArguments += ["-pad.folderBookmark", "invalid"]
        app.launch()
        app.typeKey("n", modifierFlags: .command)
        defer { app.terminate() }
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("Folder permission draft")
        app.typeKey("s", modifierFlags: .command)
        let cancel = app.buttons["CancelButton"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        cancel.click()
        expectValue("Folder permission draft", in: editor)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        editor.click()
        app.typeKey(.end, modifierFlags: .command)
        app.typeText(" retained")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey("a", modifierFlags: .command)
        app.typeText(root.path)
        app.typeKey(.return, modifierFlags: [])
        // The Touch Bar duplicates the label; target the picker’s dialog button.
        let useFolder = app.dialogs["open-panel"].buttons["OKButton"].firstMatch
        XCTAssertTrue(useFolder.waitForExistence(timeout: 5), app.debugDescription)
        useFolder.click()
        let saved = NSPredicate { _, _ in
            (try? FileManager.default.contentsOfDirectory(atPath: root.path).count) == 1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 5), .completed)
        app.terminate()
        app.launchArguments.removeLast(2)
        app.launch()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("Remembered folder draft")
        app.typeKey("s", modifierFlags: .command)
        let twoFiles = NSPredicate { _, _ in
            (try? FileManager.default.contentsOfDirectory(atPath: root.path).count) == 2
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: twoFiles, object: nil)], timeout: 5), .completed)
        XCTAssertFalse(cancel.exists, app.debugDescription)
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(contents.contains("Folder permission draft retained"), contents.description)
        XCTAssertTrue(contents.contains("Remembered folder draft"), contents.description)
    }

    private func launchPad(floating: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Launch overrides establish a deterministic initial state without changing saved values.
        app.launchArguments = ["-pad.onboardingCompleted", "YES", "-pad.format", "txt", "-pad.saveAutomatically", "NO", "-pad.floating", floating ? "YES" : "NO",
                               "-showInDock", "YES", "-menuBarItem", "NO",
                               "-pad.editingShortcuts", "invalid",
                               "-KeyboardShortcuts_pad", #""{\"carbonKeyCode\":35,\"carbonModifiers\":6912}""#]
        app.launch()
        XCTAssertFalse(app.textViews.firstMatch.exists, "Initial launch must keep the draft hidden")
        app.typeKey("n", modifierFlags: .command)
        return app
    }

    private func selectTab(_ title: String, in settings: XCUIElement) {
        let tab = settings.toolbars.buttons[title].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), settings.debugDescription)
        XCTAssertTrue(tab.isHittable, settings.debugDescription)
        tab.click()
    }

    private func expectValue(_ expected: String, in element: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        let matches = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected \(String(reflecting: expected)); actual \(String(describing: element.value))",
                       file: file, line: line)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
