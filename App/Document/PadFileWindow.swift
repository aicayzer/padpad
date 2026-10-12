import AppKit
import KeyboardShortcuts
import SwiftUI

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

/// An independent file window using the same compact shell as the quick pad.
final class PadFileWindow: NSWindow, PadDocumentWindow {
    private let files: PadDocument
    private let quit: @MainActor () -> Void = { NSApp.terminate(nil) }
    private let pendingEditorInput = MarkdownInputBuffer()
    private var editorFocusScheduled = false
    private let pendingTitleInput = OverlayInputResponder()

    init(files: PadDocument) {
        self.files = files
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 860),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        contentView = NSHostingView(rootView: PadView(files: files, prepareTitleFocus: { [weak self] in
            guard let self else { return }
            pendingTitleInput.discardEvents()
            makeFirstResponder(pendingTitleInput)
        })
            .environment(files.appSettings ?? AppSettings())
            .frame(minWidth: 520, minHeight: 320))
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        isExcludedFromWindowsMenu = false
        pendingEditorInput.attach(to: self)
        if files.startsInReadingMode { makeFirstResponder(self) }
        restoreDefaultSize(animate: false)
        let offset = CGFloat(max(0, (files.workspace?.documents.count ?? 1) - 1) % 6) * 24
        setFrameTopLeftPoint(NSPoint(x: frame.minX + offset, y: frame.maxY - offset))
        constrainToAvailableScreen()
    }

    override func close() { files.close() }
    func finishClosing() { super.close() }
    func toggleExpanded() { zoom(nil) }
    func restoreDefaultSize(animate: Bool = true) {
        guard !styleMask.contains(.fullScreen), let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(files.appSettings?.fileWindowWidth ?? 800, visible.width),
                          height: min(files.appSettings?.fileWindowHeight ?? 860, visible.height))
        setFrame(NSRect(origin: frame.origin, size: size), display: true, animate: animate)
        center()
        constrainToAvailableScreen()
    }
    func constrainToAvailableScreen() {
        guard !styleMask.contains(.fullScreen), let screen = screen ?? NSScreen.main else { return }
        setFrame(constrainFrameRect(frame, to: screen), display: true)
    }
    func requestEditorFocus() {
        guard !files.onboarding.isPresented else { return }
        guard !editorFocusScheduled else { return }
        editorFocusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editorFocusScheduled = false
            guard !self.files.onboarding.isPresented else { return }
            guard self.isKeyWindow, self.isVisible, !self.files.settingsPresented else { return }
            guard !self.files.holdInitialReadingFocus() else { return }
            guard !self.pendingEditorInput.isComposing else { return }
            guard !self.files.startsInReadingMode || self.firstResponder !== self else { return }
            let awaitingEditor = self.firstResponder === self.pendingEditorInput || self.firstResponder === self
            if self.files.currentFormat == .md {
                guard let editor = self.files.markdownEditor else { return }
                // Replacing the document can temporarily buffer input while DOM focus catches up.
                guard awaitingEditor || editor.ownsFirstResponder else { return }
                editor.enqueueInputs(self.pendingEditorInput.takeInputs())
                return
            }
            guard awaitingEditor, let content = self.contentView,
                  let editor = self.editor(in: content), editor.isEditable else { return }
            self.makeFirstResponder(editor)
        }
    }

    func prepareMarkdownSnapshot() {
        guard files.currentFormat == .md, let editor = files.markdownEditor else { return }
        editor.hasExternalMarkedText = { [weak self] in self?.pendingEditorInput.isComposing == true }
        guard !pendingEditorInput.isComposing, pendingEditorInput.eventCount > 0 else { return }
        editor.enqueueInputs(pendingEditorInput.takeInputs())
    }

    func prepareReading() {
        pendingTitleInput.discardEvents()
        pendingEditorInput.discardEvents()
        makeFirstResponder(self)
    }

    func prepareOnboarding() {
        pendingTitleInput.discardEvents()
        pendingEditorInput.discardEvents()
        makeFirstResponder(nil)
    }

    func resumeEditor() {
        guard !files.onboarding.isPresented else { return }
        pendingEditorInput.attach(to: self)
        makeFirstResponder(pendingEditorInput)
        files.isActive = true
        requestEditorFocus()
    }

    private func editor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, !(editor is MarkdownInputBuffer), !editor.isFieldEditor { return editor }
        for child in view.subviews {
            if let editor = editor(in: child) { return editor }
        }
        return nil
    }

    override func sendEvent(_ event: NSEvent) {
        if !files.onboarding.isPresented, files.currentFormat == .md, firstResponder !== pendingEditorInput,
           files.markdownEditor?.capturePendingInput(event) == true { return }
        super.sendEvent(event)
        files.acceptMarkdownContentClick(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard files.workspace?.isTransitioning != true else { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let action = files.editingShortcuts.action(for: event) {
            guard !files.onboarding.isPresented else { return true }
            switch action {
            case .newFile: (files.workspace?.quickPad ?? files).commandNew()
            case .open: Task { await files.openPicker() }
            case .save: files.save()
            case .saveAs: Task { await files.saveAs() }
            case .restoreDefaultSize: restoreDefaultSize()
            case .copyAllContents: Task { await files.copyAllContents() }
            }
            return true
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "w": files.close()
            case "r": files.requestRename()
            case ",":
                files.settingsPresented = true
                files.showSettings()
            case "q": quit()
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeKey() {
        super.becomeKey()
        files.workspace?.didFocus(files)
        files.refreshIfNeeded()
        files.settingsPresented = false
        guard !files.onboarding.isPresented else {
            files.isActive = false
            return
        }
        if !files.startsInReadingMode, !(firstResponder is NSTextView), files.markdownEditor?.ownsFirstResponder != true {
            pendingEditorInput.attach(to: self)
            makeFirstResponder(pendingEditorInput)
        }
        files.isActive = true
        requestEditorFocus()
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result, let editor = responder as? NSTextView,
           !(editor is MarkdownInputBuffer), !editor.isFieldEditor {
            // SwiftUI must finish mounting the editor and its binding before replaying input.
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor, self.isKeyWindow, self.firstResponder === editor else { return }
                for input in self.pendingEditorInput.takeInputs() {
                    guard self.isKeyWindow, self.firstResponder === editor else { break }
                    switch input {
                    case .text(let text): editor.insertText(text, replacementRange: editor.selectedRange())
                    case .key(let event): self.sendEvent(event)
                    }
                }
            }
        }
        return result
    }

    override func resignKey() {
        super.resignKey()
        pendingTitleInput.discardEvents()
        files.isActive = false
        files.lostFocus()
    }

}
