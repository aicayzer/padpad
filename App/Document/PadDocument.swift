import AppKit
import Darwin
import KeyboardShortcuts
import Observation
import UniformTypeIdentifiers

enum PadFormat: String, CaseIterable, Identifiable {
    case txt, md

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

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

enum PadError: LocalizedError {
    case unsupported
    case encoding
    case changed
    case missingFolder
    case invalidName
    case emptyName
    case nameTooLong
    case nameExists
    case renamePermission

    var errorDescription: String? {
        switch self {
        case .unsupported: "Choose a Markdown (.md) or text (.txt) file."
        case .encoding: "PadPad can’t read this file’s text encoding."
        case .changed: "This file changed elsewhere. Choose “Save As” to keep your changes."
        case .missingFolder: "This folder is unavailable. Choose it again in Settings → Files."
        case .emptyName: "Enter a file name."
        case .nameTooLong: "This file name is too long. Try a shorter one."
        case .invalidName: "This file name isn’t valid. Try another name."
        case .nameExists: "A file with this name already exists. Choose another name."
        case .renamePermission: "PadPad needs folder access to rename this file. Choose “Save As”."
        }
    }
}

enum PadUnsavedChangesDecision {
    case save, discard, cancel
}

@MainActor
@Observable
final class PadDocument {
    enum Role { case quickPad, file }
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
    var format: PadFormat {
        didSet {
            defaults.set(format.rawValue, forKey: Self.formatKey)
            updateTitle()
        }
    }
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
    private(set) var documentID = UUID()
    var text = ""
    private(set) var savedText = ""
    var isActive = false
    var settingsPresented = false
    var showSettings: @MainActor () -> Void = {}
    private(set) var renameRequest = 0
    var error: String?
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
    private var scratchFormat: PadFormat
    private var snapshotApplied = false
    private var editorLoadedSource = ""
    private(set) var markdownEditor: PadMarkdownEditorController?
    @ObservationIgnored var editorClipboard: (@MainActor () async throws -> PadClipboardContents)?
    @ObservationIgnored var editorSnapshot: (@MainActor () async throws -> String?)?
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

