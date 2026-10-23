import Foundation
import Testing
@testable import Pad

@MainActor
@Suite struct ScratchLifecycleTests {
    private let start = Date(timeIntervalSince1970: 1_790_113_017)

    @Test(arguments: [899.0, 900.0, 901.0])
    func unsavedScratchExpiresAtTheInactivityBoundary(_ away: TimeInterval) throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "temporary clipboard text"
        let identity = document.documentID
        document.close(now: start)
        #expect(document.text == "temporary clipboard text")
        document.showCurrent(now: start.addingTimeInterval(away))
        if away < 900 {
            #expect(document.text == "temporary clipboard text")
            #expect(document.documentID == identity)
        } else {
            #expect(document.text.isEmpty)
            #expect(document.documentID != identity)
        }
        #expect(try fixture.savedFiles().isEmpty)
    }

    @Test func reopeningRestartsTheIntervalAtTheNextDismissal() throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "keep while working"
        document.close(now: start)
        document.showCurrent(now: start.addingTimeInterval(14 * 60))
        document.close(now: start.addingTimeInterval(20 * 60))
        document.showCurrent(now: start.addingTimeInterval(34 * 60))
        #expect(document.text == "keep while working")
        document.close(now: start.addingTimeInterval(35 * 60))
        document.showCurrent(now: start.addingTimeInterval(50 * 60))
        #expect(document.text.isEmpty)
    }

    @Test func timeSpentEditingDoesNotCountTowardsExpiry() throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.newFile(now: start)
        document.text = "long editing session"
        document.showCurrent(now: start.addingTimeInterval(2 * 60 * 60))
        #expect(document.text == "long editing session")
        document.close(now: start.addingTimeInterval(2 * 60 * 60))
        document.showCurrent(now: start.addingTimeInterval(2 * 60 * 60 + 899))
        #expect(document.text == "long editing session")
    }

    @Test func reopenedScratchDoesNotExpireDuringTheNextEditingSession() throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "still editing"
        document.close(now: start)
        document.showCurrent(now: start.addingTimeInterval(60))
        document.showCurrent(now: start.addingTimeInterval(3_600))
        #expect(document.text == "still editing")
    }

    @Test(arguments: [false, true])
    func savedFilesStayCurrentPastDraftExpiry(_ automaticSaving: Bool) throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.saveAutomatically = automaticSaving
        document.text = "permanent file"
        if !automaticSaving { document.save() }
        document.close(now: start)
        let saved = try #require(document.url)
        document.showCurrent(now: start.addingTimeInterval(900))
        #expect(document.text == "permanent file")
        #expect(document.url == saved)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "permanent file")
    }

    @Test func openedFilesIgnoreScratchExpiry() throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appending(path: "opened.md")
        try Data("# Keep this file".utf8).write(to: file)
        let document = fixture.document
        document.open(file)
        document.close(now: start)
        document.showCurrent(now: start.addingTimeInterval(86_400))
        #expect(document.text == "# Keep this file")
        #expect(document.url == file)
    }

    @Test(arguments: [false, true])
    func explicitNewStartsFreshAndHonorsAutomaticSaving(_ automaticSaving: Bool) throws {
        var confirmations = 0
        let fixture = try ScratchFixture(resolveUnsavedChanges: {
            confirmations += 1
            return .discard
        })
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.saveAutomatically = automaticSaving
        document.text = "previous scratch"
        document.commandNew(now: start)
        #expect(confirmations == (automaticSaving ? 0 : 1))
        #expect(document.text.isEmpty)
        #expect(document.url == nil)
        let saved = try fixture.savedFiles()
        #expect(saved.count == (automaticSaving ? 1 : 0))
        if let file = saved.first {
            #expect(try String(contentsOf: file, encoding: .utf8) == "previous scratch")
        }
    }

    @Test func untilClosedStartsEmptyOnImmediateReopen() throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        fixture.document.reusePeriod = .alwaysNew
        fixture.document.text = "temporary"
        fixture.document.close(now: start)
        fixture.document.showCurrent(now: start)
        #expect(fixture.document.text.isEmpty)
    }

    @Test func defaultFormatDoesNotChangeExistingScratchOrShareFormat() throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        #expect(document.format == .md)
        document.text = "**Markdown**"
        document.format = .txt
        #expect(document.currentFormat == .md)
        let shared = try document.shareableURL(in: fixture.root)
        #expect(shared.pathExtension == "md")
        document.save()
        #expect(document.url?.pathExtension == "md")
        document.newFile()
        #expect(document.currentFormat == .txt)
    }

    @Test func saveCapturesTheLastEditorKeystroke() async throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "previous callback"
        document.editorSnapshot = { "**Final keystroke**" }
        document.save()
        #expect(document.isBusy)
        await settle(document)
        let saved = try #require(document.url)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "**Final keystroke**")
        #expect(!document.isDirty)
    }

    @Test func closingCapturesTheLastEditorKeystrokeBeforeRetainingScratch() async throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "previous callback"
        document.editorSnapshot = { "final text" }
        document.close(now: start)
        await settle(document)
        #expect(document.text == "final text")
        #expect(document.url == nil)
        document.editorSnapshot = nil
        document.showCurrent(now: start.addingTimeInterval(899))
        #expect(document.text == "final text")
    }

    @Test(arguments: ["save", "close", "new"])
    func snapshotFailureRetainsTheDocument(_ action: String) async throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "retained draft"
        let identity = document.documentID
        document.editorSnapshot = { throw CocoaError(.fileReadUnknown) }
        switch action {
        case "save": document.save()
        case "close": document.close(now: start)
        default: document.newFile()
        }
        await settle(document)
        #expect(document.documentID == identity)
        #expect(document.text == "retained draft")
        #expect(document.url == nil)
        #expect(document.error == "Couldn’t read your text. Try again.")
        #expect(try fixture.savedFiles().isEmpty)
    }

    @Test func deletedCleanQuickPadStartsFreshAfterSnapshot() async throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Saved text\r\nwith Unicode café"
        document.save()
        let file = try #require(document.url)
        let identity = document.documentID
        document.close(now: start)
        try FileManager.default.removeItem(at: file)
        document.editorSnapshot = { document.savedText }
        document.showCurrent(now: start.addingTimeInterval(1))
        await settle(document)
        #expect(document.url == nil)
        #expect(document.text.isEmpty)
        #expect(document.documentID != identity)
        #expect(document.error == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: [false, true])
    func deletedQuickPadRetainsDirtyOrUncertainSnapshot(_ snapshotFails: Bool) async throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "saved"
        document.save()
        let file = try #require(document.url)
        let identity = document.documentID
        document.close(now: start)
        try FileManager.default.removeItem(at: file)
        document.editorSnapshot = {
            if snapshotFails { throw CocoaError(.fileReadUnknown) }
            return "last unsaved keystroke"
        }
        document.showCurrent(now: start.addingTimeInterval(1))
        await settle(document)
        #expect(document.documentID == identity)
        #expect(document.url == file)
        #expect(document.text == (snapshotFails ? "saved" : "last unsaved keystroke"))
        #expect(document.error != nil)
        #expect(document.folderError == nil)
        document.save()
        await settle(document)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func deletedFileWindowRetainsRecoveryText() throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appending(path: "external.md")
        try Data("Keep this recovery copy".utf8).write(to: file)
        let defaults = try #require(UserDefaults(suiteName: "pad-recovery-\(UUID().uuidString)"))
        let document = PadDocument(defaults: defaults, presentsWindow: false, role: .file)
        #expect(document.openDocument(file))
        try FileManager.default.removeItem(at: file)
        document.refreshIfNeeded()
        #expect(document.url == file)
        #expect(document.text == "Keep this recovery copy")
        #expect(document.error != nil)
        document.save()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unreadableExistingQuickPadRetainsText() throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "saved"
        document.save()
        let file = try #require(document.url)
        try Data([0xff, 0xfe]).write(to: file)
        document.refreshIfNeeded()
        #expect(document.text == "saved")
        #expect(document.url == file)
        #expect(document.error != nil)
        #expect(document.folderError == nil)
    }

    @Test func emptyShareDoesNotCreateAFileAndUntitledUsesVisibleName() throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        #expect(!document.canShare)
        #expect(throws: PadError.self) { try document.shareableURL(in: fixture.root) }
        #expect(try fixture.savedFiles().isEmpty)
        document.text = "Hello\r\nworld 🌍"
        #expect(document.canShare)
        let shared = try document.shareableURL(in: fixture.root)
        #expect(shared.lastPathComponent == "Untitled.md")
        #expect(try String(contentsOf: shared, encoding: .utf8) == document.text)
        document.save()
        #expect(document.url?.lastPathComponent != "Untitled.md")
    }

    @Test func recoveryGuidanceHasItsOwnCompactLine() {
        let warning = PadWarningContent("This file is no longer available. Your text is still open. Choose “Save As” to keep a copy.")
        #expect(warning.message == "This file is no longer available.")
        #expect(warning.guidance == "Choose “Save As” to keep a copy.")
        let edit = PadWarningContent("Couldn’t apply that edit. Your text is unchanged.")
        #expect(edit.guidance == nil)
        #expect(edit.message == "Couldn’t apply that edit. Your text is unchanged.")
    }

    @Test func terminationWaitsForSnapshotAndRefusesSnapshotFailure() async throws {
        let fixture = try ScratchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.saveAutomatically = true
        document.text = "previous callback"
        document.editorSnapshot = { throw CocoaError(.fileReadUnknown) }
        #expect(await document.prepareToTerminate() == false)
        #expect(document.text == "previous callback")
        document.editorSnapshot = { "final before quit" }
        #expect(await document.prepareToTerminate())
        let saved = try #require(document.url)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "final before quit")
    }

    private func settle(_ document: PadDocument) async {
        for _ in 0..<100 where document.isBusy { await Task.yield() }
        #expect(!document.isBusy, "Editor snapshot operation did not finish")
    }
}

@MainActor
private struct ScratchFixture {
    let root: URL
    let document: PadDocument
    private let suite: String
    private let defaults: UserDefaults

    init(resolveUnsavedChanges: @escaping @MainActor () -> PadUnsavedChangesDecision = { .cancel }) throws {
        suite = "pad-scratch-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        document = PadDocument(defaults: defaults, defaultFolder: root, presentsWindow: false,
                               copyPath: { _ in }, resolveUnsavedChanges: resolveUnsavedChanges)
        document.saveAutomatically = false
    }

    func savedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}
