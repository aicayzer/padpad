import AppKit
import XCTest

/// The UI suite exercises global shortcuts, Dock state and saved preferences, so it must run
/// the Debug build, never an installed PadPad.
@MainActor
final class TestIdentityUITests: PadUITestCase {
    static let developmentIdentifier = "me.cyzr.pad.dev"

    func testAppUnderTestIsTheDevelopmentBuildFromTheBuildProducts() throws {
        continueAfterFailure = false
        let runnerIdentifier = try XCTUnwrap(Bundle(for: Self.self).bundleIdentifier)
        XCTAssertEqual(runnerIdentifier, Self.developmentIdentifier + ".uitests")

        let app = XCUIApplication()
        app.launchArguments = ["-pad.onboardingCompleted", "YES", "-pad.saveAutomatically", "NO"]
        app.launchArguments += sharedUITestLaunchArguments
        app.launch()
        defer { app.terminate() }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.developmentIdentifier)
        let process = try XCTUnwrap(running.first, "The application under test must use the \(Self.developmentIdentifier) identity")
        XCTAssertEqual(running.count, 1)
        let bundleURL = try XCTUnwrap(process.bundleURL)
        let path = bundleURL.path
        XCTAssertTrue(path.contains("/Build/Products/Debug/"), "The application must come from the Debug build products, not \(path)")
        XCTAssertFalse(path.hasPrefix("/Applications/"), path)
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, "PadPad Dev")
    }
}
