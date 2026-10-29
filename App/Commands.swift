import AppKit
import SwiftUI

struct AppCommands: Commands {
    let workspace: PadWorkspace
    private var document: PadDocument { workspace.activeDocument }
    private var canEdit: Bool { document.isActive && !document.isBusy && !workspace.isTransitioning && !document.onboarding.isPresented }

    private var markdownOwnsUndo: Bool {
        document.markdownOwnsFirstResponder
    }
    private var canUndo: Bool {
        markdownOwnsUndo ? document.markdownEditor?.canUndo == true : NSApp.keyWindow?.firstResponder?.undoManager?.canUndo == true
    }
    private var canRedo: Bool {
        markdownOwnsUndo ? document.markdownEditor?.canRedo == true : NSApp.keyWindow?.firstResponder?.undoManager?.canRedo == true
    }

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
            Button("Share…") { document.share() }.disabled(!canEdit || !document.canShare)
            if document.url != nil {
                Button("Reveal in Finder") { document.revealInFinder() }.disabled(!canEdit)
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if markdownOwnsUndo { document.markdownEditor?.undo() }
                else { NSApp.keyWindow?.firstResponder?.undoManager?.undo() }
            }.keyboardShortcut("z").disabled(!canUndo || (markdownOwnsUndo && !canEdit))
            Button("Redo") {
                if markdownOwnsUndo { document.markdownEditor?.redo() }
                else { NSApp.keyWindow?.firstResponder?.undoManager?.redo() }
            }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!canRedo || (markdownOwnsUndo && !canEdit))
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { Task { await document.printDocument() } }
                .keyboardShortcut("p").disabled(!canEdit)
        }
        CommandGroup(after: .pasteboard) {
            Button("Find and Replace…") {
                if document.currentFormat.usesEditor { document.markdownEditor?.showingFind = true }
                else {
                    let item = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
                }
            }.keyboardShortcut("f").disabled(!canEdit)
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
            if document.currentFormat.usesEditor, let editor = document.markdownEditor {
                // RTF has no source mode.
                if editor.documentFormat == .md {
                    Toggle("Markdown Source", isOn: Binding(get: { editor.editingMode == "source" },
                        set: { editor.setEditingMode($0 ? "source" : "formatted") }))
                        .disabled(!canEdit || !editor.canPerformMenuCommands)
                    Divider()
                }
                PadMarkdownToolbar(editor: editor).menuCommands
                    .disabled(!canEdit || !editor.canPerformMenuCommands)
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
