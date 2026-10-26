import Foundation
import Testing
@testable import Pad

@MainActor
@Suite struct FormatSwitchTests {
    @Test func scratchRoundTripPreservesSourceBytesIdentityAndDefault() async throws {
        let fixture = try FormatSwitchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        let source = "# A heading\r\n\r\n**Keep**  two spaces\r\n<custom>literal</custom>\r\n"
        document.text = "older callback"
        document.editorSnapshot = { source }
        let id = document.documentID
        #expect(document.rename(to: "My thought"))
        await document.toggleFormat()
        #expect(document.currentFormat == .txt)
        #expect(document.displayName == "My thought.txt")
        #expect(Data(document.text.utf8) == Data(source.utf8))
        #expect(document.isDirty)
        document.editorSnapshot = { Issue.record("TXT must not read a stale Markdown snapshot"); return "stale" }
        await document.toggleFormat()
        #expect(document.currentFormat == .md)
        #expect(document.displayName == "My thought.md")
        #expect(Data(document.text.utf8) == Data(source.utf8))
        #expect(document.documentID == id)
        #expect(document.url == nil)
        #expect(document.format == .md)
        #expect(fixture.defaults.string(forKey: "pad.format") == "md")
        #expect(try fixture.savedFiles().isEmpty)
    }

    @Test func snapshotFailureDoesNotChangeScratchFormatOrContent() async throws {
        let fixture = try FormatSwitchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Keep this"
        let id = document.documentID
        document.editorSnapshot = { throw CocoaError(.fileReadUnknown) }
        await document.toggleFormat()
        #expect(document.currentFormat == .md)
        #expect(document.text == "Keep this")
        #expect(document.documentID == id)
        #expect(document.error == expectedMessage(CocoaError(.fileReadUnknown), during: .snapshot))
        #expect(!document.isBusy)
    }

    @Test func savedFileDoesNotExposeDraftFormatSwitching() async throws {
        let fixture = try FormatSwitchFixture(selectSaveFile: { _, _ in
            Issue.record("A locked footer must not present Save As")
            return nil
        })
        defer { fixture.cleanUp() }
        let original = fixture.root.appending(path: "locked.md")
        try Data("# Keep the file type".utf8).write(to: original)
        fixture.document.open(original)
        let identity = fixture.document.documentID
        await fixture.document.toggleFormat()
        #expect(fixture.document.currentFormat == .md)
        #expect(fixture.document.url == original)
        #expect(fixture.document.documentID == identity)
        #expect(fixture.document.text == "# Keep the file type")
    }

    @Test func cancelledSaveAsRetainsLatestEditAndFileFormat() async throws {
        var suggestedName: String?
        let fixture = try FormatSwitchFixture(selectSaveFile: { _, name in suggestedName = name; return nil })
        defer { fixture.cleanUp() }
        let original = fixture.root.appending(path: "thought.md")
        try Data("# Original\n".utf8).write(to: original)
        let document = fixture.document
        document.open(original)
        let id = document.documentID
        document.editorSnapshot = { "# Last keystroke\n" }
        await document.saveAs(targetFormat: .txt)
        #expect(suggestedName == "thought.txt")
        #expect(document.currentFormat == .md)
        #expect(document.url == original)
        #expect(document.documentID == id)
        #expect(document.text == "# Last keystroke\n")
        #expect(document.isDirty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "# Original\n")
        #expect(!document.isBusy)
    }

    @Test func existingFileSwitchSavesSnapshotAsOtherExtensionAndKeepsOriginal() async throws {
        let fixture = try FormatSwitchFixture(selectSaveFile: { directory, name in directory.appending(path: name) })
        defer { fixture.cleanUp() }
        let original = fixture.root.appending(path: "thought.md")
        let source = "## Exact\r\n\n- [ ] Keep this  \n"
        try Data("original".utf8).write(to: original)
        let document = fixture.document
        document.open(original)
        let id = document.documentID
        document.editorSnapshot = { source }
        await document.saveAs(targetFormat: .txt)
        #expect(document.currentFormat == .txt)
        #expect(document.url == fixture.root.appending(path: "thought.txt"))
        #expect(document.documentID == id)
        #expect(!document.isDirty)
        #expect(try Data(contentsOf: #require(document.url)) == Data(source.utf8))
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(document.format == .md)
    }

    @Test func formatSaveAsDoesNotOverwriteExistingSibling() async throws {
        let fixture = try FormatSwitchFixture(selectSaveFile: { directory, name in directory.appending(path: name) })
        defer { fixture.cleanUp() }
        let original = fixture.root.appending(path: "thought.md")
        let sibling = fixture.root.appending(path: "thought.txt")
        try Data("markdown".utf8).write(to: original)
        try Data("existing sibling".utf8).write(to: sibling)
        let document = fixture.document
        document.open(original)
        document.editorSnapshot = { "latest edit" }
        await document.saveAs(targetFormat: .txt)
        #expect(document.currentFormat == .md)
        #expect(document.url == original)
        #expect(document.text == "latest edit")
        #expect(document.isDirty)
        #expect(document.error == PadError.nameExists.message(during: .saveAs))
        #expect(try String(contentsOf: sibling, encoding: .utf8) == "existing sibling")
    }

    @Test func snapshotFailureDoesNotPresentFormatSaveAs() async throws {
        let fixture = try FormatSwitchFixture(selectSaveFile: { _, _ in
            Issue.record("A failed snapshot must not present Save As")
            return nil
        })
        defer { fixture.cleanUp() }
        let original = fixture.root.appending(path: "thought.md")
        try Data("original".utf8).write(to: original)
        fixture.document.open(original)
        fixture.document.editorSnapshot = { throw CocoaError(.fileReadUnknown) }
        await fixture.document.saveAs(targetFormat: .txt)
        #expect(fixture.document.url == original)
        #expect(fixture.document.currentFormat == .md)
        #expect(fixture.document.error != nil)
    }
}

@MainActor
private struct FormatSwitchFixture {
    let root: URL
    let defaults: UserDefaults
    let document: PadDocument
    private let suite: String

    init(selectSaveFile: (@MainActor (URL, String) async -> URL?)? = nil) throws {
        suite = "pad-format-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("md", forKey: "pad.format")
        root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        document = PadDocument(defaults: defaults, defaultFolder: root, presentsWindow: false,
                               copyPath: { _ in }, selectSaveFile: selectSaveFile, resolveUnsavedChanges: { .cancel })
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
