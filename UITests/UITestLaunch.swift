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
