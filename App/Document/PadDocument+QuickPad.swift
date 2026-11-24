import AppKit
import InkKitRTF
import KeyboardShortcuts

// The quick pad's lifecycle: showing and hiding, clearing drafts, onboarding and preferences.
extension PadDocument {
    func installShortcut() {
        KeyboardShortcuts.onKeyDown(for: .pad) { [weak self] in self?.handleGlobalShortcut() }
        KeyboardShortcuts.onKeyUp(for: .pad) { [weak self] in self?.onboarding.releaseShortcut() }
    }

    /// Rehearsal advances only on an actual registered global-shortcut event.
    func handleGlobalShortcut() {
        guard !isBusy, workspace?.isTransitioning != true else { return }
        if onboarding.isPresented {
            if onboarding.stage == .practice { onboarding.recordShortcut() }
            show()
        } else {
            toggle()
        }
    }

    func restartOnboarding() async {
        guard !isBusy else { return }
        operation = .transition
        defer { operation = nil }
        // A replay must retain the last keystroke without saving or replacing the document.
        if !onboarding.isPresented {
            guard await captureLatestEditor() else { return }
        }
        panel?.prepareOnboarding()
        onboarding.begin(resetCompletion: true)
        isActive = false
        show()
    }

    func finishOnboarding(includeExample: Bool) {
        guard !isBusy, onboarding.isPresented else { return }
        if includeExample, isPristineScratch {
            replaceDraft(format: .md, text: """
            # A little room to think

            Write a thought here. **Keep what matters.**

            ## One small next step

            - [ ] Write down what's on your mind
            - [ ] Choose one thing to do next
            - [ ] Save this file if you want to keep it

            > Your shortcut brings this pad back whenever you need it.

            """)
        }
        onboarding.complete()
        reloadEditor()
        show()
        panel?.resumeEditor()
    }

    private var isPristineScratch: Bool {
        url == nil && text.isEmpty && savedText.isEmpty && pendingName == nil
    }

    private func presentOnboardingIfNeeded() -> Bool {
        if onboarding.isPresented {
            show()
            return true
        }
        guard isQuickPad, presentsWindow, isPristineScratch, error == nil, onboarding.beginIfNeeded() else { return false }
        panel?.prepareOnboarding()
        isActive = false
        show()
        return true
    }

    func newFile(now: Date = .now) {
        if !isQuickPad, let workspace { workspace.quickPad.newFile(now: now); return }
        guard !isBusy else { return }
        if onboarding.isPresented { show(); return }
        if synchronizeEditorThen({ self.newFile(now: now) }) { return }
        guard !isBusy else { return }
        operation = .transition
        defer { operation = nil }
        guard finishCurrent() else { return }
        resetDocument()
        dismissedAt = nil
        show()
    }

    func toggle(now: Date = .now) {
        guard !isBusy else { return }
        if onboarding.isPresented { show(); return }
        // Hiding already captures the editor. Reopening must not wait on JavaScript
        // in an offscreen WebKit view; show the retained document immediately.
        if presentOnboardingIfNeeded() { return }
        guard !isBusy else { return }
        if isVisible {
            close(now: now)
            return
        }
        let explains = clearIfExpired(now: now)
        show()
        // Show before capturing: an offscreen WebKit view may not answer a snapshot.
        if url != nil { refreshIfNeeded() }
        if explains { present(.draftKept(clearing: drafts.clearingDescription)) }
    }

    /// Applies the clear time to the hidden quick pad. A saved file stays on disk and a saved file with unsaved
    /// edits never clears. The first unsaved draft that would clear is kept instead, and the result is true so
    /// the caller explains, once, how drafts clear.
    func clearIfExpired(now: Date) -> Bool {
        if isReusable(at: now) || (url != nil && isDirty) { return false }
        if url == nil, !text.isEmpty, !drafts.explainedClearing {
            drafts.explainedClearing = true
            return true
        }
        // Expired drafts deliberately clear without a save prompt.
        resetDocument()
        return false
    }

    func showCurrent(now: Date = .now) {
        guard !isBusy else { return }
        if !onboarding.hasCompleted, !onboarding.isPresented,
           synchronizeEditorThen({ self.showCurrent(now: now) }) { return }
        if presentOnboardingIfNeeded() { return }
        if isVisible {
            show()
        } else {
            toggle(now: now)
        }
    }

    func commandNew(now: Date = .now) {
        if !isQuickPad, let workspace { workspace.quickPad.commandNew(now: now); return }
        guard !isBusy else { return }
        if !onboarding.isPresented, synchronizeEditorThen({ self.commandNew(now: now) }) { return }
        if presentOnboardingIfNeeded() { return }
        newFile(now: now)
    }

    private func isReusable(at now: Date) -> Bool {
        guard drafts.reusePeriod != .alwaysNew else { return false }
        guard let dismissedAt else { return true }
        return now.timeIntervalSince(dismissedAt) < TimeInterval(drafts.reusePeriod.rawValue * 60)
    }

