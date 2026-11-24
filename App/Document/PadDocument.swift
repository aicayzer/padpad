import AppKit
import Darwin
import InkKitRTF
import KeyboardShortcuts
import Observation
import UniformTypeIdentifiers

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

/// One quick pad or file window's document. State lives here; the extensions in `PadDocument+*.swift`
/// add behavior by concern and update that state directly, so it is internal rather than private.
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

    /// Formats, saving, draft lifetime and naming, shared by every document in the workspace.
    let drafts: PadDraftSettings
    var hasFormatChoices: Bool { drafts.enabledFormats.count > 1 || !drafts.enabledFormats.contains(currentFormat) }
    var folder: URL
    var url: URL?
    var startsInReadingMode = false
    var pendingReadingDocumentID: UUID?
    var documentID = UUID()
    var text = "" {
        didSet {
            guard currentFormat == .txt else { return }
            recordDiagnostic(.edit)
            if editorFeedback?.source == .edit { editorFeedback = nil }
        }
    }
    var savedText = ""
    var isActive = false
    var settingsPresented = false
    var showSettings: @MainActor () -> Void = {}
    var renameRequest = 0
    /// A small problem shown in the panel. Problems that need a decision are alerts instead.
    var error: PadMessage? {
        didSet { if let error, error != oldValue { announceProblem(error) } }
    }
    /// The alert on screen. Its document is busy until the alert closes.
    private(set) var alert: PadAlert?
    var folderError: String?
    var editorFeedback: PadMarkdownEditorFeedback? {
        didSet { if let editorFeedback, editorFeedback != oldValue { announceProblem(editorFeedback.message) } }
    }
    var notice: String? {
        didSet {
            noticeRevealsFile = false
            noticeHeld = false
            scheduleNoticeExpiry()
        }
    }
    /// The notice is about the saved file, so clicking it shows the file in Finder.
    private(set) var noticeRevealsFile = false
    private var noticeHeld = false

    private func scheduleNoticeExpiry() {
        noticeTask?.cancel()
        noticeGeneration += 1
        guard notice != nil, !noticeHeld else { return }
        let generation = noticeGeneration
        let duration = noticeDuration
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, generation == self.noticeGeneration else { return }
            self.notice = nil
        }
    }

    /// Keeps the notice while the pointer is over it, so there is time to click it.
    func holdNotice(_ held: Bool) {
        guard notice != nil, held != noticeHeld else { return }
        noticeHeld = held
        scheduleNoticeExpiry()
    }

    func announceFile(_ text: String) {
        notice = text
        noticeRevealsFile = url != nil
    }
    private var noticeTask: Task<Void, Never>?
    private var noticeGeneration = 0
    private let noticeDuration: Duration
    var baseline: Data?
    var documentScope: URL?
    var folderScope: URL?
    var panel: (any PadDocumentWindow)?
    var dismissedAt: Date?
    /// The format of a draft that has no file. Assign it only through `replaceDraft`, so the stored text
    /// always matches its format: RTF text is JSON, and Markdown or plain text written over it would be lost.
    var scratchFormat: PadFormat
    var snapshotApplied = false
    var editorLoadedSource = ""
    var editorLoadedDocumentID: UUID?
    var markdownEditor: PadMarkdownEditorController?
    @ObservationIgnored var editorClipboard: (@MainActor () async throws -> PadClipboardContents)?
    @ObservationIgnored var editorSnapshot: (@MainActor () async throws -> String?)?
    /// Converts the loaded editor document between Markdown and RTF.
    @ObservationIgnored var editorConversion: (@MainActor (PadFormat) async throws -> PadConversion)?
    var pendingName: String?
    /// The clock for generated names. Tests set it.
    var currentDate: @MainActor () -> Date = { .now }
    enum Operation { case transition, filePanel, sharing }
    var operation: Operation?
    var sharePicker: NSSharingServicePicker?
    var shareDelegate: PadSharePickerDelegate?
    let defaults: UserDefaults
    let presentsWindow: Bool
    let copyPath: @MainActor (String) -> Void
    let selectOpenFile: (@MainActor () async -> URL?)?
    let selectSaveFolder: (@MainActor (URL) -> URL?)?
    let selectSaveFile: (@MainActor (URL, String) async -> URL?)?
    let resolveUnsavedChanges: (@MainActor () -> PadUnsavedChangesDecision)?
    private let presentAlert: PadAlert.Presenter
    struct ReportedReadFailure: Equatable {
        let documentID: UUID
        let file: URL?
        let alert: PadAlert
        let bytes: Data?
    }
    // Returning focus after an alert must not repeat it for the same observed file contents.
    var reportedReadFailure: ReportedReadFailure?

    private static let floatingKey = "pad.floating"
    static let folderBookmarkKey = "pad.folderBookmark"

    static var downloadsFolder: URL {
        // FileManager points inside the sandbox. This path only suggests a location in the chooser.
        guard let record = getpwuid(getuid()), let home = String(validatingCString: record.pointee.pw_dir) else {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        return URL(fileURLWithPath: home, isDirectory: true).appending(path: "Downloads", directoryHint: .isDirectory)
    }

    init(defaults: UserDefaults = .standard,
         defaultFolder: URL? = nil, presentsWindow: Bool = true,
         role: Role = .quickPad, drafts: PadDraftSettings? = nil, editingShortcuts: EditingShortcuts? = nil,
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
        let drafts = drafts ?? PadDraftSettings(defaults: defaults, correctsStoredFormats: role == .quickPad)
        self.drafts = drafts
        scratchFormat = drafts.format
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

    var hasSaveFolderAccess: Bool {
        folderScope != nil || folder.resolvingSymlinksInPath().pathComponents
            .starts(with: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().pathComponents)
    }
    var editableName: String { url?.deletingPathExtension().lastPathComponent ?? pendingName ?? "Untitled" }
    var displayName: String {
        url?.lastPathComponent ?? pendingName.map { "\($0).\(currentFormat.rawValue)" } ?? "Untitled"
    }
    var namePreview: String { drafts.namePreview(now: currentDate()) }

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

    /// Shows a decision as an alert and waits for it. The document stays busy until the alert closes.
    func confirm(_ alert: PadAlert) async -> Bool {
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

    var windowSize: NSSize? { panel?.frame.size }
    /// The configured default size for this document's kind of window.
    var defaultWindowSize: NSSize {
        guard let appSettings else { return isQuickPad ? PadWindowSize.quickPad : PadWindowSize.fileWindow }
        return isQuickPad ? NSSize(width: appSettings.quickPadWidth, height: appSettings.quickPadHeight)
            : NSSize(width: appSettings.fileWindowWidth, height: appSettings.fileWindowHeight)
    }
    var nativeWindow: NSWindow? { panel }

    func restoreDefaultSize() { panel?.restoreDefaultSize() }
    func constrainWindowToScreens() { panel?.constrainToAvailableScreen() }

    func recordDiagnostic(_ activity: PadDiagnostics.Activity) {
        appSettings?.diagnostics.record(activity, scope: diagnosticScope, format: currentFormat)
    }

    func report(_ error: any Error, during context: PadProblem.Context, observedBytes: Data? = nil) {
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

    func updateTitle() {
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

    var dialogParent: NSWindow? {
        if let panel, panel.isVisible { return panel }
        return NSApp.keyWindow
    }
}
