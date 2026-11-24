import AppKit

@MainActor
protocol PadDocumentWindow where Self: NSWindow {
    func requestEditorFocus()
    func prepareMarkdownSnapshot()
    func prepareOnboarding()
    func prepareReading()
    func resumeEditor()
    func finishClosing()
    func restoreDefaultSize(animate: Bool)
    func constrainToAvailableScreen()
    func toggleExpanded()
}

extension PadDocumentWindow {
    func restoreDefaultSize() { restoreDefaultSize(animate: true) }
}

/// Keyboard input and editor focus shared by the quick pad and file windows. Each window forwards its
/// responder events here, so typing before the editor is ready reaches the editor in both.
@MainActor
final class PadWindowInput {
    private unowned let window: NSWindow
    private let files: PadDocument
    private let pendingTitleInput = OverlayInputResponder()
    private let pendingEditorInput = MarkdownInputBuffer()
    private var editorFocusScheduled = false
    /// Tests replace this to observe Quit without ending the test host.
    var quit: @MainActor () -> Void = { NSApp.terminate(nil) }

    var pendingEditorEventCount: Int { pendingEditorInput.eventCount }

    init(window: NSWindow, files: PadDocument) {
        self.window = window
        self.files = files
        pendingEditorInput.onInput = { [weak self] in self?.requestEditorFocus() }
    }

    /// Starts buffering typing that arrives before the editor can take focus. The window calls this once it
    /// is initialized.
    func attach() {
        pendingEditorInput.attach(to: window)
    }

    func prepareTitleFocus() {
        pendingTitleInput.discardEvents()
        window.makeFirstResponder(pendingTitleInput)
    }

    func requestEditorFocus() {
        guard !files.onboarding.isPresented, !editorFocusScheduled else { return }
        editorFocusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            editorFocusScheduled = false
            guard !files.onboarding.isPresented, window.isKeyWindow, window.isVisible, !files.settingsPresented,
                  !files.holdInitialReadingFocus(), !pendingEditorInput.isComposing,
                  !files.startsInReadingMode || window.firstResponder !== window else { return }
            let awaitingEditor = window.firstResponder === pendingEditorInput || window.firstResponder === window
            if files.currentFormat.usesEditor {
                guard let editor = files.markdownEditor else { return }
                // Replacing the document can temporarily buffer input while DOM focus catches up.
                guard awaitingEditor || editor.ownsFirstResponder else { return }
                editor.enqueueInputs(pendingEditorInput.takeInputs())
                return
            }
            guard awaitingEditor, let content = window.contentView,
                  let editor = Self.textEditor(in: content), editor.isEditable else { return }
            window.makeFirstResponder(editor)
        }
    }

    func prepareMarkdownSnapshot() {
        guard files.currentFormat.usesEditor, let editor = files.markdownEditor else { return }
        editor.hasExternalMarkedText = { [weak self] in self?.pendingEditorInput.isComposing == true }
        guard !pendingEditorInput.isComposing, pendingEditorInput.eventCount > 0 else { return }
        editor.enqueueInputs(pendingEditorInput.takeInputs())
    }

    func prepareReading() {
        pendingTitleInput.discardEvents()
        pendingEditorInput.discardEvents()
        window.makeFirstResponder(window)
    }

    func prepareOnboarding() {
        pendingTitleInput.discardEvents()
        pendingEditorInput.discardEvents()
        window.makeFirstResponder(nil)
    }

    func resumeEditor() {
        guard !files.onboarding.isPresented else { return }
        pendingEditorInput.attach(to: window)
        window.makeFirstResponder(pendingEditorInput)
        files.isActive = true
        requestEditorFocus()
    }

    /// Returns true when the web editor took the event as input that arrived before it could focus.
    func capturesPendingInput(_ event: NSEvent) -> Bool {
        !files.onboarding.isPresented && files.currentFormat.usesEditor && window.firstResponder !== pendingEditorInput
            && files.markdownEditor?.capturePendingInput(event) == true
    }

    /// Handles the window's editing and command shortcuts. Returns nil for keys the window passes to AppKit.
    func performKeyEquivalent(with event: NSEvent, restoreDefaultSize: () -> Void) -> Bool? {
        guard files.workspace?.isTransitioning != true else { return true }
        if let action = files.editingShortcuts.action(for: event) {
            guard !files.onboarding.isPresented else { return true }
            switch action {
            case .newFile: (files.workspace?.quickPad ?? files).commandNew()
            case .open: Task { await files.openPicker() }
            case .save: files.save()
            case .saveAs: Task { await files.saveAs() }
            case .restoreDefaultSize: restoreDefaultSize()
            case .copyAllContents: Task { await files.copyAllContents() }
            case .copyPath: files.copyFilePath()
            }
            return true
        }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return nil }
        switch event.charactersIgnoringModifiers {
        case "w": files.close()
        case "r": files.requestRename()
        case ",":
            files.settingsPresented = true
            files.showSettings()
        case "q": quit()
        default: return nil
        }
        return true
    }

    func didBecomeKey() {
        files.markdownEditor?.keyboardFocusDidChange()
        files.workspace?.didFocus(files)
        files.refreshIfNeeded()
        files.settingsPresented = false
        guard !files.onboarding.isPresented else {
            files.isActive = false
            return
        }
        if !files.startsInReadingMode, !(window.firstResponder is NSTextView), files.markdownEditor?.ownsFirstResponder != true {
            pendingEditorInput.attach(to: window)
            window.makeFirstResponder(pendingEditorInput)
        }
        files.isActive = true
        requestEditorFocus()
    }

    func didMakeFirstResponder(_ responder: NSResponder?) {
        files.markdownEditor?.keyboardFocusDidChange()
        guard let editor = responder as? NSTextView, !(editor is MarkdownInputBuffer), !editor.isFieldEditor else { return }
        // SwiftUI must finish mounting the editor and its binding before replaying input.
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, window.isKeyWindow, window.firstResponder === editor else { return }
            for input in pendingEditorInput.takeInputs() {
                guard window.isKeyWindow, window.firstResponder === editor else { break }
                switch input {
                case .text(let text): editor.insertText(text, replacementRange: editor.selectedRange())
                case .key(let event): window.sendEvent(event)
                }
            }
        }
    }

    func didResignKey() {
        files.markdownEditor?.keyboardFocusDidChange()
        pendingTitleInput.discardEvents()
        files.isActive = false
        files.lostFocus()
    }

    private static func textEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, !(editor is MarkdownInputBuffer), !editor.isFieldEditor { return editor }
        for child in view.subviews {
            if let editor = textEditor(in: child) { return editor }
        }
        return nil
    }
}
