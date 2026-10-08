import SwiftUI

struct AppCommands: Commands {
    let workspace: PadWorkspace
    private var document: PadDocument { workspace.activeDocument }
    private var canEdit: Bool { document.isActive && !document.isBusy && !workspace.isTransitioning && !document.onboarding.isPresented }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Draft") { workspace.quickPad.commandNew() }
                .keyboardShortcut(document.editingShortcuts.shortcut(for: .newFile)?.toSwiftUI)
                .disabled(workspace.isTransitioning)
            Button("Open File…") { Task { await document.openPicker() } }
                .keyboardShortcut(document.editingShortcuts.shortcut(for: .open)?.toSwiftUI)
                .disabled(document.isBusy || workspace.isTransitioning)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { document.save() }
                .keyboardShortcut(document.editingShortcuts.shortcut(for: .save)?.toSwiftUI)
                .disabled(!canEdit || !document.isDirty)
            Button("Save As…") { Task { await document.saveAs() } }
                .keyboardShortcut(document.editingShortcuts.shortcut(for: .saveAs)?.toSwiftUI)
                .disabled(!canEdit)
            Button("Rename…") { document.requestRename() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canEdit)
            Button("Share…") { document.share() }.disabled(!canEdit)
            if document.url != nil {
                Button("Reveal in Finder") { document.revealInFinder() }.disabled(!canEdit)
            }
        }
        CommandGroup(after: .pasteboard) {
            Button("Paste as Plain Text") { document.pasteAsPlainText() }
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
                .disabled(!canEdit)
            Button("Copy All Contents") { Task { await document.copyAllContents() } }
                .keyboardShortcut(document.editingShortcuts.shortcut(for: .copyAllContents)?.toSwiftUI)
                .disabled(!canEdit)
            Button("Copy as Markdown") { Task { await document.copyAllContents(asMarkdown: true) } }
                .disabled(!canEdit || document.currentFormat != .md)
        }
        CommandMenu("Format") {
            if document.currentFormat == .md, let editor = document.markdownEditor {
                PadMarkdownToolbar(editor: editor).menuCommands
                    .disabled(!canEdit || !editor.isReady)
            }
        }
        CommandGroup(after: .windowSize) {
            Button("Restore Default Size") { document.restoreDefaultSize() }
                .keyboardShortcut(document.editingShortcuts.shortcut(for: .restoreDefaultSize)?.toSwiftUI)
                .disabled(!canEdit)
            Divider()
            Button("Quick Pad") { workspace.quickPad.showCurrent() }
        }
        CommandGroup(replacing: .help) {
            Button("Show PadPad Introduction") { Task { await workspace.quickPad.restartOnboarding() } }
                .disabled(workspace.isTransitioning)
        }
    }
}
