import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PadDocument.self) private var document
    @Environment(PadWorkspace.self) private var workspace
    @State private var login = LoginItemSettings()
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .pad)
    @State private var settingsWindow: NSWindow?
    @State private var showingResetConfirmation = false
    @State private var resetting = false
    @FocusState private var editingDimension: String?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Editor", systemImage: "text.alignleft") { editor }
            Tab("Files", systemImage: "doc") { files }
            Tab("Shortcuts", systemImage: "keyboard") { shortcuts }
            Tab("About", systemImage: "info.circle") { about }
        }
        // A shared initial size keeps tab changes still; the forms remain scrollable.
        .frame(minWidth: 460, idealWidth: 480, minHeight: 440, idealHeight: 520)
        .tint(settings.accentColor)
        .disabled(workspace.isTransitioning)
        .background(WindowReader { window in
            settingsWindow = window
            window.level = document.floating ? .floating : .normal
            document.settingsPresented = true
        })
        .background(SettingsEditingDismissal(isEditing: editingDimension != nil) {
            editingDimension = nil
        })
        .onChange(of: document.floating) { _, floating in
            settingsWindow?.level = floating ? .floating : .normal
        }
        .onAppear {
            document.settingsPresented = true
            document.isActive = false
            NSApp.activate()
            login.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if notification.object as? NSWindow === settingsWindow { releaseSettingsFocus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if notification.object as? NSWindow === settingsWindow {
                document.settingsPresented = true
                document.isActive = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard notification.object as? NSWindow === settingsWindow,
                  !settings.isChangingActivationPolicy else { return }
            DispatchQueue.main.async {
                guard !settings.isChangingActivationPolicy else { return }
                // A color or file panel is still part of Settings, not dismissal to another app.
                if !NSApp.isActive || document.isActive { releaseSettingsFocus() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if document.settingsPresented, !settings.isChangingActivationPolicy { releaseSettingsFocus() }
        }
        .onChange(of: settings.isChangingActivationPolicy) { _, changing in
            guard !changing else { return }
            if settingsWindow?.isKeyWindow == true {
                document.settingsPresented = true
                document.isActive = false
            } else if !NSApp.isActive, document.settingsPresented {
                releaseSettingsFocus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }

    private func releaseSettingsFocus() {
        document.settingsPresented = false
        if !document.isActive { document.lostFocus() }
    }

    private var general: some View {
        @Bindable var settings = settings
        @Bindable var document = document
        return Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                }
                .tint(.primary)
                .accessibilityIdentifier("appearance")
                Picker("Accent", selection: $settings.accent) {
                    ForEach(AccentChoice.allCases) { Text($0.title).tag($0) }
                }
                .tint(.primary)
                if settings.accent == .custom {
                    ColorPicker("Accent color", selection: Binding(get: { settings.accentColor }, set: { settings.setCustomAccent($0) }), supportsOpacity: false)
                }
                MenuBarIconPicker(selection: $settings.menuBarIcon)
                    .disabled(!settings.menuBarItem)
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { login.enabled }, set: { enabled in Task { await login.setEnabled(enabled) } }))
                    .disabled(login.updating)
                if login.status == .requiresApproval { Button("Allow in Login Items…") { login.openSystemSettings() } }
                if let error = login.error { Text(error).foregroundStyle(Color("ErrorColor")) }
                Toggle("Keep quick pad on top", isOn: $document.floating)
                Picker("Open PadPad from", selection: Binding(
                    get: { settings.access },
                    set: { settings.setAccess($0, hasGlobalShortcut: shortcut != nil, from: settingsWindow) }
                )) {
                    ForEach(AppAccess.visibleChoices) { Text($0.title).tag($0) }
                    if settings.access == .shortcutOnly {
                        Text(AppAccess.shortcutOnly.title).tag(AppAccess.shortcutOnly)
                    }
                }
                .tint(.primary)
                .accessibilityIdentifier("appAccess")
            } header: { Text("PadPad") } footer: {
                Text("File windows appear in the Dock while they are open.")
                if let error = settings.activationPolicyError { Text(error).foregroundStyle(Color("ErrorColor")) }
                if !settings.showInDock && !settings.menuBarItem, let shortcut {
                    Text("Open \(Bundle.main.displayName) with \(shortcut.description).")
                }
            }
        }.formStyle(.grouped)
    }

    private var editor: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                windowSize("Quick pad", width: $settings.quickPadWidth, height: $settings.quickPadHeight,
                           identifier: "quickPadDefault", optionsIdentifier: "quickPadSizeOptions",
                           useCurrent: { workspace.useCurrentQuickPadSize() },
                           restore: { settings.restoreQuickPadSize() })
                windowSize("File windows", width: $settings.fileWindowWidth, height: $settings.fileWindowHeight,
                           identifier: "fileWindowDefault", optionsIdentifier: "fileWindowSizeOptions",
                           canUseCurrent: workspace.canUseFileSize,
                           useCurrent: { workspace.useCurrentFileSize() },
                           restore: { settings.restoreFileWindowSize() })
                Toggle("Snap quick pad to default position", isOn: $settings.snapQuickPadToCenter)
            } header: { Text("Window size") } footer: {
                Text("Width × height, in points.")
            }
            Section {
                Toggle("Limit text width", isOn: $settings.limitTextWidth)
                    .accessibilityIdentifier("limitTextWidth")
                Picker("Column width", selection: $settings.textColumnWidthChoice) {
                    ForEach(TextColumnWidthChoice.allCases) { Text($0.title).tag($0) }
                }
                .tint(.primary)
                .disabled(!settings.limitTextWidth)
                .accessibilityIdentifier("textColumnWidthChoice")
                if settings.textColumnWidthChoice == .custom {
                    LabeledContent("Custom width") {
                        dimensionField(value: $settings.textColumnWidth, label: "Text column width",
                                       identifier: "textColumnWidth")
                        Text("pt").foregroundStyle(.secondary)
                    }
                    .disabled(!settings.limitTextWidth)
                }
            } header: { Text("Text") } footer: {
                Text("Keeps text centered in wider windows.")
            }
        }.formStyle(.grouped)
    }

    private func windowSize(_ label: String, width: Binding<Double>, height: Binding<Double>,
                            identifier: String, optionsIdentifier: String, canUseCurrent: Bool = true,
                            useCurrent: @escaping () -> Void, restore: @escaping () -> Void) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                dimensionField(value: width, label: "\(label) width", identifier: identifier + "Width")
                Text("×").foregroundStyle(.secondary)
                dimensionField(value: height, label: "\(label) height", identifier: identifier + "Height")
                SettingsOptionsMenu(label: "\(label) size options", identifier: optionsIdentifier,
                                    primaryTitle: "Use Current Size", primaryEnabled: canUseCurrent,
                                    primary: useCurrent, secondaryTitle: "Restore Default", secondary: restore)
                    .frame(width: 18, height: 22)
                    .padding(.leading, 2)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func dimensionField(value: Binding<Double>, label: String, identifier: String) -> some View {
        TextField(label, value: value, format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
            .focused($editingDimension, equals: identifier)
            .onExitCommand { editingDimension = nil }
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private var files: some View {
        @Bindable var settings = settings
        @Bindable var document = document
        return Form {
            Section {
                Picker("Format", selection: $document.format) {
                    Text("Markdown (.md)").tag(PadFormat.md)
                    Text("Plain text (.txt)").tag(PadFormat.txt)
                }
                .tint(.primary)
                Toggle("Save automatically", isOn: $document.saveAutomatically)
                Picker("Clear draft", selection: $document.reusePeriod) {
                    ForEach(PadReuse.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .tint(.primary)
                .accessibilityIdentifier("draftLifetime")
                Toggle("Show format switch", isOn: $settings.showFormatToggle)
                    .accessibilityIdentifier("showFormatToggle")
            } header: { Text("Quick pad") } footer: {
                Text(draftExplanation)
            }
            Section {
                LabeledContent("Folder") {
                    Text(document.folder.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).help(document.folder.path)
                    SettingsOptionsMenu(label: "Save folder options", identifier: "saveFolderOptions",
                                        primaryTitle: "Choose Folder…",
                                        primary: { Task { await document.chooseFolder(parent: settingsWindow) } },
                                        secondaryTitle: "Use Downloads…",
                                        secondaryEnabled: !document.isDefaultFolder || document.needsFolderSelection,
                                        secondary: { Task { await document.chooseFolder(parent: settingsWindow, useDownloads: true) } })
                        .frame(width: 18, height: 22)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Filename").fixedSize()
                        Spacer(minLength: 0)
                        Text(document.namePreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(document.namePreview)
                            .accessibilityLabel("Filename example: \(document.namePreview)")
                    }
                    PadNameField(parts: $document.nameParts).frame(height: 26)
                }
            } header: { Text("Saving") } footer: {
                Text(document.needsFolderSelection
                     ? "Choose a folder on your first save, or choose one here. Opened files stay in their own folder."
                     : "New quick-pad files save here. Opened files stay in their own folder.")
                if let error = document.error { Text(error).foregroundStyle(Color("ErrorColor")) }
            }
        }.formStyle(.grouped)
    }

    private var draftExplanation: String {
        if document.saveAutomatically {
            return "Quick pad saves on close or when switching apps. Save opened files manually."
        }
        if document.reusePeriod == .alwaysNew {
            return "Clears temporary drafts on reopening. Saved files are kept."
        }
        return "Clears temporary drafts after \(document.reusePeriod.title) away. Saved files are kept."
    }

    private var about: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    LabeledContent(Bundle.main.displayName, value: "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                }
                Text("A place for text and Markdown.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Link("Website", destination: URL(string: "https://padpad.cyzr.me")!)
                Link("Source Code", destination: URL(string: "https://github.com/aicayzer/padpad")!)
                Link("Privacy Policy", destination: URL(string: "https://padpad.cyzr.me/privacy")!)
                Link("License", destination: URL(string: "https://github.com/aicayzer/padpad/blob/main/LICENSE")!)
            } footer: {
                if let error = workspace.resetError {
                    Text(error).foregroundStyle(Color("ErrorColor"))
                }
                HStack {
                    Spacer()
                    Button("Reset App…") { showingResetConfirmation = true }
                        .disabled(resetting)
                        .accessibilityIdentifier("resetApp")
                        .help("Restore default settings while keeping your writing and saved files")
                }
                .padding(.top, 8)
            }
            .tint(.primary)
        }.formStyle(.grouped)
        .alert("Reset PadPad?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset App", role: .destructive) {
                resetting = true
                Task {
                    await workspace.resetApp()
                    shortcut = KeyboardShortcuts.getShortcut(for: .pad)
                    login.refresh()
                    resetting = false
                }
            }
        } message: {
            Text("Your settings will return to their defaults. Your writing and saved files will be kept.")
        }
    }

    private var shortcuts: some View {
        Form {
            Section("Global shortcut") {
                KeyboardShortcuts.Recorder("Show or hide \(Bundle.main.displayName)", name: .pad) { value in
                    shortcut = value
                    // Keep an entry point when the final global shortcut is removed.
                    if value == nil && !settings.showInDock && !settings.menuBarItem { settings.menuBarItem = true }
                }
                .shortcutValidation { document.editingShortcuts.validateGlobal($0) }
            }
            Section {
                EditingShortcutSettings(shortcuts: document.editingShortcuts,
                                        actions: [.newFile, .open, .save, .saveAs, .copyAllContents,
                                                  .restoreDefaultSize])
            } header: {
                Text("In PadPad")
            } footer: {
                VStack(alignment: .trailing, spacing: 8) {
                    if let error = document.editingShortcuts.error {
                        Text(error).foregroundStyle(Color("ErrorColor")).font(.caption)
                    }
                    HStack {
                        Spacer()
                        Button("Restore Defaults") { document.editingShortcuts.restoreDefaults() }
                            .tint(.primary)
                            .disabled(document.editingShortcuts.isDefault)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.formStyle(.grouped)
    }
}
