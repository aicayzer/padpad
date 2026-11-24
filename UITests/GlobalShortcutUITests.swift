import AppKit
import XCTest

@MainActor
final class GlobalShortcutUITests: PadUITestCase {
    func testGlobalShortcutOpensAboveAnotherApplicationWithoutActivating() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appending(path: "pad-shortcut-cover-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let cover = finder.windows[directory.lastPathComponent]
        func visibleWindows() -> [[String: Any]] {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        }
        func bounds(of window: [String: Any]) -> CGRect? {
            guard let value = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: value as CFDictionary)
        }
        func sameFrame(_ left: CGRect, _ right: CGRect) -> Bool {
            abs(left.minX - right.minX) < 2 && abs(left.minY - right.minY) < 2 &&
                abs(left.width - right.width) < 2 && abs(left.height - right.height) < 2
        }
        var ownedWindowID: Int?
        defer {
            if let ownedWindowID,
               let info = visibleWindows().first(where: { $0[kCGWindowNumber as String] as? Int == ownedWindowID }),
               let frame = bounds(of: info),
               let window = finder.windows.allElementsBoundByIndex.first(where: { sameFrame($0.frame, frame) }) {
                window.buttons["_XCUI:CloseWindow"].click()
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let app = XCUIApplication()
        app.launchArguments = ["-pad.onboardingCompleted", "YES", "-pad.format", "txt",
                               "-pad.saveAutomatically", "NO", "-pad.floating", "YES",
                               "-showInDock", "NO", "-menuBarItem", "YES",
                               "-KeyboardShortcuts_pad", #""{\"carbonKeyCode\":11,\"carbonModifiers\":2560}""#]
        app.launchArguments += sharedUITestLaunchArguments
        app.launch()
        defer { app.terminate() }
        let bundle = try XCTUnwrap(Bundle(for: Self.self).bundleIdentifier)
        let target = String(bundle.dropLast(".uitests".count))
        let process = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: target).first)
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        let finderProcess = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let finderPID = finderProcess.processIdentifier
        let previousWindowIDs = Set(visibleWindows().compactMap { $0[kCGWindowNumber as String] as? Int })
        func newFinderWindow() -> [String: Any]? {
            visibleWindows().first { window in
                guard let id = window[kCGWindowNumber as String] as? Int,
                      window[kCGWindowOwnerPID as String] as? pid_t == finderPID,
                      window[kCGWindowLayer as String] as? Int == 0,
                      let frame = bounds(of: window), frame.width > 200, frame.height > 200 else { return false }
                return !previousWindowIDs.contains(id)
            }
        }
        finder.typeKey("n", modifierFlags: .command)
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in newFinderWindow() != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 5), .completed, "Finder must create a new fixture window")
        let newWindow = try XCTUnwrap(newFinderWindow())
        ownedWindowID = try XCTUnwrap(newWindow[kCGWindowNumber as String] as? Int)
        finder.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(finder.textFields.firstMatch.waitForExistence(timeout: 5))
        finder.typeKey("a", modifierFlags: .command)
        finder.typeText(directory.path)
        finder.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(cover.waitForExistence(timeout: 5), finder.debugDescription)

        // Center the disposable window so an empty desktop or remembered Finder placement cannot hide the regression.
        let primaryScreen = try XCTUnwrap(NSScreen.screens.first)
        let center = CGPoint(x: primaryScreen.visibleFrame.midX,
                             y: primaryScreen.frame.maxY - primaryScreen.visibleFrame.midY)
        let initialFrame = cover.frame
        let titleBar = cover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8))
        titleBar.press(forDuration: 0.1, thenDragTo: titleBar.withOffset(CGVector(dx: center.x - initialFrame.midX,
                                                                               dy: center.y - initialFrame.midY)))
        let coverFrame = cover.frame
        let coverInfo = try XCTUnwrap(visibleWindows().first { window in
            window[kCGWindowOwnerPID as String] as? pid_t == finderPID &&
                window[kCGWindowNumber as String] as? Int == ownedWindowID &&
                window[kCGWindowLayer as String] as? Int == 0 &&
                bounds(of: window).map { sameFrame($0, coverFrame) } == true
        }, "The disposable Finder window must match its new window ID and accessibility frame")
        let coverID = try XCTUnwrap(coverInfo[kCGWindowNumber as String] as? Int)
        XCTAssertEqual(process.activationPolicy, .accessory)

        let editor = app.textViews.firstMatch
        let close = app.buttons["Close PadPad"].firstMatch
        XCTAssertFalse(close.exists)
        for cycle in 1...3 {
            FinderKeyboard.press("b", [.option, .shift])
            XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(coverFrame.intersects(editor.frame), "The disposable Finder window must overlap the editor")
            let ordering = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                guard let padIndex = windows.firstIndex(where: {
                    $0[kCGWindowOwnerPID as String] as? pid_t == process.processIdentifier &&
                    $0[kCGWindowLayer as String] as? Int == Int(NSWindow.Level.floating.rawValue)
                }), let coverIndex = windows.firstIndex(where: {
                    $0[kCGWindowNumber as String] as? Int == coverID
                }) else { return false }
                return padIndex < coverIndex
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ordering], timeout: 5), .completed,
                           "The quick pad must be above the overlapping foreground window")
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, finderPID)
            // Synthesize through the foreground app without activating or clicking PadPad.
            FinderKeyboard.press("a")
            let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", String(repeating: "a", count: cycle)), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "Typing must reach the pad without a click")
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, finderPID)
            FinderKeyboard.press("b", [.option, .shift])
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        }
    }
}
