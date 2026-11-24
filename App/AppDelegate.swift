import AppIntents
import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let isTestHost = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    let settings: AppSettings
    let workspace: PadWorkspace
    var document: PadDocument { workspace.quickPad }

    override init() {
        let defaults = Self.isTestHost ? UserDefaults(suiteName: "tests-\(UUID().uuidString)")! : .standard
        settings = AppSettings(defaults: defaults)
        workspace = PadWorkspace(settings: settings, defaults: defaults, presentsWindows: !Self.isTestHost)
        super.init()
        // Shortcuts can launch PadPad just to run an action, so the workspace must be available from the start.
        let workspace = workspace
        AppDependencyManager.shared.add(dependency: workspace)
        if Self.isTestHost { KeyboardShortcuts.isEnabled = false }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        settings.applyAppearance()
        settings.applyActivationPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        document.installShortcut()
        // SwiftUI finishes creating its scenes after the delegate's early launch callback.
        // Reapply the saved access policy once scene setup has settled, without opening a draft.
        DispatchQueue.main.async { [weak self] in self?.settings.applyActivationPolicy() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        settings.applyActivationPolicy()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !Self.isTestHost else { return }
        for url in urls where url.isFileURL { workspace.open(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isTestHost else { return false }
        workspace.reopen()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { sender.reply(toApplicationShouldTerminate: await workspace.prepareToTerminate()) }
        return .terminateLater
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        workspace.screenConfigurationChanged()
    }
}
