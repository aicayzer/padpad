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
    /// Chooses a format from the quick pad's footer menu, such as "Plain Text".
    @MainActor func chooseFormat(_ name: String) {
        let control = menuButtons["documentFormat"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), debugDescription)
        control.click()
        let item = menuItems[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), debugDescription)
        item.click()
    }
}
