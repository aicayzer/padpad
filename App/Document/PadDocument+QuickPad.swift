import AppKit
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
        } else if url != nil {
            // Show before capturing: an offscreen WebKit view may not answer a snapshot.
            show()
            refreshIfNeeded()
        } else if isReusable(at: now) {
            show()
        } else {
            // Expired temporary drafts deliberately clear without a save prompt.
            resetDocument()
            show()
        }
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
}
