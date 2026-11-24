import AppKit

// The bridge between a document and its InkKit editor: mounting, snapshots, clipboard and printing.
extension PadDocument {
    func printDocument() async {
        let id = documentID
        guard !isBusy else { return }
        operation = .transition
        defer { operation = nil }
        guard await captureLatestEditor(), documentID == id else { return }
        do {
            if currentFormat.usesEditor {
                guard let editor = markdownEditor else { throw PadMarkdownEditorError.notReady }
                try await editor.printDocument()
            } else {
                let view = PadPlainTextPrintView.make(text)
                let operation = NSPrintOperation(view: view)
                operation.showsPrintPanel = true
                operation.run()
            }
        } catch { report(error, during: .print) }
    }
    func mountMarkdownEditor() {
        guard !onboarding.isPresented, currentFormat.usesEditor, markdownEditor == nil else { return }
        let editor = PadMarkdownEditorController()
        editor.diagnosticScope = diagnosticScope
        editor.diagnostics = appSettings?.diagnostics
        appSettings?.diagnostics.register(editor)
        editor.onChanged = { [weak self] content, id in
            guard let self, self.documentID == id, self.currentFormat.usesEditor, !self.onboarding.isPresented else { return }
            self.text = content
            if self.editorFeedback?.source == .edit { self.editorFeedback = nil }
        }
        editor.onFeedback = { [weak self] feedback, id in
            guard let self, self.documentID == id, self.currentFormat.usesEditor, !self.onboarding.isPresented else { return }
            self.editorFeedback = feedback
        }
        editor.onError = { [weak self] error in
            guard let self, self.currentFormat.usesEditor, !self.onboarding.isPresented else { return }
            self.report(error, during: .editor)
        }
        editor.onRestarted = { [weak self, weak editor] in
            guard let self, let editor, self.markdownEditor === editor, self.currentFormat.usesEditor else { return }
            self.reloadEditor()
        }
        editor.onReady = { [weak self] in
            guard let self, !self.onboarding.isPresented, self.currentFormat.usesEditor else { return }
            guard !self.holdInitialReadingFocus() else { return }
            self.panel?.requestEditorFocus()
        }
        markdownEditor = editor
        editorSnapshot = { [weak editor] in
            guard let editor else { throw CocoaError(.coderReadCorrupt) }
            return try await editor.snapshot()
        }
        editorClipboard = { [weak editor] in
            guard let editor else { throw PadMarkdownEditorError.unavailable }
            return try await editor.clipboardSnapshot()
        }
        editorConversion = { [weak editor] format in
            guard let editor else { throw PadMarkdownEditorError.unavailable }
            return try await editor.convert(to: format)
        }
        editorLoadedSource = text
        editorLoadedDocumentID = documentID
        editor.load(text, format: currentFormat, documentID: documentID)
    }
    func acceptMarkdownContentClick(_ event: NSEvent) {
        guard event.type == .leftMouseDown, !onboarding.isPresented, currentFormat.usesEditor,
              let editor = markdownEditor, let window = editor.webView.window,
              event.windowNumber == window.windowNumber, let content = window.contentView,
              let parent = content.superview,
              let target = content.hitTest(parent.convert(event.locationInWindow, from: nil)),
              target === editor.webView || target.isDescendant(of: editor.webView) else { return }
        pendingReadingDocumentID = nil
        editor.contentWasClicked()
    }
    func holdInitialReadingFocus() -> Bool {
        guard pendingReadingDocumentID == documentID else { return false }
        guard let editor = markdownEditor, editor.isReady, let panel,
              panel.isKeyWindow, editor.webView.window === panel else { return true }
        pendingReadingDocumentID = nil
        // Native WebKit ownership during mounting does not establish editing intent.
        if editor.ownsFirstResponder { panel.prepareReading() }
        return true
    }
    /// Plain text can't keep an image, so a paste or drop of only an image changes nothing and says so.
    func refuseImage() {
        editorFeedback = PadMarkdownEditorFeedback(code: "image-unsupported", source: .edit)
    }
    func reloadEditor() {
        editorFeedback = nil
        editorLoadedSource = text
        if editorLoadedDocumentID == documentID {
            markdownEditor?.reload(text, format: currentFormat, documentID: documentID)
        } else {
            editorLoadedDocumentID = documentID
            markdownEditor?.load(text, format: currentFormat, documentID: documentID)
        }
    }
    func captureLatestEditor() async -> Bool {
        guard !onboarding.isPresented, currentFormat.usesEditor, let editorSnapshot else { return true }
        recordDiagnostic(.snapshot)
        let id = documentID
        panel?.prepareMarkdownSnapshot()
        do {
            let latest = try await editorSnapshot()
            guard id == documentID else { return false }
            text = latest ?? editorLoadedSource
            recordDiagnostic(.snapshotSucceeded)
            return true
        } catch PadMarkdownEditorError.unavailable where markdownEditor?.hasEnded == true && id == documentID {
            // The editor's process is gone for good. `text` holds the last content it reported, so saving and
            // closing go ahead with that copy; closing still asks about unsaved changes.
            return true
        } catch {
            report(error, during: .snapshot)
            onboarding.dismiss()
            show()
            if !isActive, !onboarding.isPresented { panel?.resumeEditor() }
            return false
        }
    }
    // Web edits are asynchronous; hold document transitions until the final keystroke is read.
    func synchronizeEditorThen(_ action: @escaping @MainActor () -> Void) -> Bool {
        guard !snapshotApplied, currentFormat.usesEditor, editorSnapshot != nil else { return false }
        guard !isBusy else { return true }
        operation = .transition
        Task {
            let captured = await captureLatestEditor()
            operation = nil
            guard captured else { return }
            snapshotApplied = true
            defer { snapshotApplied = false }
            action()
        }
        return true
    }
    var markdownOwnsFirstResponder: Bool {
        currentFormat.usesEditor && markdownEditor?.webView.window === NSApp.keyWindow
            && markdownEditor?.ownsFirstResponder == true
    }
    func pasteAsPlainText() {
        guard let value = NSPasteboard.general.string(forType: .string), !isBusy else { return }
        if markdownOwnsFirstResponder { markdownEditor?.pasteAsPlainText(value) }
        else { NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil) }
    }
    func copyAllContents(asMarkdown: Bool = false, to pasteboard: NSPasteboard = .general) async {
        guard !isBusy, !onboarding.isPresented else { return }
        operation = .transition
        defer { operation = nil }
        let id = documentID
        guard await captureLatestEditor(), documentID == id else { return }
        do {
            let contents: PadClipboardContents
            // Copy as Markdown copies Markdown source only; an RTF document always copies readable text and HTML.
            if currentFormat == .rtf || (currentFormat == .md && !asMarkdown) {
                guard let editorClipboard else { throw PadMarkdownEditorError.unavailable }
                contents = try await editorClipboard()
            } else {
                contents = PadClipboardContents(text: text)
            }
            guard documentID == id else { return }
            try contents.write(to: pasteboard)
            notice = "Copied"
        } catch {
            report(error, during: .copy)
        }
    }
}
