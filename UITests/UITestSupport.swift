import AppKit
import Foundation
import XCTest

/// Launch arguments every UI test shares.
///
/// macOS inline predictions show a panel that runs its own event loop and consumes
/// synthesized key events, so XCTest typing can insert the predicted character twice
/// ("after click" becomes "after clickr"). A plain WKWebView reproduces this without
/// PadPad or InkKit. Tests assert exact typed text, so the app under test starts
/// without inline predictions.
let sharedUITestLaunchArguments = ["-NSAutomaticInlinePredictionEnabled", "NO"]

/// Base class for every UI test.
///
/// UI tests take over the keyboard, mouse and windows of the session they run in, so
/// they fail immediately, with the reason, unless the run declares that its session is
/// disposable: pass `TEST_RUNNER_PAD_UI_TESTS=1` to `xcodebuild`, as CI and the isolated
/// test machine do. See DEVELOPMENT.md.
@MainActor
class PadUITestCase: XCTestCase {
    static let isolatedSessionVariable = "PAD_UI_TESTS"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let value = ProcessInfo.processInfo.environment[Self.isolatedSessionVariable]
        guard value == "1" else {
            XCTFail("""
                UI tests control the keyboard, mouse and windows of the session they run in. \
                Run them only in an isolated GUI session, with TEST_RUNNER_\(Self.isolatedSessionVariable)=1 \
                set in the xcodebuild environment. See DEVELOPMENT.md.
                """)
            throw SessionNotIsolated()
        }
    }

    private struct SessionNotIsolated: Error {}
}

/// Presses keys through Finder, the application a global shortcut is usually pressed over.
///
/// Every key XCTest synthesizes for an application it did not launch waits about ten seconds for that
/// application to become idle, and Finder never does. Posting a `CGEvent` instead avoids the wait, but it
/// needs Accessibility access that the UI test runner does not have on a disposable test machine. The
/// helper therefore keeps the wait to one call per key press, and resolves no Finder element beforehand.
@MainActor
enum FinderKeyboard {
    private static let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")

    /// Makes Finder the frontmost application, so the key press is not delivered to the application under test.
    static func activate(file: StaticString = #filePath, line: UInt = #line) {
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5), "Finder did not become frontmost", file: file, line: line)
    }

    /// Activates Finder, then presses `key` with `modifiers`.
    static func pressAfterActivating(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = [],
                                                file: StaticString = #filePath, line: UInt = #line) {
        activate(file: file, line: line)
        press(key, modifiers)
    }

    /// Presses `key` with `modifiers` while Finder is frontmost.
    static func press(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        finder.typeKey(key, modifierFlags: modifiers)
    }
}

extension XCUIApplication {
    /// Cycles the quick pad through its enabled formats.
    @MainActor func chooseFormat(_ name: String) {
        let control = buttons["documentFormat"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), debugDescription)
        for _ in 0..<3 {
            if control.label == name { return }
            let previous = control.value as? String
            control.click()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (control.value as? String) != previous
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        }
        XCTAssertEqual(control.label, name)
    }
}

extension XCTestCase {
    /// Adds a screenshot that is kept only when the test fails.
    @MainActor func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
