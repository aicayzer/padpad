import Foundation

/// Launch arguments every UI test shares.
///
/// macOS inline predictions show a panel that runs its own event loop and consumes
/// synthesized key events, so XCTest typing can insert the predicted character twice
/// ("after click" becomes "after clickr"). A plain WKWebView reproduces this without
/// PadPad or InkKit. Tests assert exact typed text, so the app under test starts
/// without inline predictions.
let sharedUITestLaunchArguments = ["-NSAutomaticInlinePredictionEnabled", "NO"]
