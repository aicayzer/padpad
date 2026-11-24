import AppIntents

/// Shows the quick pad, following the same rules as the global shortcut.
struct ShowPadPadIntent: AppIntent {
    static let title: LocalizedStringResource = "Show PadPad"
    static let description = IntentDescription("Shows the quick pad.")
    static var supportedModes: IntentModes { .foreground }

    @Dependency private var workspace: PadWorkspace

    @MainActor
    func perform() async throws -> some IntentResult {
        workspace.quickPad.showCurrent()
        return .result()
    }
}

/// Adds text to the end of the quick pad's draft and shows it.
struct AddToPadPadIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to PadPad"
    static let description = IntentDescription("Adds text to the end of the quick pad’s draft and shows it.")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to PadPad")
    }

    @Dependency private var workspace: PadWorkspace

    @MainActor
    func perform() async throws -> some IntentResult {
        try await workspace.quickPad.add(text)
        return .result()
    }
}

struct PadPadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowPadPadIntent(),
                    phrases: ["Show \(.applicationName)", "Open \(.applicationName)"],
                    shortTitle: "Show PadPad", systemImageName: "note.text")
        AppShortcut(intent: AddToPadPadIntent(),
                    phrases: ["Add to \(.applicationName)"],
                    shortTitle: "Add to PadPad", systemImageName: "text.append")
    }
}
