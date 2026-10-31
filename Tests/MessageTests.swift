import AppKit
import Testing
@testable import Pad

@MainActor
@Suite struct MessageTests {
    @Test func smallProblemsWithAnObviousFixArePanelMessages() {
        for error: PadError in [.emptyName, .nameTooLong, .invalidName, .nameExists, .emptyShare] {
            for context: PadProblem.Context in [.rename, .save, .saveAs, .nameFormat] {
                #expect(expectedMessage(error, during: context) != nil, "\(error) during \(context)")
            }
        }
        let editorErrors: [PadMarkdownEditorError] = [
            .notReady, .composing, .documentChanged, .invalidResponse, .unavailable, .script("failure"),
            .snapshotRejected(code: "operation-pending", message: ""), .snapshotRejected(code: "other", message: "")
        ]
        for error in editorErrors {
            for context: PadProblem.Context in [.snapshot, .print, .save, .copy, .editor] {
                #expect(expectedMessage(error, during: context) != nil, "\(error) during \(context)")
            }
        }
        // Reading the editor, copying and editor failures never become alerts, whatever the underlying error.
        for context: PadProblem.Context in [.snapshot, .copy, .editor] {
            #expect(expectedMessage(CocoaError(.fileReadNoSuchFile), during: context) != nil)
        }
        #expect(expectedMessage(POSIXError(.EIO), during: .rename) != nil)
        #expect(expectedMessage(CocoaError(.fileWriteFileExists), during: .saveAs) == PadError.nameExists.message())
        #expect(PadError.nameExists.message() == PadMessage(text: "A file with this name already exists.",
                                                            hint: "Choose another name."))
    }

    @Test func problemsThatNeedADecisionAreAlertsWithTheirNextStep() {
        let cases: [(any Error, PadProblem.Context, PadAlert.Action?)] = [
            (PadError.changed, .save, .saveAs), (PadError.changed, .saveAs, .saveAs),
            (PadError.changed, .read, .saveAs), (PadError.changed, .rename, .saveAs),
            (PadError.missingFolder, .save, .openSettings),
            (PadError.renamePermission, .rename, .saveAs),
            (PadError.unsupported, .open, .chooseFile), (PadError.unsupported, .saveAs, .saveAs),
            (PadError.encoding, .open, nil), (PadError.encoding, .read, .saveAs),
            (CocoaError(.fileReadNoSuchFile), .open, nil), (CocoaError(.fileReadNoSuchFile), .read, .saveAs),
            (CocoaError(.fileReadNoSuchFile), .rename, .saveAs),
            (CocoaError(.fileReadNoPermission), .open, .chooseFile), (CocoaError(.fileReadNoPermission), .save, .saveAs),
            (CocoaError(.fileWriteNoPermission), .save, .saveAs), (CocoaError(.fileWriteNoPermission), .saveAs, .saveAs),
            (CocoaError(.fileWriteOutOfSpace), .save, nil),
            (CocoaError(.fileReadUnknown), .open, nil), (CocoaError(.fileReadUnknown), .read, .saveAs),
            (CocoaError(.fileWriteUnknown), .save, .saveAs), (CocoaError(.fileWriteUnknown), .nameFormat, .saveAs),
            (CocoaError(.fileWriteUnknown), .share, nil), (CocoaError(.fileWriteUnknown), .print, nil)
        ]
        for (error, context, action) in cases {
            let alert = expectedAlert(error, during: context)
            #expect(alert != nil, "\(error) during \(context)")
            #expect(alert?.action == action, "\(error) during \(context)")
            #expect(alert?.buttons == (action.map { [$0.title, "Cancel"] } ?? ["OK"]))
            // A short title, then one informative sentence.
            #expect(alert?.title.hasSuffix(".") == false)
            #expect(alert?.message.hasSuffix(".") == true)
            #expect(alert?.message.contains(". ") == false, "\(alert?.message ?? "")")
        }
    }

    @Test func copyIsPlainAndKeepsTheAgreedWording() {
        #expect(PadMarkdownEditorFeedback(code: "preservation", source: .edit).message
            == PadMessage(text: "That edit isn’t possible here. Nothing changed."))
        #expect(PadMarkdownEditorFeedback(code: "image-unavailable", source: .clipboard).message
            == PadMessage(text: "Copied. Some images are included as Markdown."))
        #expect(PadError.missingFolder.alert() == PadAlert(title: "The save folder isn’t available",
                                                           message: "Choose another folder in Settings.",
                                                           action: .openSettings))
        #expect(PadError.missingFolder.alert()?.buttons == ["Open Settings", "Cancel"])
        #expect(PadError.invalidName.message(during: .nameFormat)
            == PadMessage(text: "The file name format isn’t valid.", hint: "Change it in Settings."))

        let errors: [any Error] = [PadError.unsupported, PadError.encoding, PadError.changed, PadError.missingFolder,
                                   PadError.invalidName, PadError.emptyName, PadError.nameTooLong, PadError.nameExists,
                                   PadError.renamePermission, PadError.emptyShare, PadMarkdownEditorError.notReady,
                                   PadMarkdownEditorError.composing, PadMarkdownEditorError.unavailable,
                                   CocoaError(.fileReadNoSuchFile), CocoaError(.fileReadNoPermission),
                                   CocoaError(.fileWriteNoPermission), CocoaError(.fileWriteOutOfSpace), POSIXError(.EIO)]
        let contexts: [PadProblem.Context] = [.open, .read, .save, .saveAs, .rename, .share, .print, .copy, .editor,
                                              .snapshot, .nameFormat]
        var words: [String] = []
        for error in errors {
            for context in contexts {
                switch PadProblem(error, during: context) {
                case .message(let message): words += [message.text, message.hint].compactMap(\.self)
                case .alert(let alert): words += [alert.title, alert.message] + alert.buttons
                }
            }
        }
        for source in [PadMarkdownEditorFeedback.Source.edit, .clipboard, .print] {
            for code in ["preservation", "composition", "not-ready", "operation-pending", "read-only", "stale-document",
                         "image-unavailable", "image-unsupported", "file-unavailable", "diagram-unavailable", "unknown"] {
                let message = PadMarkdownEditorFeedback(code: code, source: source).message
                words += [message.text, message.hint].compactMap(\.self)
            }
        }
        for text in words {
            #expect(!text.contains("'") && !text.contains("!") && !text.lowercased().contains("please"), "\(text)")
            #expect(!text.contains("Your text is still open"), "\(text)")
        }
    }

    @Test func alertIsPresentedOnceAndBlocksTheDocumentUntilItCloses() throws {
        let fixture = try MessageFixture()
        defer { fixture.cleanUp() }
        var presented: [PadAlert] = []
        var close: (@MainActor (Bool) -> Void)?
        let document = fixture.document(presentAlert: { alert, window, completion in
            presented.append(alert)
            #expect(window == nil)
            close = completion
        })
        let url = try fixture.conflictingFile(in: document)
        document.save()
        #expect(presented == [PadError.changed.alert()])
        #expect(presented.first?.buttons == ["Save As…", "Cancel"])
        #expect(document.alert == presented.first)
        #expect(document.isBusy)
        document.save()
        document.refreshIfNeeded()
        #expect(presented.count == 1)
        close?(false)
        #expect(document.alert == nil)
        #expect(!document.isBusy)
        #expect(document.text == "local edit")
        #expect(try String(contentsOf: url, encoding: .utf8) == "external edit")
    }

    @Test(arguments: [false, true])
    func cancelingAConflictingSaveAcknowledgesOnlyTheObservedFile(_ saveAs: Bool) async throws {
        let fixture = try MessageFixture()
        defer { fixture.cleanUp() }
        var presented: [PadAlert] = []
        var close: (@MainActor (Bool) -> Void)?
        let file = fixture.root.appending(path: "conflict.txt")
        let document = fixture.document(presentAlert: { alert, _, completion in
            presented.append(alert)
            close = completion
        }, selectSaveFile: { _, _ in file })
        _ = try fixture.conflictingFile(in: document)
        if saveAs { await document.saveAs() } else { document.save() }
        #expect(presented == [PadError.changed.alert()])
        close?(false)
        document.refreshIfNeeded()
        #expect(presented.count == 1, "Returning focus after Cancel must not repeat the same conflict")
        #expect(document.alert == nil)
        #expect(document.text == "local edit")
        #expect(document.savedText == "original")
        #expect(try String(contentsOf: file, encoding: .utf8) == "external edit")

        document.save()
        #expect(presented.count == 2, "An explicit save must still explain why it cannot overwrite the file")
        // A different external write while the alert is open has not been acknowledged.
        try Data("newer external edit".utf8).write(to: file)
        close?(false)
        document.refreshIfNeeded()
        #expect(presented.count == 3)
        #expect(document.alert == PadError.changed.alert())
        close?(false)
        document.refreshIfNeeded()
        #expect(presented.count == 3)
        #expect(!document.isBusy)
        #expect(document.text == "local edit")
        #expect(document.savedText == "original")
        #expect(try String(contentsOf: file, encoding: .utf8) == "newer external edit")

        document.text = document.savedText
        let replacement = fixture.root.appending(path: "replacement.txt")
        try Data("replacement original".utf8).write(to: replacement)
        #expect(document.openDocument(replacement))
        document.text = "replacement local edit"
        try Data("newer external edit".utf8).write(to: replacement)
        document.refreshIfNeeded()
        #expect(presented.count == 4, "A different document must not inherit an acknowledged conflict")
        close?(false)
        #expect(document.text == "replacement local edit")
        #expect(try String(contentsOf: replacement, encoding: .utf8) == "newer external edit")
    }

    @Test(arguments: [false, true])
    func alertActionRunsTheExistingSaveAsCommand(_ confirms: Bool) async throws {
        let fixture = try MessageFixture()
        defer { fixture.cleanUp() }
        let alerts = AlertRecorder()
        alerts.confirms = confirms
        var requests: [String] = []
        let document = fixture.document(presentAlert: alerts.present, selectSaveFile: { _, name in
            requests.append(name)
            return nil
        })
        _ = try fixture.conflictingFile(in: document)
        document.save()
        #expect(alerts.alerts.count == 1)
        for _ in 0..<50 where requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(requests == (confirms ? ["conflict.txt"] : []))
        #expect(!document.isBusy)
        #expect(document.text == "local edit")
    }

    @Test func chooseFileRunsTheExistingOpenCommand() async throws {
        let fixture = try MessageFixture()
        defer { fixture.cleanUp() }
        let alerts = AlertRecorder()
        alerts.confirms = true
        var requests = 0
        let document = fixture.document(presentAlert: alerts.present, selectOpenFile: {
            requests += 1
            return nil
        })
        let rich = fixture.root.appending(path: "notes.rtfd")
        try Data("Rich".utf8).write(to: rich)
        document.open(rich)
        #expect(alerts.alerts == [PadError.unsupported.alert(during: .open)])
        for _ in 0..<50 where requests == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(requests == 1)
        #expect(!document.isBusy)
    }

    @Test func panelMessagesNeverBlockEditingAndClearWhenDismissedOrFixed() throws {
        let fixture = try MessageFixture()
        defer { fixture.cleanUp() }
        let alerts = AlertRecorder()
        let document = fixture.document(presentAlert: alerts.present)
        document.text = "draft"
        #expect(!document.rename(to: "a/b"))
        #expect(document.error == PadError.invalidName.message())
        #expect(!document.isBusy)
        #expect(document.alert == nil)
        #expect(document.canShare)
        document.text = "draft, still typing"
        #expect(document.isDirty)
        #expect(document.error != nil)
        document.dismissMessage()
        #expect(document.error == nil)
        #expect(!document.rename(to: ""))
        #expect(document.rename(to: "Fixed"))
        #expect(document.error == nil)
        #expect(document.notice == "Renamed")
        document.save()
        #expect(!document.isDirty)
        #expect(document.url?.lastPathComponent == "Fixed.txt")
        #expect(alerts.alerts.isEmpty)
    }

    @Test func anAlertReplacesAPanelMessage() throws {
        let fixture = try MessageFixture()
        defer { fixture.cleanUp() }
        let alerts = AlertRecorder()
        let document = fixture.document(presentAlert: alerts.present)
        _ = try fixture.conflictingFile(in: document)
        #expect(!document.rename(to: "a/b"))
        #expect(document.error != nil)
        document.save()
        #expect(alerts.alerts.count == 1)
        #expect(document.error == nil)
        #expect(document.notice == nil)
    }

    @Test func refusedPlainTextImageShowsOneSmallProblemUntilTheTextChanges() throws {
        let fixture = try MessageFixture()
        defer { fixture.cleanUp() }
        let document = PadDocument(defaults: fixture.defaults, defaultFolder: fixture.root, presentsWindow: false)
        document.text = "Keep this"
        document.refuseImage()
        #expect(document.editorFeedback == PadMarkdownEditorFeedback(code: "image-unsupported", source: .edit))
        #expect(document.editorFeedback?.message.text == "Images aren’t supported.")
        #expect(document.text == "Keep this")
        #expect(document.alert == nil)
        document.dismissMessage()
        #expect(document.editorFeedback == nil)
        document.refuseImage()
        document.text = "Keep this, edited"
        #expect(document.editorFeedback == nil)
    }

    @Test func headlessDocumentsAnswerAlertsWithoutShowingThem() throws {
        let fixture = try MessageFixture()
        defer { fixture.cleanUp() }
        let document = PadDocument(defaults: fixture.defaults, defaultFolder: fixture.root, presentsWindow: false)
        let rich = fixture.root.appending(path: "notes.rtfd")
        try Data("Rich".utf8).write(to: rich)
        #expect(!document.openDocument(rich))
        #expect(document.alert == nil)
        #expect(!document.isBusy)
        #expect(document.error == nil)
    }
}

@MainActor
private struct MessageFixture {
    let root: URL
    let defaults: UserDefaults
    private let suite = "pad-message-tests-\(UUID().uuidString)"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("txt", forKey: "pad.format")
        root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func document(presentAlert: @escaping PadAlert.Presenter,
                  selectOpenFile: (@MainActor () async -> URL?)? = nil,
                  selectSaveFile: (@MainActor (URL, String) async -> URL?)? = nil) -> PadDocument {
        let document = PadDocument(defaults: defaults, defaultFolder: root, presentsWindow: false, copyPath: { _ in },
                                   selectOpenFile: selectOpenFile, selectSaveFile: selectSaveFile,
                                   resolveUnsavedChanges: { .cancel }, presentAlert: presentAlert)
        document.saveAutomatically = false
        return document
    }

    /// Opens a file in `document`, edits it, then changes it on disk so the next save conflicts.
    func conflictingFile(in document: PadDocument) throws -> URL {
        let url = root.appending(path: "conflict.txt")
        try Data("original".utf8).write(to: url)
        #expect(document.openDocument(url))
        document.text = "local edit"
        try Data("external edit".utf8).write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}
