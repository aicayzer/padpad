import AppKit
import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    func testFirstSummonPracticesGlobalShortcutWithoutAdvancingOnRepeat() throws {
        let app = launchPad()
        defer { app.terminate() }
        summonIntroduction(app)
        attach(app.dialogs.firstMatch.screenshot(), name: "First intentional summon introduces PadPad")

        let start = app.buttons["onboardingStartPractice"].firstMatch
        expectHittable(start)
        XCTAssertEqual(start.label, "Next")
        XCTAssertTrue(app.staticTexts["Your Pad for Thought"].exists)
        XCTAssertFalse(app.buttons["onboardingDetails"].exists)
        let skip = app.buttons["onboardingSkip"].firstMatch
        XCTAssertLessThan(skip.frame.maxX, start.frame.minX)
        XCTAssertEqual(skip.frame.midY, start.frame.midY, accuracy: 2)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(element("onboardingPractice", in: app).waitForExistence(timeout: 5))
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(element("onboardingIntro", in: app).waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        let practice = element("onboardingPractice", in: app)
        XCTAssertTrue(practice.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(element("onboardingDone", in: app).exists)
        XCTAssertTrue(app.staticTexts["Try your shortcut."].exists)
        let finish = app.buttons["onboardingContinue"].firstMatch
        XCTAssertTrue(finish.exists)
        XCTAssertEqual(finish.label, "Done")
        XCTAssertFalse(finish.isEnabled)
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(practice.exists, "Return and Right must not bypass shortcut practice")
        XCTAssertFalse(app.buttons["documentFormat"].exists)
        attach(app.dialogs.firstMatch.screenshot(), name: "Shortcut practice keeps Done visible and disabled")
        let explanationFrame = element("onboardingPracticeExplanation", in: app).frame
        let shortcut = element("onboardingShortcut", in: app)
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(shortcut.label.contains("⌃⌥⇧⌘P") ||
                      (shortcut.value as? String)?.contains("⌃⌥⇧⌘P") == true,
                      "Practice must show the configured fixture chord: \(shortcut.debugDescription)")

        pressGlobalShortcutFromFinder()
        expectValue("Practiced 1 times", in: shortcut)
        let done = element("onboardingDone", in: app)
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(done.label, "Nice, it’s that simple.")
        let practicedFrame = element("onboardingPracticeExplanation", in: app).frame
        XCTAssertEqual(practicedFrame.minY, explanationFrame.minY, accuracy: 1,
                       "Shortcut practice must retain the description position")
        XCTAssertEqual(practicedFrame.height, explanationFrame.height, accuracy: 1,
                       "Both shortcut practice descriptions must occupy two lines")
        XCTAssertTrue(practice.exists, "Practicing must leave the onboarding visible")
        XCTAssertFalse(app.buttons["documentFormat"].exists, "The editor must not appear before Continue")
        attach(app.dialogs.firstMatch.screenshot(), name: "Real global shortcut acknowledged in native onboarding")

        // A second global invocation must stay in practice, not open or dismiss the editor.
        pressGlobalShortcutFromFinder()
        expectValue("Practiced 2 times", in: shortcut)
        XCTAssertTrue(done.exists, app.debugDescription)
        XCTAssertTrue(practice.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["documentFormat"].exists, app.debugDescription)
        expectHittable(finish)
        XCTAssertTrue(finish.isEnabled)
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(element("onboardingIntro", in: app).waitForExistence(timeout: 5))
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(practice.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isEnabled, "Back and Next retain successful practice")
        app.typeKey(.return, modifierFlags: [])
        waitForMarkdownEditor(app)
        XCTAssertFalse(practice.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["Bold"].exists, "Formatting starts hidden")
        attach(app.dialogs.firstMatch.screenshot(), name: "Practice finishes in a real editable Markdown example")

        switchToText(app)
        let text = app.textViews.firstMatch
        let source = try XCTUnwrap(text.value as? String)
        XCTAssertTrue(source.hasPrefix("# "), "The example should have a Markdown heading: \(source)")
        XCTAssertTrue(source.contains("- "), "The example should include a useful action list: \(source)")
        text.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("\nNative shortcut practice verified")
        expectTextContaining("Native shortcut practice verified", in: text)
    }

    func testSkipAndFormatRoundTripRetainEditableMarkdownInDarkAppearance() throws {
        let app = launchPad(appearance: "dark")
        defer { app.terminate() }
        summonIntroduction(app)
        attach(app.dialogs.firstMatch.screenshot(), name: "Native onboarding in Dark appearance")
        let skip = app.buttons["onboardingSkip"].firstMatch
        app.typeKey(.tab, modifierFlags: [])
        for _ in 0..<5 {
            if skip.debugDescription.components(separatedBy: .newlines).first?.contains("Keyboard Focused") == true { break }
            app.typeKey(.tab, modifierFlags: [])
        }
        XCTAssertTrue(skip.debugDescription.components(separatedBy: .newlines).first?.contains("Keyboard Focused") == true,
                      "Skip must be reachable by Tab: \(skip.debugDescription)")
        app.typeKey(.space, modifierFlags: [])
        waitForMarkdownEditor(app)
        switchToText(app)

        let text = app.textViews.firstMatch
        let source = "# Disposable plan\n\nKeep **this exact sentence**.\n\n- Bring the draft\n- Agree the owner\n"
        replaceText(source, in: text, app: app)
        expectValue(source, in: text)
        app.buttons["documentFormat"].click()
        waitForMarkdownEditor(app)
        XCTAssertFalse(app.buttons["Bold"].exists)
        attach(app.dialogs.firstMatch.screenshot(), name: "Plain source becomes editable formatted Markdown")

        // Loading formatted content alone must retain the exact original source.
        switchToText(app)
        expectValue(source, in: app.textViews.firstMatch)
        app.buttons["documentFormat"].click()
        waitForMarkdownEditor(app)
        let web = app.webViews.firstMatch
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Edited in the formatted surface")

        switchToText(app)
        expectTextContaining("Edited in the formatted surface", in: app.textViews.firstMatch)
        let edited = try XCTUnwrap(app.textViews.firstMatch.value as? String)
        XCTAssertTrue(edited.contains("# Disposable plan"), edited)
        XCTAssertTrue(edited.contains("**this exact sentence**"), edited)
        XCTAssertTrue(edited.contains("Bring the draft"), edited)
        attach(app.dialogs.firstMatch.screenshot(), name: "Markdown source includes the formatted editor change")
        app.buttons["documentFormat"].hover()
        attach(app.dialogs.firstMatch.screenshot(), name: "Format button with quiet hover background")
    }

    func testNoShortcutCanSkipWithoutPretendingPracticeSucceeded() {
        let app = launchPad(accent: "custom", globalShortcutEnabled: false, customAccent: "216E4E")
        defer { app.terminate() }
        summonIntroduction(app)
        attach(app.dialogs.firstMatch.screenshot(), name: "Primary onboarding action respects a custom green accent")
        app.buttons["onboardingStartPractice"].click()
        let shortcut = element("onboardingShortcut", in: app)
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        XCTAssertEqual(shortcut.label, "No global shortcut configured")
        XCTAssertFalse(app.buttons["onboardingContinue"].isEnabled)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("onboardingPractice", in: app).exists)
        attach(app.dialogs.firstMatch.screenshot(), name: "No shortcut offers a clear Skip path")
        app.buttons["onboardingSkip"].click()
        waitForMarkdownEditor(app)
        switchToText(app)
        expectValue("", in: app.textViews.firstMatch)
    }

    func testIntroductionReplayThenSkipPreservesTheCurrentDraft() {
        let app = launchPad(completed: true, format: "txt")
        defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let text = app.textViews.firstMatch
        expectHittable(text)
        let draft = "Draft retained through onboarding replay.\nKeep the second line too."
        replaceText(draft, in: text, app: app)
        expectValue(draft, in: text)

        app.menuBars.menuBarItems["Help"].click()
        let replay = app.menuItems["Show PadPad Introduction"].firstMatch
        expectHittable(replay)
        replay.click()
        XCTAssertTrue(element("onboardingIntro", in: app).waitForExistence(timeout: 5), app.debugDescription)
        attach(app.dialogs.firstMatch.screenshot(), name: "Onboarding replay preserves an existing draft behind it")
        let skip = app.buttons["onboardingSkip"].firstMatch
        expectHittable(skip)
        skip.click()
        expectValue("TXT", in: app.buttons["documentFormat"].firstMatch)
        expectHittable(app.textViews.firstMatch)
        expectValue(draft, in: app.textViews.firstMatch)
        XCTAssertFalse(element("onboardingIntro", in: app).exists)

        // The restored draft must remain editable rather than being a retained screenshot.
        app.textViews.firstMatch.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("\nAnd continue editing.")
        expectValue(draft + "\nAnd continue editing.", in: app.textViews.firstMatch)
        attach(app.dialogs.firstMatch.screenshot(), name: "Existing draft restored and edited after skipping replay")
    }

    func testResetAppRequiresConfirmationAndCancellationPreservesWriting() {
        let app = launchPad(completed: true, format: "txt")
        defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let draft = "Keep this draft when canceling Reset App."
        let text = app.textViews.firstMatch
        expectHittable(text)
        replaceText(draft, in: text, app: app)
        let settings = openSettings(app)
        selectTab("About", in: settings)
        settings.buttons["resetApp"].click()
        let confirmation = settings.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirmation.staticTexts["Reset PadPad?"].exists)
        confirmation.buttons["Cancel"].click()
        XCTAssertFalse(confirmation.exists)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        pressGlobalShortcutFromFinder()
        expectHittable(app.textViews.firstMatch)
        expectValue(draft, in: app.textViews.firstMatch)
        XCTAssertFalse(element("onboardingIntro", in: app).exists)
    }

    func testSettingsKeepTheSameFrameAndBottomControlsReachable() {
        let app = launchPad(completed: true, format: "txt", accent: "custom")
        defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        expectHittable(app.textViews.firstMatch)
        let settings = openSettings(app)
        attach(settings.screenshot(), name: "Settings on first opening before any tab selection")
        XCTAssertGreaterThanOrEqual(settings.frame.height, 520, "Settings should have room for its complete default layout")

        selectTab("General", in: settings)
        expectHittable(settings.popUpButtons["menuBarIcon"].firstMatch)
        let size = settings.frame.size
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertGreaterThanOrEqual(size.height, 520)
        attach(settings.screenshot(), name: "Compact General settings with the bottom icon control visible")

        selectTab("Editor", in: settings)
        expectHittable(element("quickPadSizeOptions", in: settings))
        expectHittable(element("fileWindowSizeOptions", in: settings))
        element("fileWindowSizeOptions", in: settings).click()
        XCTAssertFalse(app.menuItems["Use Current Size"].firstMatch.isEnabled,
                       "Use Current Size requires an open file window")
        XCTAssertTrue(app.menuItems["Restore Default"].firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        let readingWidth = element("limitTextWidth", in: settings)
        for _ in 0..<3 where !readingWidth.isHittable {
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        expectHittable(readingWidth)
        expectSize(size, of: settings)
        attach(settings.screenshot(), name: "Editor settings keep sizing and text width controls reachable")

        selectTab("Files", in: settings)
        let filename = element("File name", in: settings)
        expectHittable(filename)
        expectHittable(element("Insert filename variable", in: settings))
        expectSize(size, of: settings)
        attach(settings.screenshot(), name: "Compact Files settings with naming controls visible")

        selectTab("Shortcuts", in: settings)
        let saveAs = settings.searchFields["editingShortcut.saveAs"].firstMatch
        for _ in 0..<3 where !saveAs.isHittable {
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        expectHittable(saveAs)
        // Restore Defaults is intentionally disabled for a default fixture, but must be visible.
        let restore = settings.buttons["Restore Defaults"].firstMatch
        XCTAssertTrue(restore.exists, settings.debugDescription)
        for _ in 0..<3 where !settings.frame.contains(restore.frame) {
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -100)
        }
        XCTAssertTrue(settings.frame.contains(restore.frame), settings.debugDescription)
        expectSize(size, of: settings)
        attach(settings.screenshot(), name: "Compact Shortcuts settings with the last recorder visible")

        selectTab("About", in: settings)
        let reset = settings.buttons["resetApp"].firstMatch
        expectHittable(reset)
        let license = element("License", in: settings)
        XCTAssertTrue(license.exists, settings.debugDescription)
        XCTAssertGreaterThanOrEqual(reset.frame.minY, license.frame.maxY,
                                    "Reset App belongs below the About rows")
        expectSize(size, of: settings)
        attach(settings.screenshot(), name: "Compact About settings with Reset App reachable")

        selectTab("General", in: settings)
        expectHittable(settings.popUpButtons["menuBarIcon"].firstMatch)
        expectSize(size, of: settings)

        settings.buttons[XCUIIdentifierCloseWindow].click()
        expectSize(size, of: openSettings(app))

        // Check restoration before selecting a tab, which can itself trigger a resize.
        app.terminate()
        app.launch()
        app.typeKey("n", modifierFlags: .command)
        let restoredSettings = openSettings(app)
        expectSize(size, of: restoredSettings)
        attach(restoredSettings.screenshot(), name: "Settings retains its compact size after relaunch")
    }

    private func launchPad(completed: Bool = false, format: String = "md",
                           appearance: String = "light", accent: String = "standard",
                           globalShortcutEnabled: Bool = true, customAccent: String = "BEBAFC") -> XCUIApplication {
        continueAfterFailure = false
        // Run this suite with PAD_APP_IDENTIFIER=me.cyzr.pad.onboardingqa. The target
        // resolves through XCUIApplication(), retaining compatibility with isolated app names.
        // Argument-domain fixtures override values; onboarding writes stay in that QA container.
        let app = XCUIApplication()
        app.launchArguments = [
            "-pad.onboardingCompleted", completed ? "YES" : "NO",
            "-pad.format", format, "-pad.saveAutomatically", "NO", "-pad.floating", "NO",
            "-pad.reusePeriod", "60", "-showInDock", "YES", "-menuBarItem", "YES",
            "-appearance", appearance, "-accent", accent, "-customAccent", customAccent,
            "-pad.editingShortcuts", "invalid",
            "-KeyboardShortcuts_pad", globalShortcutEnabled ? #""{\"carbonKeyCode\":35,\"carbonModifiers\":6912}""# : "NO",
        ]
        app.launchArguments += sharedUITestLaunchArguments
        app.launch()
        XCTAssertFalse(element("onboardingIntro", in: app).exists, "Initial launch must remain hidden")
        XCTAssertFalse(app.buttons["documentFormat"].exists, "Initial launch must not open a draft")
        return app
    }

    private func summonIntroduction(_ app: XCUIApplication) {
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(element("onboardingIntro", in: app).waitForExistence(timeout: 5), app.debugDescription)
        expectHittable(app.buttons["onboardingStartPractice"].firstMatch)
        XCTAssertFalse(app.buttons["documentFormat"].exists, "The normal editor stays hidden during introduction")
    }

    private func pressGlobalShortcutFromFinder() {
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5), finder.debugDescription)
        let menuBar = finder.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 5), finder.debugDescription)
        XCTAssertGreaterThan(menuBar.frame.width, 0)
        menuBar.typeKey("p", modifierFlags: [.control, .option, .shift, .command])
        // Pad is a nonactivating panel. The caller waits for its practice counter,
        // rather than requiring the application to become the foreground app.
    }

    private func waitForMarkdownEditor(_ app: XCUIApplication) {
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        expectHittable(app.menuButtons["formattingMenu"].firstMatch, timeout: 15)
        expectValue("MD", in: app.buttons["documentFormat"].firstMatch)
        XCTAssertEqual(app.buttons["documentFormat"].firstMatch.label, "Markdown")
    }

    private func switchToText(_ app: XCUIApplication) {
        let format = app.buttons["documentFormat"].firstMatch
        expectHittable(format)
        expectValue("MD", in: format)
        format.click()
        expectValue("TXT", in: format)
        expectHittable(app.textViews.firstMatch)
    }

    private func replaceText(_ source: String, in text: XCUIElement, app: XCUIApplication) {
        text.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(source)
    }

    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        return settings
    }

    private func selectTab(_ title: String, in settings: XCUIElement) {
        let tab = settings.toolbars.buttons[title].firstMatch
        expectHittable(tab)
        tab.click()
    }

    private func element(_ identifier: String, in parent: XCUIElement) -> XCUIElement {
        parent.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func expectHittable(_ element: XCUIElement, timeout: TimeInterval = 5,
                                file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       element.debugDescription, file: file, line: line)
    }

    private func expectValue(_ expected: String, in element: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       "Expected \(String(reflecting: expected)); actual \(String(describing: element.value))",
                       file: file, line: line)
    }

    private func expectTextContaining(_ expected: String, in element: XCUIElement,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       element.debugDescription, file: file, line: line)
    }

    private func expectSize(_ size: CGSize, of window: XCUIElement,
                            file: StaticString = #filePath, line: UInt = #line) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(window.frame.width - size.width) < 1 && abs(window.frame.height - size.height) < 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                       "Settings frame changed from \(size) to \(window.frame.size)", file: file, line: line)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
