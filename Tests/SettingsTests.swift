import AppKit
import SwiftUI
import Testing
@testable import Pad

@MainActor
@Suite struct SettingsTests {
    @Test func errorColorUsesTheSpecifiedLightAndDarkValues() throws {
        let color = try #require(NSColor(named: "ErrorColor"))
        for (name, expected) in [(NSAppearance.Name.aqua, [255.0, 59.0, 48.0]),
                                 (NSAppearance.Name.darkAqua, [255.0, 69.0, 58.0])] {
            let appearance = try #require(NSAppearance(named: name))
            var components: [Double] = []
            appearance.performAsCurrentDrawingAppearance {
                if let resolved = color.usingColorSpace(.sRGB) {
                    components = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
                        .map { Double($0) * 255 }
                }
            }
            #expect(components.count == 3)
            for (actual, target) in zip(components, expected) { #expect(abs(actual - target) < 0.01) }
        }
    }

    @Test func freshSettingsUsePadDefaults() {
        let suite = "pad-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.showFormatToggle)
        #expect(settings.showInDock)
        #expect(settings.menuBarItem)
        #expect(settings.menuBarIcon == .mark)
        #expect(settings.accent == .standard)
        #expect(settings.customAccent == "BEBAFC")
    }

    @Test func formatSwitchVisibilityPersistsIndependently() {
        let suite = "pad-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("txt", forKey: "pad.format")
        let settings = AppSettings(defaults: defaults)
        settings.showFormatToggle = false
        #expect(!AppSettings(defaults: defaults).showFormatToggle)
        #expect(defaults.string(forKey: "pad.format") == "txt")
        settings.showFormatToggle = true
        #expect(AppSettings(defaults: defaults).showFormatToggle)
    }

    @Test func appearancePreferencesPersistIndependently() {
        let suite = "pad-settings-tests-\(UUID().uuidString)"
        let otherSuite = "pad-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let other = UserDefaults(suiteName: otherSuite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            other.removePersistentDomain(forName: otherSuite)
        }
        let settings = AppSettings(defaults: defaults)
        settings.menuBarItem = false
        settings.menuBarIcon = .compose
        settings.accent = .custom
        settings.setCustomAccent(Color(red: 0.2, green: 0.4, blue: 0.6))
        let restored = AppSettings(defaults: defaults)
        #expect(!restored.menuBarItem)
        #expect(restored.menuBarIcon == .compose)
        #expect(restored.accent == .custom)
        #expect(restored.customAccent == "336699")
        let isolated = AppSettings(defaults: other)
        #expect(isolated.menuBarItem)
        #expect(isolated.accent == .standard)
    }

    @Test(arguments: [AppAccess.dock, .menuBar, .both, .hidden])
    func accessPreservesExistingVisibilityPreferences(_ access: AppAccess) {
        let suite = "pad-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(access.showInDock, forKey: "showInDock")
        defaults.set(access.menuBarItem, forKey: "menuBarItem")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.access == access)
        #expect(defaults.bool(forKey: "showInDock") == access.showInDock)
        #expect(defaults.bool(forKey: "menuBarItem") == access.menuBarItem)
        #expect(AppAccess.visibleChoices.contains(.hidden))
    }

    @Test func hiddenAccessPersistsWithoutShortcut() {
        let suite = "pad-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.setAccess(.hidden)

        #expect(settings.access == .hidden)
        #expect(AppSettings(defaults: defaults).access == .hidden)
        #expect(!defaults.bool(forKey: "showInDock"))
        #expect(!defaults.bool(forKey: "menuBarItem"))
    }

    @Test func widthPresetsAndExplicitCustomChoicePersist() {
        let suite = "pad-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.textColumnWidthChoice == .standard)
        settings.textColumnWidthChoice = .wide
        #expect(settings.readingWidth == 920)
        #expect(AppSettings(defaults: defaults).textColumnWidthChoice == .wide)
        settings.textColumnWidthChoice = .custom
        settings.textColumnWidth = 740
        let restored = AppSettings(defaults: defaults)
        #expect(restored.textColumnWidthChoice == .custom)
        #expect(restored.readingWidth == 740)
        restored.limitTextWidth = false
        #expect(restored.readingWidth == nil)
        #expect(restored.textColumnWidthChoice == .custom)
    }

    @Test func existingCustomWidthIsPreservedAndSizeResetIsScoped() {
        let suite = "pad-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(680.0, forKey: "textColumnWidth")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.textColumnWidthChoice == .custom)
        #expect(settings.readingWidth == 680)
        settings.quickPadWidth = 900
        settings.fileWindowHeight = 1000
        settings.restoreQuickPadSize()
        #expect(settings.quickPadWidth == 740)
        #expect(settings.quickPadHeight == 480)
        #expect(settings.fileWindowHeight == 1000)
        #expect(settings.readingWidth == 680)
        settings.restoreFileWindowSize()
        #expect(settings.fileWindowHeight == 860)
        settings.restoreEditorDefaults()
        #expect(AppSettings(defaults: defaults).textColumnWidthChoice == .standard)
        #expect(settings.readingWidth == 740)
    }

    @Test func systemAccentUsesMacOSColor() {
        let suite = "pad-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.accent = .system
        #expect(settings.accentColor == Color(nsColor: .controlAccentColor))
    }
}