    func resetDocument() {
        startsInReadingMode = false
        pendingReadingDocumentID = nil
        documentID = UUID()
        documentScope?.stopAccessingSecurityScopedResource()
        documentScope = nil
        url = nil
        baseline = nil
        replaceDraft(format: drafts.format, text: "")
        savedText = ""
        error = nil
        reportedReadFailure = nil
        notice = nil
        dismissedAt = nil
        pendingName = nil
        reloadEditor()
    }

    func close(now: Date = .now) {
        if !snapshotApplied { recordDiagnostic(.close) }
        if !isQuickPad {
            Task { await closeFileWindow() }
            return
        }
        guard !isBusy else { return }
        if onboarding.isPresented {
            let pristine = isPristineScratch
            onboarding.dismiss()
            if pristine {
                isActive = false
                dismissedAt = nil
                panel?.orderOut(nil)
                return
            }
            // Replaying the welcome does not exempt an existing draft from normal close rules.
        }
        if synchronizeEditorThen({ self.close(now: now) }) { return }
        guard !isBusy else { return }
        operation = .transition
        defer { operation = nil }
        guard finishCurrent(retainingDocument: true) else {
            show()
            panel?.resumeEditor()
            return
        }
        dismissedAt = now
        isActive = false
        panel?.orderOut(nil)
    }

    func lostFocus() {
        guard isQuickPad else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.onboarding.isPresented, !self.isBusy, !self.settingsPresented, self.markdownEditor?.showingLink != true,
                  self.panel?.isVisible == true, self.panel?.isKeyWindow == false else { return }
            self.close()
        }
    }

    func resetQuickPadPreferences() {
        floating = true
        drafts.reset()
        // Keep an independent scope alive for an open file before forgetting its save-folder grant.
        if documentScope == nil, url != nil, let folderScope {
            documentScope = folderScope
            self.folderScope = nil
        }
        if documentScope == nil, let url {
            let directory = url.deletingLastPathComponent()
            if directory.startAccessingSecurityScopedResource() { documentScope = directory }
        }
        forgetSaveFolder()
        editingShortcuts.restoreDefaults()
        onboarding.resetCompletion()
        // Retained text cannot expire as an accidental consequence of resetting preferences.
        dismissedAt = nil
    }

    func expand() { panel?.toggleExpanded() }

    /// Adds text from Shortcuts to the end of the quick pad's document and shows it. A hidden pad follows the
    /// usual clearing rules first, so a draft past its clear time clears and the text starts a new one.
    func add(_ addition: String, now: Date = .now) async throws {
        guard isQuickPad, !addition.isEmpty else { return }
        guard onboarding.hasCompleted, !onboarding.isPresented else { throw PadIntentError.introductionNotFinished }
        // Another operation may replace the document when it finishes, which would lose the added text.
        guard !isBusy, workspace?.isTransitioning != true else { throw PadIntentError.busy }
        operation = .transition
        var explains = false
        if isVisible {
            // The editor holds the latest text. Reloading it before it has loaded would drop typing it buffered.
            if currentFormat.usesEditor {
                guard markdownEditor?.isReady == true, await captureLatestEditor() else {
                    operation = nil
                    throw PadIntentError.busy
                }
            }
        } else {
            // Closing captured the editor, so `text` is current.
            explains = clearIfExpired(now: now)
        }
        do {
            text = try Self.appending(addition, to: text, format: currentFormat)
        } catch {
            operation = nil
            throw error
        }
        reloadEditor()
        operation = nil
        show()
        panel?.resumeEditor()
        if explains { present(.draftKept(clearing: drafts.clearingDescription)) }
    }

    /// Markdown starts the addition as a new paragraph, plain text on a new line and RTF as new paragraphs.
    /// Existing text, including blank lines at its end, is kept as it is.
    static func appending(_ addition: String, to text: String, format: PadFormat) throws -> String {
        switch format {
        case .rtf:
            var document = try PadRichText.document(from: text)
            let added = RichTextDocument(plainText: addition).blocks
            document.blocks = document.plainText.isEmpty ? added : document.blocks + added
            return try PadRichText.text(for: document)
        case .md, .txt:
            guard !text.isEmpty else { return addition }
            let needed = format == .md ? 2 : 1
            let present = text.reversed().prefix { $0 == "\n" }.count
            return text + String(repeating: "\n", count: max(0, needed - present)) + addition
        }
    }
}

/// A Shortcuts action that PadPad can't carry out right now.
enum PadIntentError: Error, CustomLocalizedStringResourceConvertible {
    case introductionNotFinished, busy

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .introductionNotFinished: "Finish the PadPad introduction first."
        case .busy: "PadPad is busy. Try again."
        }
    }
}
