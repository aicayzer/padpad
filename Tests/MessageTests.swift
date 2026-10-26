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
        let rich = fixture.root.appending(path: "notes.rtf")
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

    @Test func headlessDocumentsAnswerAlertsWithoutShowingThem() throws {
        let fixture = try MessageFixture()
        defer { fixture.cleanUp() }
        let document = PadDocument(defaults: fixture.defaults, defaultFolder: fixture.root, presentsWindow: false)
        let rich = fixture.root.appending(path: "notes.rtf")
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
