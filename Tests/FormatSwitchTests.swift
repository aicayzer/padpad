import Foundation
import InkKitRTF
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
        await document.changeFormat(to: .txt)
        #expect(document.currentFormat == .txt)
        #expect(document.displayName == "My thought.txt")
        #expect(Data(document.text.utf8) == Data(source.utf8))
        #expect(document.isDirty)
        document.editorSnapshot = { Issue.record("TXT must not read a stale Markdown snapshot"); return "stale" }
        await document.changeFormat(to: .md)
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
        await document.changeFormat(to: .txt)
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
        await fixture.document.changeFormat(to: .txt)
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

    // MARK: RTF

    private static let richJSON = try! PadRichText.text(for: RichTextDocument(blocks: [
        .paragraph(.init([.text("Title", marks: [.bold])])),
        .paragraph(.init([.text("Body", marks: [.underline])], align: .center)),
    ]))

    @Test(arguments: [false, true])
    func markdownToRTFConfirmsWhatIsLostAndCancelKeepsTheSource(confirms: Bool) async throws {
        let alerts = AlertRecorder()
        alerts.confirms = confirms
        let fixture = try FormatSwitchFixture(alerts: alerts)
        defer { fixture.cleanUp() }
        let document = fixture.document
        let source = "# Title\n\nBody\n"
        document.editorSnapshot = { source }
        var requested: [PadFormat] = []
        document.editorConversion = { target in
            requested.append(target)
            return PadConversion(text: Self.richJSON, changes: PadFormatLoss.changes(for: ["heading", "heading", "quote"]))
        }
        let id = document.documentID
        await document.changeFormat(to: .rtf)
        #expect(requested == [.rtf])
        #expect(alerts.alerts == [PadAlert(title: "Convert this draft to RTF?",
                                           message: "Headings become bold text.\nQuotes become ordinary paragraphs.",
                                           action: .convert)])
        #expect(alerts.last?.buttons == ["Convert", "Cancel"])
        #expect(document.currentFormat == (confirms ? .rtf : .md))
        #expect(document.text == (confirms ? Self.richJSON : source))
        #expect(document.documentID == id)
        #expect(!document.isBusy)
        #expect(document.alert == nil)
        #expect(try fixture.savedFiles().isEmpty)
    }

    @Test func rtfToMarkdownWithoutLossSwitchesWithoutAsking() async throws {
        let alerts = AlertRecorder()
        let fixture = try FormatSwitchFixture(format: .rtf, alerts: alerts)
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = Self.richJSON
        document.editorConversion = { target in
            #expect(target == .md)
            return PadConversion(text: "**Title**\n\n<u>Body</u>\n", changes: [])
        }
        await document.changeFormat(to: .md)
        #expect(alerts.alerts.isEmpty)
        #expect(document.currentFormat == .md)
        #expect(document.text == "**Title**\n\n<u>Body</u>\n")
    }

    @Test func rtfToMarkdownReportsAlignmentLoss() async throws {
        let alerts = AlertRecorder()
        let fixture = try FormatSwitchFixture(format: .rtf, alerts: alerts)
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = Self.richJSON
        document.editorConversion = { _ in PadConversion(text: "Body\n", changes: PadFormatLoss.changes(for: ["alignment"])) }
        await document.changeFormat(to: .md)
        #expect(alerts.last == PadAlert(title: "Convert this draft to Markdown?",
                                        message: "Centered, right-aligned and justified text becomes left-aligned.",
                                        action: .convert))
        #expect(document.currentFormat == .rtf)
        #expect(document.text == Self.richJSON)
    }

    @Test func plainTextToRTFMakesParagraphsWithoutAsking() async throws {
        let alerts = AlertRecorder()
        let fixture = try FormatSwitchFixture(format: .txt, alerts: alerts)
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.editorConversion = { _ in Issue.record("TXT to RTF must not use the editor"); throw CocoaError(.featureUnsupported) }
        document.text = "First line\r\nSecond **literal**\n"
        await document.changeFormat(to: .rtf)
        #expect(alerts.alerts.isEmpty)
        #expect(document.currentFormat == .rtf)
        #expect(try PadRichText.document(from: document.text) == RichTextDocument(blocks: [
            .paragraph(.init([.text("First line")])),
            .paragraph(.init([.text("Second **literal**")])),
        ]))
    }

    @Test(arguments: [false, true])
    func plainTextToRTFConfirmsCharactersRTFCantStore(confirms: Bool) async throws {
        let alerts = AlertRecorder()
        alerts.confirms = confirms
        let fixture = try FormatSwitchFixture(format: .txt, alerts: alerts)
        defer { fixture.cleanUp() }
        let document = fixture.document
        let source = "Null\u{0}here\nObject\u{FFFC}there"
        document.text = source
        await document.changeFormat(to: .rtf)
        #expect(alerts.alerts == [PadAlert(title: "Convert this draft to RTF?",
                                           message: PadFormatLoss.change(for: "invalid-character"), action: .convert)])
        #expect(document.currentFormat == (confirms ? .rtf : .txt))
        if confirms {
            #expect(try PadRichText.document(from: document.text).plainText == "Null\u{FFFD}here\nObject\u{FFFD}there")
        } else {
            #expect(document.text == source)
        }
    }

    @Test func resetKeepsAConvertedDraftAndSavesItAsRTF() async throws {
        let fixture = try FormatSwitchFixture(format: .txt, choosesSaveFolder: true)
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Draft line"
        await document.changeFormat(to: .rtf)
        let converted = document.text
        #expect(document.currentFormat == .rtf)
        document.resetQuickPadPreferences()
        // Reset changes the default for future drafts only.
        #expect(document.format == .md)
        #expect(fixture.defaults.string(forKey: "pad.format") == "md")
        #expect(document.currentFormat == .rtf)
        #expect(document.text == converted)
        #expect(document.displayName == "Untitled")
        // Reset forgets the save folder, so choose it again, then save.
        fixture.selectedFolder = fixture.root
        document.save()
        let saved = try #require(document.url)
        #expect(saved.pathExtension == "rtf")
        #expect(try RTFConverter.document(contentsOf: saved).plainText == "Draft line")
        #expect(!document.isDirty)
        // The next draft uses the reset default.
        document.newFile()
        #expect(document.currentFormat == .md)
        #expect(document.text.isEmpty)
    }

    @Test(arguments: [false, true])
    func rtfToPlainTextAlwaysConfirms(confirms: Bool) async throws {
        let alerts = AlertRecorder()
        alerts.confirms = confirms
        let fixture = try FormatSwitchFixture(format: .rtf, alerts: alerts)
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = Self.richJSON
        await document.changeFormat(to: .txt)
        #expect(alerts.alerts == [PadAlert(title: "Convert this draft to plain text?",
                                           message: PadFormatLoss.plainText.joined(separator: "\n"), action: .convert)])
        #expect(document.currentFormat == (confirms ? .txt : .rtf))
        #expect(document.text == (confirms ? "Title\nBody" : Self.richJSON))
    }

    @Test func failedConversionKeepsTheDraft() async throws {
        let alerts = AlertRecorder()
        alerts.confirms = true
        let fixture = try FormatSwitchFixture(alerts: alerts)
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Keep this"
        document.editorConversion = { _ in throw PadMarkdownEditorError.snapshotRejected(code: "preservation", message: "") }
        await document.changeFormat(to: .rtf)
        #expect(document.currentFormat == .md)
        #expect(document.text == "Keep this")
        #expect(document.error != nil)
        #expect(alerts.alerts.isEmpty)
        #expect(!document.isBusy)
    }

    @Test func saveAsConvertsACopyAndKeepsTheOriginalRTF() async throws {
        let alerts = AlertRecorder()
        alerts.confirms = true
        let fixture = try FormatSwitchFixture(selectSaveFile: { directory, name in directory.appending(path: name) }, alerts: alerts)
        defer { fixture.cleanUp() }
        let original = fixture.root.appending(path: "letter.rtf")
        let originalBytes = try RTFConverter.rtfData(from: PadRichText.document(from: Self.richJSON))
        try originalBytes.write(to: original)
        let document = fixture.document
        document.open(original)
        #expect(document.currentFormat == .rtf)
        document.editorConversion = { _ in PadConversion(text: "**Title**\n", changes: PadFormatLoss.changes(for: ["alignment"])) }
        await document.saveAs(targetFormat: .md)
        #expect(alerts.last?.title == "Save a copy as Markdown?")
        #expect(alerts.last?.message.hasSuffix("The original file doesn’t change.") == true)
        #expect(document.url == fixture.root.appending(path: "letter.md"))
        #expect(document.currentFormat == .md)
        #expect(document.text == "**Title**\n")
        #expect(!document.isDirty)
        #expect(try String(contentsOf: #require(document.url), encoding: .utf8) == "**Title**\n")
        #expect(try Data(contentsOf: original) == originalBytes)
    }

    @Test func cancelledSaveAsConversionWritesNothing() async throws {
        let alerts = AlertRecorder()
        let fixture = try FormatSwitchFixture(selectSaveFile: { directory, name in directory.appending(path: name) }, alerts: alerts)
        defer { fixture.cleanUp() }
        let original = fixture.root.appending(path: "letter.rtf")
        try RTFConverter.rtfData(from: PadRichText.document(from: Self.richJSON)).write(to: original)
        let document = fixture.document
        document.open(original)
        await document.saveAs(targetFormat: .txt)
        #expect(alerts.last?.title == "Save a copy as plain text?")
        #expect(document.url == original)
        #expect(document.currentFormat == .rtf)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "letter.txt").path))
        #expect(!document.isBusy)
    }

    @Test func plainTextSaveAsRTFWritesReadableRTF() async throws {
        let fixture = try FormatSwitchFixture(selectSaveFile: { directory, name in directory.appending(path: name) })
        defer { fixture.cleanUp() }
        let original = fixture.root.appending(path: "notes.txt")
        try Data("One\nTwo\n".utf8).write(to: original)
        let document = fixture.document
        document.open(original)
        await document.saveAs(targetFormat: .rtf)
        let copy = fixture.root.appending(path: "notes.rtf")
        #expect(document.url == copy)
        #expect(try RTFConverter.document(contentsOf: copy).plainText == "One\nTwo")
        #expect(try String(contentsOf: original, encoding: .utf8) == "One\nTwo\n")
    }
}

@MainActor
private struct FormatSwitchFixture {
    let root: URL
    let defaults: UserDefaults
    let document: PadDocument
    private let suite: String
    private let folder: FolderChoice
    /// The folder the save-folder chooser returns, when the fixture has one.
    var selectedFolder: URL? {
        get { folder.url }
        nonmutating set { folder.url = newValue }
    }

    init(format: PadFormat = .md, selectSaveFile: (@MainActor (URL, String) async -> URL?)? = nil,
         choosesSaveFolder: Bool = false, alerts: AlertRecorder? = nil) throws {
        let choice = FolderChoice()
        folder = choice
        suite = "pad-format-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(format.rawValue, forKey: "pad.format")
        root = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var chooser: (@MainActor (URL) -> URL?)?
        if choosesSaveFolder { chooser = { _ in choice.url } }
        document = PadDocument(defaults: defaults, defaultFolder: root, presentsWindow: false,
                               copyPath: { _ in }, selectSaveFile: selectSaveFile,
                               selectSaveFolder: chooser,
                               resolveUnsavedChanges: { .cancel }, presentAlert: alerts?.present)
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

@MainActor
private final class FolderChoice {
    var url: URL?
}
