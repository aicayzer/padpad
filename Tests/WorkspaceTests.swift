import Foundation
import Testing
@testable import Pad

@MainActor
@Suite struct WorkspaceTests {
    @Test func openingFilesKeepsTheQuickPadAndEachDocumentIndependent() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let pad = fixture.workspace.quickPad
        pad.text = "Keep this temporary thought"
        #expect(pad.rename(to: "My thought"))
        let identity = pad.documentID
        let first = try fixture.file("first.md", text: "# First")
        let second = try fixture.file("second.txt", text: "Second")
        fixture.workspace.open(first)
        fixture.workspace.open(second)
        let documents = fixture.workspace.documents
        #expect(documents.count == 2)
        #expect(pad.documentID == identity)
        #expect(pad.text == "Keep this temporary thought")
        #expect(pad.url == nil)
        #expect(pad.displayName == "My thought.md")
        #expect(documents[0].text == "# First")
        #expect(documents[1].text == "Second")
        #expect(documents[0].currentFormat == .md)
        #expect(documents[1].currentFormat == .txt)
        #expect(fixture.settings.hasFileWindows)
        #expect(fixture.workspace.activeDocument === documents[1])
        fixture.workspace.didFocus(pad)
        #expect(fixture.workspace.activeDocument === pad)
        documents[0].text = "Independent edits"
        #expect(documents[1].text == "Second")
        #expect(pad.text == "Keep this temporary thought")
    }

    @Test func repeatedOpenAndFilesystemAliasesReuseOneDocument() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.file("original.md", text: "# File")
        let symlink = fixture.root.appending(path: "symlink.md")
        let hardLink = fixture.root.appending(path: "hardlink.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        try FileManager.default.linkItem(at: original, to: hardLink)
        fixture.workspace.open(original)
        let document = try #require(fixture.workspace.documents.first)
        document.text = "Keep unsaved edits"
        fixture.workspace.open(original)
        fixture.workspace.open(symlink)
        fixture.workspace.open(hardLink)
        #expect(fixture.workspace.documents.count == 1)
        #expect(fixture.workspace.document(at: symlink) === document)
        #expect(fixture.workspace.document(at: hardLink) === document)
        #expect(document.text == "Keep unsaved edits")
        #expect(try String(contentsOf: original, encoding: .utf8) == "# File")
    }

    @Test func equalNamesInDifferentFoldersRemainDistinct() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.file("one/note.md", text: "One")
        let second = try fixture.file("two/note.md", text: "Two")
        fixture.workspace.open(first)
        fixture.workspace.open(second)
        #expect(fixture.workspace.documents.count == 2)
        #expect(fixture.workspace.document(at: first) !== fixture.workspace.document(at: second))
        #expect(fixture.workspace.document(at: first)?.text == "One")
        #expect(fixture.workspace.document(at: second)?.text == "Two")
    }

    @Test func fileDocumentsKeepTheirFormatAndDoNotInheritQuickPadAutomaticSaving() async throws {
        let fixture = try WorkspaceFixture(automaticSaving: true)
        defer { fixture.cleanUp() }
        let original = try fixture.file("note.txt", text: "Plain text")
        fixture.workspace.open(original)
        let document = try #require(fixture.workspace.documents.first)
        #expect(fixture.workspace.quickPad.saveAutomatically)
        #expect(!document.saveAutomatically)
        await document.changeFormat(to: .md)
        #expect(document.currentFormat == .txt)
        #expect(document.url == original)
        #expect(document.text == "Plain text")
        #expect(fixture.defaults.bool(forKey: "pad.saveAutomatically"))
    }

    @Test func closingDocumentsRetainsDockMembershipUntilTheLastFileCloses() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.workspace.open(try fixture.file("first.txt", text: "First"))
        fixture.workspace.open(try fixture.file("second.txt", text: "Second"))
        let first = fixture.workspace.documents[0]
        let second = fixture.workspace.documents[1]
        fixture.workspace.didClose(second)
        #expect(fixture.workspace.documents.count == 1)
        #expect(fixture.settings.hasFileWindows)
        #expect(fixture.workspace.activeDocument === first)
        fixture.workspace.didClose(first)
        #expect(fixture.workspace.documents.isEmpty)
        #expect(!fixture.settings.hasFileWindows)
        #expect(fixture.workspace.activeDocument === fixture.workspace.quickPad)
    }

    @Test func failedOpenAlertsWithoutAWindowOrQuickPadMessage() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let unsupported = try fixture.file("notes.rtfd", text: "Rich text")
        fixture.workspace.open(unsupported)
        #expect(fixture.workspace.documents.isEmpty)
        #expect(fixture.alerts.alerts == [PadError.unsupported.alert(during: .open)])
        #expect(fixture.alerts.windows == [nil])
        #expect(fixture.workspace.quickPad.error == nil)
        #expect(!fixture.workspace.quickPad.isBusy)
    }

    @Test func saveAsCannotOverwriteAnotherOpenDocument() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.file("first.txt", text: "First")
        let destination = try fixture.file("second.txt", text: "Second")
        fixture.workspace.open(destination)
        let other = try #require(fixture.workspace.documents.first)
        other.text = "Unsaved second edits"
        let source = PadDocument(defaults: fixture.defaults, defaultFolder: fixture.root,
                                 presentsWindow: false, role: .file,
                                 selectSaveFile: { _, _ in destination })
        source.workspace = fixture.workspace
        #expect(source.openDocument(original))
        source.text = "First edits"
        await source.saveAs()
        #expect(source.url == original)
        #expect(source.text == "First edits")
        #expect(source.isDirty)
        #expect(source.error == PadError.nameExists.message(during: .saveAs))
        #expect(other.text == "Unsaved second edits")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Second")
        #expect(try String(contentsOf: original, encoding: .utf8) == "First")
    }

    @Test func resettingQuickPadPreferencesPreservesWritingAndOpenFiles() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let pad = fixture.workspace.quickPad
        pad.text = "Retained draft"
        #expect(pad.rename(to: "Keep this name"))
        let identity = pad.documentID
        let original = try fixture.file("opened.txt", text: "Saved content")
        fixture.workspace.open(original)
        let document = try #require(fixture.workspace.documents.first)
        document.text = "Retained file edits"
        pad.resetQuickPadPreferences()
        #expect(pad.documentID == identity)
        #expect(pad.text == "Retained draft")
        #expect(pad.displayName == "Keep this name.md")
        #expect(document.url == original)
        #expect(document.text == "Retained file edits")
        #expect(document.isDirty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "Saved content")
        #expect(fixture.workspace.documents.count == 1)
    }
}

@MainActor
private struct WorkspaceFixture {
    let root: URL
    let defaults: UserDefaults
    let settings: AppSettings
    let workspace: PadWorkspace
    let alerts = AlertRecorder()
    private let suite: String

    init(automaticSaving: Bool = false) throws {
        suite = "pad-workspace-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set("md", forKey: "pad.format")
        defaults.set(automaticSaving, forKey: "pad.saveAutomatically")
        root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        settings = AppSettings(defaults: defaults)
        workspace = PadWorkspace(settings: settings, defaults: defaults, presentsWindows: false,
                                 defaultFolder: root, presentAlert: alerts.present)
    }

    func file(_ path: String, text: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}
