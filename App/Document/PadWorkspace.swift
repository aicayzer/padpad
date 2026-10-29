import AppKit
import KeyboardShortcuts
import Observation

/// Owns the quick pad and independent document lifetimes; menus never guess a document from a filename.
@MainActor
@Observable
final class PadWorkspace {
    let quickPad: PadDocument
    let settings: AppSettings
    private(set) var documents: [PadDocument] = []
    private var focusedDocument: PadDocument
    private let defaults: UserDefaults
    private let presentsWindows: Bool
    private(set) var isTransitioning = false
    private(set) var resetError: String?
    private let presentAlert: PadAlert.Presenter?

    init(settings: AppSettings, defaults: UserDefaults = .standard, presentsWindows: Bool = true,
         defaultFolder: URL? = nil, noticeDuration: Duration = .seconds(2),
         presentAlert: PadAlert.Presenter? = nil) {
        self.settings = settings
        self.defaults = defaults
        self.presentsWindows = presentsWindows
        self.presentAlert = presentAlert
        let pad = PadDocument(defaults: defaults, defaultFolder: defaultFolder,
                              presentsWindow: presentsWindows, noticeDuration: noticeDuration,
                              presentAlert: presentAlert)
        quickPad = pad
        focusedDocument = pad
        pad.appSettings = settings
        pad.workspace = self
    }

    var activeDocument: PadDocument { focusedDocument }
    var canUseFileSize: Bool { documents.contains { $0.windowSize != nil } }
    var fileForSettings: PadDocument? {
        documents.first(where: { $0 === focusedDocument }) ?? documents.last
    }
    var allDocuments: [PadDocument] { [quickPad] + documents }

    func didFocus(_ document: PadDocument) {
        focusedDocument = document
        document.recordDiagnostic(.focus)
    }

    func open(_ file: URL) {
        guard !isTransitioning else { return }
        let scope = file.startAccessingSecurityScopedResource()
        defer { if scope { file.stopAccessingSecurityScopedResource() } }
        if let existing = document(at: file) {
            existing.showCurrent()
            return
        }
        let document = PadDocument(defaults: defaults, defaultFolder: quickPad.folder,
                                   presentsWindow: presentsWindows, role: .file,
                                   editingShortcuts: quickPad.editingShortcuts, presentAlert: presentAlert)
        document.appSettings = settings
        document.workspace = self
        documents.append(document)
        // Activate before presenting the first file; minimization does not remove this membership.
        settings.hasFileWindows = true
        // A file that fails to open reports its own alert and never gets a window.
        if !document.openDocument(file) {
            documents.removeAll { $0 === document }
            settings.hasFileWindows = !documents.isEmpty
        } else {
            focusedDocument = document
        }
    }

    func document(at url: URL, excluding excluded: PadDocument? = nil) -> PadDocument? {
        allDocuments.first { candidate in
            guard candidate !== excluded, let existing = candidate.url else { return false }
            if existing.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL {
                return true
            }
            // Hard links also identify the same file, while equal names in different folders do not.
            guard let lhs = try? FileManager.default.attributesOfItem(atPath: existing.path),
                  let rhs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let leftInode = lhs[.systemFileNumber] as? NSNumber,
                  let rightInode = rhs[.systemFileNumber] as? NSNumber,
                  let leftDevice = lhs[.systemNumber] as? NSNumber,
                  let rightDevice = rhs[.systemNumber] as? NSNumber else { return false }
            return leftInode == rightInode && leftDevice == rightDevice
        }
    }

    func didClose(_ document: PadDocument) {
        documents.removeAll { $0 === document }
        if focusedDocument === document { focusedDocument = documents.last ?? quickPad }
        settings.hasFileWindows = !documents.isEmpty
    }

    func reopen() {
        if let file = fileForSettings { file.showCurrent() }
        else { quickPad.showCurrent() }
    }

    func useCurrentQuickPadSize() {
        guard let size = quickPad.windowSize else { return }
        settings.quickPadWidth = size.width
        settings.quickPadHeight = size.height
    }

    func useCurrentFileSize() {
        guard let size = fileForSettings?.windowSize else { return }
        settings.fileWindowWidth = size.width
        settings.fileWindowHeight = size.height
    }

    func prepareToTerminate() async -> Bool {
        guard !isTransitioning else { return false }
        isTransitioning = true
        defer { isTransitioning = false }
        // Capture every editor before allowing a destructive decision in any window.
        for document in allDocuments {
            guard await document.captureForReset() else { return false }
        }
        for document in allDocuments {
            guard document.canTerminate() else { return false }
        }
        return true
    }

    func resetApp() async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        resetError = nil
        for document in allDocuments {
            guard await document.captureForReset() else {
                resetError = "Couldn’t reset PadPad. Try again."
                return
            }
        }
        let login = LoginItemSettings()
        if login.enabled {
            await login.setEnabled(false)
            if let error = login.error { resetError = error; return }
        }
        KeyboardShortcuts.reset(.pad)
        quickPad.resetQuickPadPreferences()
        settings.resetPreferences(from: NSApp.keyWindow)
        if let error = settings.activationPolicyError { resetError = error }
    }

    func screenConfigurationChanged() {
        for document in allDocuments { document.constrainWindowToScreens() }
    }
}
