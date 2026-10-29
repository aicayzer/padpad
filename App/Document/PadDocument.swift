import AppKit
import Darwin
import InkKitRTF
import KeyboardShortcuts
import Observation
import UniformTypeIdentifiers

enum PadReuse: Int, CaseIterable, Identifiable {
    case alwaysNew = 0, fiveMinutes = 5, tenMinutes = 10, fifteenMinutes = 15, thirtyMinutes = 30, oneHour = 60

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .alwaysNew: "Every opening"
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        }
    }
}

enum PadError: Error {
    case unsupported
    case encoding
    case changed
    case missingFolder
    case invalidName
    case emptyName
    case nameTooLong
    case nameExists
    case renamePermission
    case emptyShare
}

enum PadUnsavedChangesDecision {
    case save, discard, cancel
}

@MainActor
@Observable
final class PadDocument {
    enum Role { case quickPad, file }
    let diagnosticScope = UUID()
    let role: Role
    var isQuickPad: Bool { role == .quickPad }
    @ObservationIgnored weak var workspace: PadWorkspace?

    @ObservationIgnored var appSettings: AppSettings?
    let editingShortcuts: EditingShortcuts
    let onboarding: PadOnboarding
    var floating: Bool {
        didSet {
            defaults.set(floating, forKey: Self.floatingKey)
            panel?.level = isQuickPad && floating ? .floating : .normal
        }
    }
    private var defaultFormat: PadFormat
    var format: PadFormat {
        get { defaultFormat }
        set {
            guard enabledFormats.contains(newValue) else { return }
            defaultFormat = newValue
            defaults.set(newValue.rawValue, forKey: Self.formatKey)
            updateTitle()
        }
    }
    private(set) var enabledFormats: [PadFormat]

    func setFormatEnabled(_ candidate: PadFormat, enabled: Bool) {
        var selected = Set(enabledFormats)
        if enabled { selected.insert(candidate) } else { selected.remove(candidate) }
        guard !selected.isEmpty else { return }
        enabledFormats = PadFormat.allCases.filter { selected.contains($0) }
        defaults.set(enabledFormats.map(\.rawValue), forKey: Self.enabledFormatsKey)
        if !selected.contains(format), let first = enabledFormats.first { format = first }
    }