    private static let floatingKey = "pad.floating"
    private static let formatKey = "pad.format"
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
         resolveUnsavedChanges: (@MainActor () -> PadUnsavedChangesDecision)? = nil) {
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
        #if DEBUG
        let defaultFloating = false
        #else
        let defaultFloating = true
        #endif
        floating = defaults.object(forKey: Self.floatingKey) == nil ? defaultFloating : defaults.bool(forKey: Self.floatingKey)
        format = defaults.string(forKey: Self.formatKey).flatMap(PadFormat.init(rawValue:)) ?? .md
        scratchFormat = defaults.string(forKey: Self.formatKey).flatMap(PadFormat.init(rawValue:)) ?? .md
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
    var isBusy: Bool { operation != nil }
    var isVisible: Bool { panel?.isVisible == true }
    var isDefaultFolder: Bool { folder.standardizedFileURL == Self.downloadsFolder.standardizedFileURL }
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

    func mountMarkdownEditor() {
        guard !onboarding.isPresented, currentFormat == .md, markdownEditor == nil else { return }
        let editor = PadMarkdownEditorController()
        editor.onChanged = { [weak self] markdown, id in
            guard let self, self.documentID == id, self.currentFormat == .md, !self.onboarding.isPresented else { return }
            self.text = markdown
        }
        editor.onError = { [weak self] error in
            guard let self, self.currentFormat == .md, !self.onboarding.isPresented else { return }
            self.error = readableError(error, fallback: "The editor couldn’t complete that action. Your text is still open.")
        }
        editor.onReady = { [weak self] in
            guard let self, !self.onboarding.isPresented, self.currentFormat == .md else { return }
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
        editorLoadedSource = text
        editor.load(text, documentID: documentID)
    }

    private func reloadEditor() {
        editorLoadedSource = text
        markdownEditor?.load(text, documentID: documentID)
    }

    private func captureLatestEditor() async -> Bool {
        guard !onboarding.isPresented, currentFormat == .md, let editorSnapshot else { return true }
        let id = documentID
        panel?.prepareMarkdownSnapshot()
        do {
            let latest = try await editorSnapshot()
            guard id == documentID else { return false }
            text = latest ?? editorLoadedSource
            return true
        } catch {
            self.error = "Couldn’t read your text. Try again."
            onboarding.dismiss()
            show()
            if !isActive, !onboarding.isPresented { panel?.resumeEditor() }
            return false
        }
    }

    // Web edits are asynchronous; hold document transitions until the final keystroke is read.
    private func synchronizeEditorThen(_ action: @escaping @MainActor () -> Void) -> Bool {
        guard !snapshotApplied, currentFormat == .md, editorSnapshot != nil else { return false }
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

    func pasteAsPlainText() {
        guard let value = NSPasteboard.general.string(forType: .string), !isBusy else { return }
        if currentFormat == .md { markdownEditor?.pasteAsPlainText(value) }
        else { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
    }

    func copyAllContents(asMarkdown: Bool = false, to pasteboard: NSPasteboard = .general) async {
        guard !isBusy, !onboarding.isPresented else { return }
        operation = .transition
        defer { operation = nil }
        let id = documentID
        guard await captureLatestEditor(), documentID == id else { return }
        do {
            let contents: PadClipboardContents
            if currentFormat == .md, !asMarkdown {
                guard let editorClipboard else { throw PadMarkdownEditorError.unavailable }
                contents = try await editorClipboard()
            } else {
                contents = PadClipboardContents(text: text)
            }
            guard documentID == id else { return }
            try contents.write(to: pasteboard)
            notice = "Copied"
        } catch {
            self.error = "Couldn’t copy your text. Try again."
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
            scratchFormat = .md
            text = """
            # A little room to think

            Write a thought here. **Keep what matters.**

            ## One small next step

            - [ ] Write down what's on your mind
            - [ ] Choose one thing to do next
            - [ ] Save this file if you want to keep it

            > Your shortcut brings this pad back whenever you need it.

            """
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

    func chooseFolder(parent: NSWindow? = nil, useDownloads: Bool = false) async {
        guard !isBusy else { return }
        operation = .filePanel
        defer { operation = nil }
        let picker = saveFolderPicker(directory: useDownloads ? Self.downloadsFolder : folder)
        guard await present(picker, parent: parent ?? dialogParent) == .OK, let chosen = picker.url else { return }
        do {
            try rememberSaveFolder(chosen)
            error = nil
        } catch { self.error = readableError(error, fallback: "Couldn’t use this folder. Choose another folder.") }
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
        } else if url != nil || isReusable(at: now) {
            refreshCurrentFile()
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
        documentID = UUID()
        scratchFormat = format
        documentScope?.stopAccessingSecurityScopedResource()
        documentScope = nil
        url = nil
        baseline = nil
        text = ""
        savedText = ""
        error = nil
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
        picker.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
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
        guard ["txt", "md"].contains(file.pathExtension.lowercased()) else {
            error = PadError.unsupported.localizedDescription
            onboarding.dismiss()
            if isQuickPad || url != nil { show() }
            if leavingOnboarding { panel?.resumeEditor() }
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
            let bytes = try Data(contentsOf: file)
            guard let content = String(data: bytes, encoding: .utf8) else { throw PadError.encoding }
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
            documentID = UUID()
            url = file
            text = content
            savedText = content
            baseline = bytes
            dismissedAt = nil
            onboarding.dismiss()
            pendingName = nil
            error = nil
            notice = nil
            reloadEditor()
            if isQuickPad || url != nil { show() }
            if leavingOnboarding { panel?.resumeEditor() }
            return true
        } catch {
            if accessing { file.stopAccessingSecurityScopedResource() }
            self.error = readableError(error, fallback: "Couldn’t open this file. Try opening it again.")
            onboarding.dismiss()
            if isQuickPad || url != nil { show() }
            if leavingOnboarding { panel?.resumeEditor() }
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
        do {
            let bytes = try Data(contentsOf: url)
            guard let content = String(data: bytes, encoding: .utf8) else { throw PadError.encoding }
            if isDirty {
                guard bytes == baseline else { throw PadError.changed }
            } else {
                text = content
                savedText = content
                baseline = bytes
                notice = nil
                reloadEditor()
            }
            error = nil
        } catch {
            self.error = readableError(error, fallback: "Couldn’t read this file. Your text is still open.")
            notice = nil
        }
    }

    func save() {
        if synchronizeEditorThen({ self.save() }) { return }
        guard !isBusy else { return }
        saveCurrent()
    }

    private func saveCurrent() {
        do {
            if let url {
                guard try Data(contentsOf: url) == baseline else { throw PadError.changed }
                let bytes = Data(text.utf8)
                try bytes.write(to: url, options: .atomic)
                baseline = bytes
                savedText = text
                notice = "Saved"
            } else {
                guard try obtainSaveFolderAccess() else { return }
                let bytes = Data(text.utf8)
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
            updateTitle()
        } catch { self.error = readableError(error, fallback: "Couldn’t save your changes. Your text is still open."); notice = nil }
    }

    func toggleFormat() async {
        guard isQuickPad, url == nil, !isBusy, !onboarding.isPresented else { return }
        let target: PadFormat = currentFormat == .md ? .txt : .md
        operation = .transition
        defer { operation = nil }
        guard await captureLatestEditor() else { return }
        scratchFormat = target
        // The source is deliberately unchanged. TXT shows Markdown's exact source bytes.
        reloadEditor()
        error = nil
        notice = nil
        updateTitle()
        show()
        panel?.resumeEditor()
    }

    func saveAs(targetFormat: PadFormat? = nil) async {
        guard !isBusy else { return }
        operation = .filePanel
        defer { operation = nil }
        guard await captureLatestEditor() else { return }
        let previousFormat = currentFormat
        let saveFormat = targetFormat ?? currentFormat
        let id = documentID
        let content = text
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
            self.error = readableError(error, fallback: "Couldn’t create a file name. Check your naming settings.")
            notice = nil
            return
        }
        let destination = if let selectSaveFile {
            await selectSaveFile(directory, suggestion.name)
        } else {
            await presentSavePanel(directory: directory, name: suggestion.name, targetFormat: targetFormat)
        }
        guard let destination, documentID == id else { return }
        let accessing = destination.startAccessingSecurityScopedResource()
        do {
            guard PadFormat(rawValue: destination.pathExtension.lowercased()) != nil else { throw PadError.unsupported }
            guard workspace?.document(at: destination, excluding: self) == nil else { throw PadError.nameExists }
            if let targetFormat {
                guard destination.pathExtension.lowercased() == targetFormat.rawValue else { throw PadError.unsupported }
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw PadError.nameExists }
            }
            if destination.standardizedFileURL == url?.standardizedFileURL,
               try Data(contentsOf: destination) != baseline {
                throw PadError.changed
            }
            let bytes = Data(content.utf8)
            try bytes.write(to: destination, options: targetFormat == nil ? .atomic : .withoutOverwriting)
            documentScope?.stopAccessingSecurityScopedResource()
            documentScope = accessing ? destination : nil
            url = destination
            pendingName = nil
            baseline = bytes
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
            notice = "Saved"
            updateTitle()
        } catch {
            if accessing { destination.stopAccessingSecurityScopedResource() }
            self.error = readableError(error, fallback: "Couldn’t save your changes. Your text is still open.")
            notice = nil
        }
    }

    private func presentSavePanel(directory: URL, name: String, targetFormat: PadFormat? = nil) async -> URL? {
        let picker = NSSavePanel()
        picker.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        if let targetFormat {
            picker.allowedContentTypes = targetFormat == .md
                ? [UTType(filenameExtension: "md") ?? .plainText] : [.plainText]
            picker.allowsOtherFileTypes = false
        }
        picker.directoryURL = directory
        picker.nameFieldStringValue = name
        guard await present(picker, parent: dialogParent) == .OK else { return nil }
        return picker.url
    }

    func share(from anchor: NSView? = nil) {
        if synchronizeEditorThen({ self.share(from: anchor) }) { return }
        guard !isBusy, let view = anchor ?? panel?.contentView else { return }
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
            self.error = readableError(error, fallback: "Couldn’t share this file. Try again.")
        }
    }

    func shareableURL(in temporaryFolder: URL = FileManager.default.temporaryDirectory) throws -> URL {
        if let url, !isDirty, let current = try? Data(contentsOf: url), current == baseline { return url }
        let directory = temporaryFolder.appending(path: "PadShare-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name: String
        if let url { name = url.lastPathComponent }
        else if let pendingName { name = "\(pendingName).\(currentFormat.rawValue)" }
        else { name = try PadFilename.name(parts: nameParts, format: currentFormat, number: nextNumber) }
        let snapshot = directory.appending(path: name)
        try Data(text.utf8).write(to: snapshot, options: .atomic)
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
        if url == nil { format = .md }
        scratchFormat = .md
        defaults.set(PadFormat.md.rawValue, forKey: Self.formatKey)
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
        do {
            let fileExtension = url?.pathExtension ?? currentFormat.rawValue
            let stem = try PadFilename.validatedStem(input)
            let name = try PadFilename.filename(stem: stem, extension: fileExtension)
            if let source = url {
                let destination = source.deletingLastPathComponent().appending(path: name)
                if destination != source {
                    guard canRenameInContainingFolder(source) else { throw PadError.renamePermission }
                    guard try Data(contentsOf: source) == baseline else { throw PadError.changed }
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
            self.error = readableError(error, fallback: "Couldn’t rename this file. Try another name or choose “Save As”.")
            notice = nil
            return false
        }
    }

    private func readableError(_ error: any Error, fallback: String) -> String {
        if let error = error as? PadError { return error.localizedDescription }
        if let error = error as? PadMarkdownEditorError { return error.localizedDescription }
        if let error = error as? CocoaError {
            switch error.code {
            case .fileReadNoSuchFile: return "This file is no longer available. Choose another file."
            case .fileReadNoPermission:
                return "PadPad can’t access this file. Choose it again with “Open File”."
            case .fileWriteNoPermission:
                return "PadPad can’t save in this folder. Choose “Save As”."
            case .fileWriteOutOfSpace: return "There isn’t enough storage to save. Free up some space and try again."
            case .fileWriteFileExists: return PadError.nameExists.localizedDescription
            default: break
            }
        }
        return fallback
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
        markdownEditor?.allowsFocus = !onboarding.isPresented && currentFormat == .md
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