    var hasFormatChoices: Bool { enabledFormats.count > 1 || !enabledFormats.contains(currentFormat) }
    var saveAutomatically: Bool {
        didSet { defaults.set(saveAutomatically, forKey: Self.autoSaveKey) }
    }
    var reusePeriod: PadReuse {
        didSet { defaults.set(reusePeriod.rawValue, forKey: Self.reuseKey) }
    }
    var nameParts: [PadNamePart] {
        didSet {
            if let data = try? JSONEncoder().encode(nameParts) { defaults.set(data, forKey: Self.namePartsKey) }
        }
    }
    private(set) var folder: URL
    private(set) var url: URL?
    private(set) var startsInReadingMode = false
    private var pendingReadingDocumentID: UUID?
    private(set) var documentID = UUID()
    var text = "" {
        didSet { if currentFormat == .txt { recordDiagnostic(.edit) } }
    }
    private(set) var savedText = ""
    var isActive = false
    var settingsPresented = false
    var showSettings: @MainActor () -> Void = {}
    private(set) var renameRequest = 0
    /// A small problem shown in the panel. Problems that need a decision are alerts instead.
    private(set) var error: PadMessage? {
        didSet { if let error, error != oldValue { announceProblem(error) } }
    }
    /// The alert on screen. Its document is busy until the alert closes.
    private(set) var alert: PadAlert?
    private(set) var folderError: String?
    private(set) var editorFeedback: PadMarkdownEditorFeedback? {
        didSet { if let editorFeedback, editorFeedback != oldValue { announceProblem(editorFeedback.message) } }
    }
    private(set) var notice: String? {
        didSet {
            noticeTask?.cancel()
            noticeGeneration += 1
            guard notice != nil else { return }
            let generation = noticeGeneration
            let duration = noticeDuration
            noticeTask = Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                guard let self, generation == self.noticeGeneration else { return }
                self.notice = nil
            }
        }
    }
    private var noticeTask: Task<Void, Never>?
    private var noticeGeneration = 0
    private let noticeDuration: Duration
    private var baseline: Data?
    private var documentScope: URL?
    private var folderScope: URL?
    private var panel: (any PadDocumentWindow)?
    private var dismissedAt: Date?
    /// The format of a draft that has no file. Assign it only through `replaceDraft`, so the stored text
    /// always matches its format: RTF text is JSON, and Markdown or plain text written over it would be lost.
    private var scratchFormat: PadFormat
    private var snapshotApplied = false
    private var editorLoadedSource = ""
    private var editorLoadedDocumentID: UUID?
    private(set) var markdownEditor: PadMarkdownEditorController?
    @ObservationIgnored var editorClipboard: (@MainActor () async throws -> PadClipboardContents)?
    @ObservationIgnored var editorSnapshot: (@MainActor () async throws -> String?)?
    /// Converts the loaded editor document between Markdown and RTF.
    @ObservationIgnored var editorConversion: (@MainActor (PadFormat) async throws -> PadConversion)?
    private var pendingName: String?
    private var nextNumber: Int
    private enum Operation { case transition, filePanel, sharing }
    private var operation: Operation?
    private var sharePicker: NSSharingServicePicker?
    private var shareDelegate: PadSharePickerDelegate?
    private let defaults: UserDefaults
    private let presentsWindow: Bool
    private let copyPath: @MainActor (String) -> Void
    private let selectOpenFile: (@MainActor () async -> URL?)?
    private let selectSaveFolder: (@MainActor (URL) -> URL?)?
    private let selectSaveFile: (@MainActor (URL, String) async -> URL?)?
    private let resolveUnsavedChanges: (@MainActor () -> PadUnsavedChangesDecision)?
    private let presentAlert: PadAlert.Presenter
    private struct ReportedReadFailure: Equatable {
        let documentID: UUID
        let file: URL?
        let alert: PadAlert
        let bytes: Data?
    }
    // Returning focus after an alert must not repeat it for the same observed file contents.
    private var reportedReadFailure: ReportedReadFailure?

    private static let floatingKey = "pad.floating"
    private static let formatKey = "pad.format"
    private static let enabledFormatsKey = "pad.enabledFormats"
    private static let folderBookmarkKey = "pad.folderBookmark"
    private static let autoSaveKey = "pad.saveAutomatically"
    private static let reuseKey = "pad.reusePeriod"
    private static let namePartsKey = "pad.nameParts"
    private static let nextNumberKey = "pad.nextNumber"

    private static var downloadsFolder: URL {
        // FileManager points inside the sandbox. This path only suggests a location in the chooser.
        guard let record = getpwuid(getuid()), let home = String(validatingCString: record.pointee.pw_dir) else {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        return URL(fileURLWithPath: home, isDirectory: true).appending(path: "Downloads", directoryHint: .isDirectory)
    }

    init(defaults: UserDefaults = .standard,
         defaultFolder: URL? = nil, presentsWindow: Bool = true,
         role: Role = .quickPad, editingShortcuts: EditingShortcuts? = nil,
         noticeDuration: Duration = .seconds(2),
         copyPath: @escaping @MainActor (String) -> Void = {
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString($0, forType: .string)
         },
         selectOpenFile: (@MainActor () async -> URL?)? = nil,
         selectSaveFile: (@MainActor (URL, String) async -> URL?)? = nil,
         selectSaveFolder: (@MainActor (URL) -> URL?)? = nil,
         resolveUnsavedChanges: (@MainActor () -> PadUnsavedChangesDecision)? = nil,
         presentAlert: PadAlert.Presenter? = nil) {
        self.role = role
        self.noticeDuration = noticeDuration
        self.defaults = defaults
        self.editingShortcuts = editingShortcuts ?? EditingShortcuts(defaults: defaults)
        onboarding = PadOnboarding(defaults: defaults)
        self.presentsWindow = presentsWindow
        self.copyPath = copyPath
        self.selectOpenFile = selectOpenFile
        self.selectSaveFile = selectSaveFile
        self.selectSaveFolder = selectSaveFolder
        self.resolveUnsavedChanges = resolveUnsavedChanges
        // A document without windows has nowhere to show an alert, so tests never see a modal.
        let headless: PadAlert.Presenter = { _, _, completion in completion(false) }
        self.presentAlert = presentAlert ?? (presentsWindow ? PadAlert.presentSystem : headless)
        #if DEBUG
        let defaultFloating = false
        #else
        let defaultFloating = true
        #endif
        floating = defaults.object(forKey: Self.floatingKey) == nil ? defaultFloating : defaults.bool(forKey: Self.floatingKey)
        let storedFormats = defaults.stringArray(forKey: Self.enabledFormatsKey)
        let selected = PadFormat.allCases.filter { storedFormats?.contains($0.rawValue) ?? true }
        let enabled = selected.isEmpty ? PadFormat.allCases : selected
        enabledFormats = enabled
        let storedDefault = defaults.string(forKey: Self.formatKey).flatMap(PadFormat.init(rawValue:)) ?? .md
        let initialFormat = enabled.contains(storedDefault) ? storedDefault : enabled[0]
        defaultFormat = initialFormat
        scratchFormat = initialFormat
        if role == .quickPad, defaults.object(forKey: Self.enabledFormatsKey) != nil {
            if storedFormats != enabled.map(\.rawValue) {
                defaults.set(enabled.map(\.rawValue), forKey: Self.enabledFormatsKey)
            }
            if initialFormat != storedDefault { defaults.set(initialFormat.rawValue, forKey: Self.formatKey) }
        }
        saveAutomatically = role == .quickPad && (defaults.object(forKey: Self.autoSaveKey) == nil ? true : defaults.bool(forKey: Self.autoSaveKey))
        reusePeriod = PadReuse(rawValue: defaults.object(forKey: Self.reuseKey) as? Int ?? 15) ?? .fifteenMinutes
        nameParts = defaults.data(forKey: Self.namePartsKey)
            .flatMap { try? JSONDecoder().decode([PadNamePart].self, from: $0) } ?? PadFilename.defaultParts
        nextNumber = max(1, defaults.integer(forKey: Self.nextNumberKey))
        folder = defaultFolder ?? Self.downloadsFolder
        var stale = false
        if let data = defaults.data(forKey: Self.folderBookmarkKey),
           let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
            folder = resolved
            folderScope = resolved.startAccessingSecurityScopedResource() ? resolved : nil
            if stale, folderScope != nil,
               let refreshed = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(refreshed, forKey: Self.folderBookmarkKey)
            }
        }
    }

    var currentFormat: PadFormat { url.flatMap { PadFormat(rawValue: $0.pathExtension.lowercased()) } ?? scratchFormat }

    var isDirty: Bool { text != savedText }
    var canShare: Bool { !text.isEmpty && !isBusy }
    var isBusy: Bool { operation != nil || alert != nil }
    var isVisible: Bool { panel?.isVisible == true }
    var needsFolderSelection: Bool { !hasSaveFolderAccess }

    private var hasSaveFolderAccess: Bool {
        folderScope != nil || folder.resolvingSymlinksInPath().pathComponents
            .starts(with: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().pathComponents)
    }
    var editableName: String { url?.deletingPathExtension().lastPathComponent ?? pendingName ?? "Untitled" }
    var displayName: String {
        url?.lastPathComponent ?? pendingName.map { "\($0).\(currentFormat.rawValue)" } ?? "Untitled"
    }
    var namePreview: String {
        (try? PadFilename.name(parts: nameParts, format: format, number: nextNumber)) ?? "Invalid filename"
    }

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

    /// Clicking the message pill clears the problem it shows: a document error first, then editor feedback.
    func dismissMessage() {
        if error != nil { error = nil } else { editorFeedback = nil }
        guard nativeWindow?.isKeyWindow == true, let editor = markdownEditor,
              !editor.showingFind, !editor.showingLink else { return }
        editor.focus()
    }

    // A pill is not focused when it appears, so VoiceOver would otherwise miss it.
    private func announceProblem(_ message: PadMessage) {
        let announcement = [message.text, message.hint].compactMap(\.self).joined(separator: " ")
        NSAccessibility.post(element: (nativeWindow as NSObject?) ?? NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: "Error: \(announcement)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func reloadEditor() {
        editorFeedback = nil
        editorLoadedSource = text
        if editorLoadedDocumentID == documentID {
            markdownEditor?.reload(text, format: currentFormat, documentID: documentID)
        } else {
            editorLoadedDocumentID = documentID
            markdownEditor?.load(text, format: currentFormat, documentID: documentID)
        }
    }

    private func captureLatestEditor() async -> Bool {
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
        } catch {
            report(error, during: .snapshot)
            onboarding.dismiss()
            show()
            if !isActive, !onboarding.isPresented { panel?.resumeEditor() }
            return false
        }
    }

    // Web edits are asynchronous; hold document transitions until the final keystroke is read.
    private func synchronizeEditorThen(_ action: @escaping @MainActor () -> Void) -> Bool {
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

    func prepareToTerminate() async -> Bool {
        guard !isBusy else { return false }
        operation = .transition
        let captured = await captureLatestEditor()
        operation = nil
        return captured && canTerminate()
    }

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

    func chooseFolder(parent: NSWindow? = nil) async {
        guard !isBusy else { return }
        operation = .filePanel
        defer { operation = nil }
        let chosen: URL?
        if let selectSaveFolder {
            chosen = selectSaveFolder(folder)
        } else {
            let picker = saveFolderPicker(directory: folder)
            chosen = await present(picker, parent: parent ?? dialogParent) == .OK ? picker.url : nil
        }
        guard let chosen else { return }
        do {
            try rememberSaveFolder(chosen)
            folderError = nil
        } catch { folderError = "PadPad can’t use this folder. Choose another one." }
    }

    private func saveFolderPicker(directory: URL) -> NSOpenPanel {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.prompt = "Use Folder"
        picker.message = "Choose a folder for quick-pad files. PadPad will remember your choice."
        picker.directoryURL = directory
        return picker
    }

    private func rememberSaveFolder(_ chosen: URL) throws {
        let accessing = chosen.startAccessingSecurityScopedResource()
        do {
            guard try chosen.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw PadError.missingFolder
            }
            let data = try chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            folderScope?.stopAccessingSecurityScopedResource()
            defaults.set(data, forKey: Self.folderBookmarkKey)
            folder = chosen
            folderScope = accessing ? chosen : nil
        } catch {
            if accessing { chosen.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func obtainSaveFolderAccess() throws -> Bool {
        guard !hasSaveFolderAccess else { return true }
        // Close, New Draft, and Quit wait synchronously for a save decision.
        // Keep their transition locked while the native folder chooser runs.
        let previousOperation = operation
        operation = .filePanel
        defer { operation = previousOperation }
        let chosen: URL?
        if let selectSaveFolder {
            chosen = selectSaveFolder(folder)
        } else {
            NSApp.activate()
            let picker = saveFolderPicker(directory: folder)
            chosen = picker.runModal() == .OK ? picker.url : nil
        }
        guard let chosen else { return false }
        try rememberSaveFolder(chosen)
        guard hasSaveFolderAccess else { throw PadError.missingFolder }
        return true
    }

    private func forgetSaveFolder() {
        folderScope?.stopAccessingSecurityScopedResource()
        folderScope = nil
        defaults.removeObject(forKey: Self.folderBookmarkKey)
        folder = Self.downloadsFolder
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
        guard reusePeriod != .alwaysNew else { return false }
        guard let dismissedAt else { return true }
        return now.timeIntervalSince(dismissedAt) < TimeInterval(reusePeriod.rawValue * 60)
    }

    private func resetDocument() {
        startsInReadingMode = false
        pendingReadingDocumentID = nil
        documentID = UUID()
        documentScope?.stopAccessingSecurityScopedResource()
        documentScope = nil
        url = nil
        baseline = nil
        replaceDraft(format: format, text: "")
        savedText = ""
        error = nil
        reportedReadFailure = nil
        notice = nil
        dismissedAt = nil
        pendingName = nil
        reloadEditor()
    }

    func openPicker() async {
        guard !isBusy else { return }
        operation = .filePanel
        defer { operation = nil }
        guard await captureLatestEditor() else { return }
        let chosen = if let selectOpenFile { await selectOpenFile() } else { await presentOpenPanel() }
        guard let chosen else { return }
        if let workspace { workspace.open(chosen) } else { openDocument(chosen) }
    }

    private func presentOpenPanel() async -> URL? {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = PadFormat.allCases.map(\.contentType)
        picker.allowsOtherFileTypes = false
        guard await present(picker, parent: dialogParent) == .OK else { return nil }
        return picker.url
    }

    func open(_ file: URL) {
        if let workspace { workspace.open(file); return }
        if synchronizeEditorThen({ self.open(file) }) { return }
        guard !isBusy else { return }
        operation = .transition
        defer { operation = nil }
        openDocument(file)
    }

    @discardableResult
    func openDocument(_ file: URL) -> Bool {
        let leavingOnboarding = onboarding.isPresented
        // RTFD packages are not supported; their extension is refused like any other type.
        guard let format = PadFormat(rawValue: file.pathExtension.lowercased()) else {
            onboarding.dismiss()
            if isQuickPad || url != nil { show() }
            if leavingOnboarding { panel?.resumeEditor() }
            report(PadError.unsupported, during: .open)
            return false
        }
        if file.standardizedFileURL == url?.standardizedFileURL {
            onboarding.dismiss()
            refreshCurrentFile()
            if isQuickPad || url != nil { show() }
            if leavingOnboarding { panel?.resumeEditor() }
            return true
        }
        let accessing = file.startAccessingSecurityScopedResource()
        do {
            // An RTF file that holds content PadPad can't keep throws here, before anything is replaced.
            let (bytes, content) = try format.read(file)
            guard finishCurrent() else {
                if accessing { file.stopAccessingSecurityScopedResource() }
                if leavingOnboarding {
                    onboarding.dismiss()
                    if isQuickPad || url != nil { show() }
                    panel?.resumeEditor()
                }
                return false
            }
            documentScope?.stopAccessingSecurityScopedResource()
            documentScope = accessing ? file : nil
            startsInReadingMode = true
            documentID = UUID()
            url = file
            pendingReadingDocumentID = currentFormat.usesEditor ? documentID : nil
            text = content
            savedText = content
            baseline = bytes
            dismissedAt = nil
            onboarding.dismiss()
            pendingName = nil
            error = nil
            reportedReadFailure = nil
            notice = nil
            panel?.prepareReading()
            reloadEditor()
            if isQuickPad || url != nil { show() }
            return true
        } catch {
            if accessing { file.stopAccessingSecurityScopedResource() }
            onboarding.dismiss()
            if isQuickPad || url != nil { show() }
            if leavingOnboarding { panel?.resumeEditor() }
            report(error, during: .open)
            return false
        }
    }

    func refreshIfNeeded() {
        guard url != nil, !isBusy, !onboarding.isPresented else { return }
        // A newly mounted web editor has already received the disk contents.
        if let editor = markdownEditor, !editor.isReady { return }
        if synchronizeEditorThen({ self.refreshIfNeeded() }) { return }
        refreshCurrentFile()
    }

    private func refreshCurrentFile() {
        guard let url else { return }
        var observedBytes: Data?
        do {
            let bytes = try Data(contentsOf: url)
            observedBytes = bytes
            if isDirty {
                if currentFormat != .rtf, String(data: bytes, encoding: .utf8) == nil { throw PadError.encoding }
                guard bytes == baseline else { throw PadError.changed }
            } else if currentFormat == .rtf, bytes == baseline {
                // Converting unchanged bytes again would only reset the editor.
            } else {
                // A refused RTF change keeps the old baseline, so a later save reports the conflict.
                let content = try currentFormat.decode(bytes)
                text = content
                savedText = content
                baseline = bytes
                notice = nil
                reloadEditor()
            }
            error = nil
            reportedReadFailure = nil
        } catch {
            let failure = error as NSError
            // Only a confirmed missing file permits discarding a clean quick pad.
            // Permission, decoding and snapshot failures retain recoverable text.
            if isQuickPad, !isDirty, failure.domain == NSCocoaErrorDomain,
               failure.code == NSFileReadNoSuchFileError {
                resetDocument()
                return
            }
            report(error, during: .read, observedBytes: observedBytes)
        }
    }

    func save() {
        if synchronizeEditorThen({ self.save() }) { return }
        guard !isBusy else { return }
        saveCurrent()
    }

    private func saveCurrent() {
        recordDiagnostic(.save)
        let namesFile = url == nil && pendingName == nil
        var observedBytes: Data?
        do {
            if let url {
                let bytesOnDisk = try Data(contentsOf: url)
                observedBytes = bytesOnDisk
                guard bytesOnDisk == baseline else { throw PadError.changed }
                // Writing RTF restyles the whole file, so an unedited RTF file is never rewritten.
                if currentFormat == .rtf, !isDirty {
                    notice = "Saved"
                    error = nil
                    reportedReadFailure = nil
                    recordDiagnostic(.saveSucceeded)
                    return
                }
                // Conversion finishes before the atomic write, so a failure never leaves partial bytes.
                let bytes = try currentFormat.encode(text)
                try bytes.write(to: url, options: .atomic)
                baseline = bytes
                savedText = text
                notice = "Saved"
            } else {
                guard try obtainSaveFolderAccess() else { return }
                let bytes = try currentFormat.encode(text)
                let destination: URL
                if let pendingName {
                    destination = folder.appending(path: try PadFilename.filename(stem: pendingName, extension: currentFormat.rawValue))
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw PadError.nameExists }
                    try bytes.write(to: destination, options: .withoutOverwriting)
                } else {
                    destination = try saveGeneratedFile(bytes)
                }
                url = destination
                pendingName = nil
                baseline = bytes
                savedText = text
                documentScope = folder.startAccessingSecurityScopedResource() ? folder : nil
                copyPath(destination.path)
                notice = "Saved. Path copied."
            }
            error = nil
            reportedReadFailure = nil
            updateTitle()
            recordDiagnostic(.saveSucceeded)
        } catch { report(error, during: namesFile ? .nameFormat : .save, observedBytes: observedBytes) }
    }

    /// Switches an unsaved quick-pad draft to another format. Markdown and plain text keep the exact source;
    /// RTF converts, and a conversion that loses something changes nothing until the person confirms it.
    func changeFormat(to target: PadFormat) async {
        guard isQuickPad, url == nil, !isBusy, !onboarding.isPresented,
              enabledFormats.contains(target), target != currentFormat else { return }
        operation = .transition
        defer { operation = nil }
        guard await captureLatestEditor(), enabledFormats.contains(target) else { return }
        let id = documentID
        guard let conversion = await confirmedConversion(of: text, to: target, savingCopy: false, requiresEnabledFormat: true),
              documentID == id, enabledFormats.contains(target) else {
            show()
            panel?.resumeEditor()
            return
        }
        replaceDraft(format: target, text: conversion.text)
        reloadEditor()
        error = nil
        notice = nil
        updateTitle()
        show()
        panel?.resumeEditor()
    }

    /// Changes a draft's format and text together. An empty text is valid in every format.
    private func replaceDraft(format newFormat: PadFormat, text newText: String) {
        scratchFormat = newFormat
        text = newText
    }

    /// Converts text from the current format. Markdown and plain text share their source. Markdown and RTF
    /// convert in the editor; plain text and RTF convert with InkKitRTF.
    private func convert(_ content: String, to target: PadFormat) async throws -> PadConversion {
        let sharedSource: Set<PadFormat> = [.md, .txt]
        if currentFormat == target || (sharedSource.contains(currentFormat) && sharedSource.contains(target)) {
            return PadConversion(text: content, changes: [])
        }
        switch (currentFormat, target) {
        case (.txt, .rtf):
            // RTF can't hold U+0000 or U+FFFC as text, so InkKitRTF replaces them with U+FFFD.
            let replaced = content.unicodeScalars.contains { $0 == "\u{0}" || $0 == "\u{FFFC}" }
            return PadConversion(text: try PadRichText.text(for: RichTextDocument(plainText: content)),
                                 changes: replaced ? PadFormatLoss.changes(for: ["invalid-character"]) : [])
        case (.rtf, .txt):
            return PadConversion(text: try PadRichText.document(from: content).plainText, changes: PadFormatLoss.plainText)
        default:
            guard let editorConversion else { throw PadMarkdownEditorError.unavailable }
            return try await editorConversion(target)
        }
    }

    /// The converted text, or nil when the conversion failed or the person kept the original.
    private func confirmedConversion(of content: String, to target: PadFormat, savingCopy: Bool,
                                     requiresEnabledFormat: Bool = false) async -> PadConversion? {
        let id = documentID
        let conversion: PadConversion
        do {
            conversion = try await convert(content, to: target)
        } catch {
            report(error, during: .convert)
            return nil
        }
        guard documentID == id, !requiresEnabledFormat || enabledFormats.contains(target) else { return nil }
        if conversion.changes.isEmpty { return conversion }
        let alert = PadAlert.conversion(to: target, savingCopy: savingCopy, changes: conversion.changes)
        guard await confirm(alert), documentID == id else { return nil }
        return conversion
    }

    /// Shows a decision as an alert and waits for it. The document stays busy until the alert closes.
    private func confirm(_ alert: PadAlert) async -> Bool {
        guard self.alert == nil else { return false }
        self.alert = alert
        let window = nativeWindow?.isVisible == true ? nativeWindow : nil
        return await withCheckedContinuation { continuation in
            presentAlert(alert, window) { confirmed in
                self.alert = nil
                continuation.resume(returning: confirmed)
            }
        }
    }

    func saveAs(targetFormat: PadFormat? = nil) async {
        guard !isBusy else { return }
        operation = .filePanel
        defer { operation = nil }
        guard await captureLatestEditor() else { return }
        let previousFormat = currentFormat
        let saveFormat = targetFormat ?? currentFormat
        let id = documentID
        var content = text
        let directory = url?.deletingLastPathComponent() ?? folder
        let suggestion: (name: String, number: Int?)
        do {
            if let url {
                let name = targetFormat == nil ? url.lastPathComponent
                    : url.deletingPathExtension().appendingPathExtension(saveFormat.rawValue).lastPathComponent
                suggestion = (name, nil)
            } else if let pendingName {
                suggestion = (try PadFilename.filename(stem: pendingName, extension: saveFormat.rawValue), nil)
            } else {
                let generated = try PadFilename.available(in: directory, parts: nameParts,
                                                             format: saveFormat, number: nextNumber)
                guard generated.number < Int.max else { throw PadError.invalidName }
                suggestion = (generated.url.lastPathComponent, generated.number)
            }
        } catch {
            report(error, during: url == nil && pendingName == nil ? .nameFormat : .saveAs)
            return
        }
        let destination = if let selectSaveFile {
            await selectSaveFile(directory, suggestion.name)
        } else {
            await presentSavePanel(directory: directory, name: suggestion.name, targetFormat: targetFormat)
        }
        guard let destination, documentID == id else { return }
        let accessing = destination.startAccessingSecurityScopedResource()
        var observedBytes: Data?
        do {
            guard let destinationFormat = PadFormat(rawValue: destination.pathExtension.lowercased()) else { throw PadError.unsupported }
            guard workspace?.document(at: destination, excluding: self) == nil else { throw PadError.nameExists }
            if let targetFormat {
                guard destinationFormat == targetFormat else { throw PadError.unsupported }
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw PadError.nameExists }
            }
            if destination.standardizedFileURL == url?.standardizedFileURL {
                let bytes = try Data(contentsOf: destination)
                observedBytes = bytes
                guard bytes == baseline else { throw PadError.changed }
            }
            let unchangedCopy = destinationFormat == previousFormat && content == savedText ? baseline : nil
            var converted = false
            if destinationFormat != previousFormat {
                // The copy converts; the original file keeps its format and bytes.
                guard let conversion = await confirmedConversion(of: content, to: destinationFormat, savingCopy: url != nil),
                      documentID == id else {
                    if accessing { destination.stopAccessingSecurityScopedResource() }
                    return
                }
                converted = conversion.text != content
                content = conversion.text
            }
            // An unedited copy keeps the original bytes, including RTF fonts and colors.
            let bytes = try unchangedCopy ?? destinationFormat.encode(content)
            try bytes.write(to: destination, options: targetFormat == nil ? .atomic : .withoutOverwriting)
            documentScope?.stopAccessingSecurityScopedResource()
            documentScope = accessing ? destination : nil
            url = destination
            pendingName = nil
            baseline = bytes
            // A converted copy replaces the text; otherwise a late edit stays unsaved.
            if converted { text = content }
            savedText = content
            // A retained web editor must follow native edits when Save As changes formats.
            if currentFormat != previousFormat {
                reloadEditor()
                show()
                panel?.resumeEditor()
            }
            if let number = suggestion.number, destination.lastPathComponent == suggestion.name {
                advanceGeneratedNumber(after: number)
            }
            error = nil
            reportedReadFailure = nil
            notice = "Saved"
            updateTitle()
        } catch {
            if accessing { destination.stopAccessingSecurityScopedResource() }
            report(error, during: .saveAs, observedBytes: observedBytes)
        }
    }

    private func presentSavePanel(directory: URL, name: String, targetFormat: PadFormat? = nil) async -> URL? {
        let picker = NSSavePanel()
        picker.allowedContentTypes = PadFormat.allCases.map(\.contentType)
        if let targetFormat {
            picker.allowedContentTypes = [targetFormat.contentType]
            picker.allowsOtherFileTypes = false
        }
        picker.directoryURL = directory
        picker.nameFieldStringValue = name
        guard await present(picker, parent: dialogParent) == .OK else { return nil }
        return picker.url
    }

    func share(from anchor: NSView? = nil) {
        if synchronizeEditorThen({ self.share(from: anchor) }) { return }
        guard canShare, let view = anchor ?? panel?.contentView else { return }
        operation = .sharing
        do {
            let picker = NSSharingServicePicker(items: [try shareableURL()])
            let delegate = PadSharePickerDelegate { [weak self] in
                self?.operation = nil
                self?.sharePicker = nil
                self?.shareDelegate = nil
                if self?.panel?.isKeyWindow == false { self?.lostFocus() }
            }
            picker.delegate = delegate
            sharePicker = picker
            shareDelegate = delegate
            let rect = anchor == nil
                ? NSRect(x: view.bounds.maxX - 90, y: view.bounds.maxY - 38, width: 32, height: 24)
                : view.bounds
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
            error = nil
        } catch {
            operation = nil
            report(error, during: .share)
        }
    }

    func shareableURL(in temporaryFolder: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard !text.isEmpty else { throw PadError.emptyShare }
        if let url, !isDirty, let current = try? Data(contentsOf: url), current == baseline { return url }
        let directory = temporaryFolder.appending(path: "PadShare-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name: String
        if let url { name = url.lastPathComponent }
        else if let pendingName { name = "\(pendingName).\(currentFormat.rawValue)" }
        else { name = "Untitled.\(currentFormat.rawValue)" }
        let snapshot = directory.appending(path: name)
        try currentFormat.encode(text).write(to: snapshot, options: .atomic)
        return snapshot
    }

    func close(now: Date = .now) {
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

    private func finishCurrent(retainingDocument: Bool = false) -> Bool {
        guard isDirty else { return true }
        if isQuickPad && saveAutomatically {
            saveCurrent()
            return !isDirty
        }
        // Hiding retains both scratch and file edits. Only destructive transitions need a decision.
        if retainingDocument { return true }
        if url != nil || !text.isEmpty {
            switch resolveUnsavedChanges?() ?? confirmUnsavedChanges() {
            case .cancel: return false
            case .save:
                saveCurrent()
                return !isDirty
            case .discard:
                text = savedText
                reloadEditor()
            }
        } else {
            resetDocument()
        }
        return true
    }

    func canTerminate() -> Bool {
        guard !isBusy else { return false }
        operation = .transition
        defer { operation = nil }
        return finishCurrent()
    }

    var windowSize: NSSize? { panel?.frame.size }
    var nativeWindow: NSWindow? { panel }

    func restoreDefaultSize() { panel?.restoreDefaultSize() }
    func constrainWindowToScreens() { panel?.constrainToAvailableScreen() }
    func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func captureForReset() async -> Bool {
        guard !isBusy else { return false }
        operation = .transition
        defer { operation = nil }
        return await captureLatestEditor()
    }

    private func closeFileWindow() async {
        guard !isBusy else { return }
        operation = .transition
        let captured = await captureLatestEditor()
        operation = nil
        guard captured else { return }
        operation = .transition
        defer { operation = nil }
        if isDirty {
            let decision: PadUnsavedChangesDecision
            if let resolveUnsavedChanges { decision = resolveUnsavedChanges() }
            else { decision = await confirmFileClose() }
            switch decision {
            case .cancel: show(); return
            case .save:
                saveCurrent()
                guard !isDirty else { show(); return }
            case .discard:
                text = savedText
            }
        }
        isActive = false
        markdownEditor?.allowsFocus = false
        panel?.finishClosing()
        panel = nil
        documentScope?.stopAccessingSecurityScopedResource()
        documentScope = nil
        folderScope?.stopAccessingSecurityScopedResource()
        folderScope = nil
        workspace?.didClose(self)
    }

    func resetQuickPadPreferences() {
        floating = true
        // The default applies to future drafts; the current draft keeps its format and text.
        enabledFormats = PadFormat.allCases
        defaults.set(enabledFormats.map(\.rawValue), forKey: Self.enabledFormatsKey)
        format = .md
        saveAutomatically = false
        reusePeriod = .fifteenMinutes
        nameParts = PadFilename.defaultParts
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

    func requestRename() {
        guard isActive, !isBusy, !onboarding.isPresented else { return }
        renameRequest += 1
    }

    @discardableResult
    func rename(to input: String) -> Bool {
        guard !isBusy else { return false }
        var observedBytes: Data?
        do {
            let fileExtension = url?.pathExtension ?? currentFormat.rawValue
            let stem = try PadFilename.validatedStem(input)
            let name = try PadFilename.filename(stem: stem, extension: fileExtension)
            if let source = url {
                let destination = source.deletingLastPathComponent().appending(path: name)
                if destination != source {
                    guard canRenameInContainingFolder(source) else { throw PadError.renamePermission }
                    let bytes = try Data(contentsOf: source)
                    observedBytes = bytes
                    guard bytes == baseline else { throw PadError.changed }
                    // Exclusive rename prevents an existing destination from being replaced, including races.
                    let result = source.withUnsafeFileSystemRepresentation { sourcePath in
                        destination.withUnsafeFileSystemRepresentation { destinationPath in
                            renameatx_np(AT_FDCWD, sourcePath!, AT_FDCWD, destinationPath!, UInt32(RENAME_EXCL))
                        }
                    }
                    guard result == 0 else {
                        switch errno {
                        case EEXIST: throw PadError.nameExists
                        case EACCES, EPERM: throw PadError.renamePermission
                        default: throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                    }
                    url = destination
                    if documentScope?.standardizedFileURL == source.standardizedFileURL {
                        documentScope?.stopAccessingSecurityScopedResource()
                        documentScope = nil
                    }
                }
            } else {
                let destination = folder.appending(path: name)
                // Draft names refer to the configured save folder. Reject a
                // collision now, while Save still guards against later races.
                var attributes = stat()
                let exists = destination.withUnsafeFileSystemRepresentation { lstat($0!, &attributes) == 0 }
                guard !exists else { throw PadError.nameExists }
                pendingName = stem
            }
            error = nil
            notice = "Renamed"
            updateTitle()
            return true
        } catch {
            report(error, during: .rename, observedBytes: observedBytes)
            return false
        }
    }

    func recordDiagnostic(_ activity: PadDiagnostics.Activity) {
        appSettings?.diagnostics.record(activity, scope: diagnosticScope, format: currentFormat)
    }

    private func report(_ error: any Error, during context: PadProblem.Context, observedBytes: Data? = nil) {
        appSettings?.diagnostics.record(.error, scope: diagnosticScope, format: currentFormat,
                                        code: PadMarkdownEditorController.diagnosticCode(error))
        if let editor = markdownEditor { appSettings?.diagnostics.captureIncident(from: editor) }
        notice = nil
        switch PadProblem(error, during: context) {
        case .message(let message):
            self.error = message
        case .alert(let alert):
            let failure = ReportedReadFailure(documentID: documentID, file: url?.standardizedFileURL,
                                              alert: alert, bytes: observedBytes)
            if context == .read {
                guard failure != reportedReadFailure else { return }
                reportedReadFailure = failure
            } else if (error as? PadError) == .changed, observedBytes != nil {
                reportedReadFailure = failure
            }
            self.error = nil
            present(alert)
        }
    }

    private func present(_ alert: PadAlert) {
        // A file that fails to open has no window, and an alert without a window can open where nobody
        // sees it. The alert becomes a sheet on the window the person is using, or on the quick pad,
        // which stays busy, and so visible, until the alert closes.
        // Only open problems happen without a window, so the host's Choose File action still fits.
        if nativeWindow == nil, let workspace {
            let active = workspace.activeDocument
            let host = active !== self && active.nativeWindow?.isVisible == true ? active : workspace.quickPad
            if host !== self {
                if host.nativeWindow?.isVisible != true { host.show() }
                host.present(alert)
                return
            }
        }
        guard self.alert == nil else { return }
        self.alert = alert
        let window = nativeWindow?.isVisible == true ? nativeWindow : nil
        presentAlert(alert, window) { confirmed in
            self.alert = nil
            guard confirmed, let action = alert.action else { return }
            switch action {
            case .saveAs: Task { await self.saveAs() }
            case .openSettings: self.showSettings()
            case .chooseFile: Task { await (self.workspace?.activeDocument ?? self).openPicker() }
            case .convert: break
            }
        }
    }

    private func canRenameInContainingFolder(_ source: URL) -> Bool {
        guard documentScope?.standardizedFileURL == source.standardizedFileURL else { return true }
        // A grant for one file does not authorize its new sibling name. Save As can request that grant.
        let directory = source.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        let authorizedFolders = [FileManager.default.temporaryDirectory] + [folderScope].compactMap { $0 }
        return authorizedFolders.contains { directory.starts(with: $0.resolvingSymlinksInPath().pathComponents) }
    }

    private func saveGeneratedFile(_ bytes: Data) throws -> URL {
        let now = Date.now
        while true {
            let candidate = try PadFilename.available(in: folder, parts: nameParts, format: currentFormat,
                                                         now: now, number: nextNumber)
            guard candidate.number < Int.max else { throw PadError.invalidName }
            do {
                try bytes.write(to: candidate.url, options: .withoutOverwriting)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            advanceGeneratedNumber(after: candidate.number)
            return candidate.url
        }
    }

    private func advanceGeneratedNumber(after number: Int) {
        nextNumber = max(number + 1, max(nextNumber, defaults.integer(forKey: Self.nextNumberKey)))
        defaults.set(nextNumber, forKey: Self.nextNumberKey)
    }

    private func updateTitle() {
        panel?.representedURL = url
        panel?.title = isQuickPad ? "PadPad: \(displayName)" : displayName
    }

    func show() {
        dismissedAt = nil
        markdownEditor?.allowsFocus = !onboarding.isPresented && currentFormat.usesEditor
        if onboarding.isPresented { isActive = false }
        guard presentsWindow else { return }
        if panel == nil {
            panel = isQuickPad ? PadPanel(files: self) : PadFileWindow(files: self)
        }
        updateTitle()
        if !isQuickPad { NSApp.activate() }
        // Focus cannot succeed before the window is key.
        if panel?.isMiniaturized == true { panel?.deminiaturize(nil) }
        panel?.makeKeyAndOrderFront(nil)
    }

    private var dialogParent: NSWindow? {
        if let panel, panel.isVisible { return panel }
        return NSApp.keyWindow
    }

    private func present(_ picker: NSSavePanel, parent: NSWindow?) async -> NSApplication.ModalResponse {
        NSApp.activate()
        if let parent, parent.isVisible {
            parent.makeKeyAndOrderFront(nil)
            return await picker.beginSheetModal(for: parent)
        }
        return await picker.begin()
    }

    private func confirmFileClose() async -> PadUnsavedChangesDecision {
        guard let parent = dialogParent else { return confirmUnsavedChanges() }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(displayName)”?"
        alert.informativeText = "Your changes haven’t been saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parent) { response in
                switch response {
                case .alertFirstButtonReturn: continuation.resume(returning: .save)
                case .alertSecondButtonReturn: continuation.resume(returning: .discard)
                default: continuation.resume(returning: .cancel)
                }
            }
        }
    }

    private func confirmUnsavedChanges() -> PadUnsavedChangesDecision {
        let alert = NSAlert()
        alert.messageText = "Save changes?"
        alert.informativeText = "Save your changes to “\(displayName)” before continuing."
        alert.addButton(withTitle: "Save Changes")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        // Lay out before attaching: resizing an attached alert can offset it from its owner.
        alert.layout()
        let parent = dialogParent
        let screen = parent?.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            alert.window.setFrameOrigin(NSPoint(x: frame.midX - alert.window.frame.width / 2,
                                                y: frame.midY - alert.window.frame.height / 2))
        }
        // Keep the alert above a floating Pad without raising unrelated windows.
        parent?.addChildWindow(alert.window, ordered: .above)
        defer { parent?.removeChildWindow(alert.window) }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}

private final class PadSharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        onDismiss()
    }
}

@MainActor
enum PadPlainTextPrintView {
    static func make(_ text: String) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 1))
        view.minSize = .zero
        view.maxSize = NSSize(width: 540, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.string = text
        view.font = .systemFont(ofSize: 12)
        view.sizeToFit()
        return view
    }
}
