import Foundation
import InkKitRTF
import Testing
@testable import Pad

@MainActor
@Suite struct FormatSwitchTests {
    @Test func cyclingSkipsDisabledFormatsAndPreservesSource() async throws {
        let fixture = try FormatSwitchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.setFormatEnabled(.rtf, enabled: false)
        let source = "# Keep é\r\n\r\n**These**  spaces\r\n"
        document.text = source
        document.editorSnapshot = { source }
        await document.cycleFormat()
        #expect(document.currentFormat == .txt)
        #expect(document.text == source)
        await document.cycleFormat()
        #expect(document.currentFormat == .md)
        #expect(document.text == source)
        #expect(document.format == .md)
        document.setFormatEnabled(.md, enabled: false)
        #expect(document.nextFormat == .txt)
        await document.cycleFormat()
        #expect(document.currentFormat == .txt)
        #expect(document.nextFormat == nil)
        await document.cycleFormat()
        #expect(document.text == source)
    }

    @Test func failedCycleRetainsFormatAndText() async throws {
        let fixture = try FormatSwitchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Keep this"
        document.editorSnapshot = { throw CocoaError(.fileReadUnknown) }
        await document.cycleFormat()
        #expect(document.currentFormat == .md)
        #expect(document.text == "Keep this")
        #expect(!document.isBusy)
    }

    @Test func cycleOrderIncludesRTFAndWraps() async throws {
        let fixture = try FormatSwitchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        #expect(document.nextFormat == .txt)
        await document.cycleFormat()
        #expect(document.nextFormat == .rtf)
        await document.cycleFormat()
        #expect(document.currentFormat == .rtf)
        #expect(document.nextFormat == .md)
    }

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

    @Test(arguments: 1...7, [PadFormat.md, .txt, .rtf])
    func enabledCombinationsKeepValidDefaultsAndCurrentDraft(mask: Int, initial: PadFormat) throws {
        let fixture = try FormatSwitchFixture(format: initial)
        defer { fixture.cleanUp() }
        let document = fixture.document
        let source = initial == .rtf ? Self.richJSON : "é &amp; \r\n*  Untidy source  \r\n"
        document.text = source
        let id = document.documentID
        let enabled = PadFormat.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
        for format in PadFormat.allCases where !enabled.contains(format) {
            document.setFormatEnabled(format, enabled: false)
        }
        #expect(document.enabledFormats == enabled)
        #expect(document.format == (enabled.contains(initial) ? initial : enabled[0]))
        #expect(document.currentFormat == initial)
        #expect(Data(document.text.utf8) == Data(source.utf8))
        #expect(document.documentID == id)
        #expect(document.hasFormatChoices == (enabled.count > 1 || !enabled.contains(initial)))
        let restored = PadDocument(defaults: fixture.defaults, defaultFolder: fixture.root, presentsWindow: false)
        #expect(restored.enabledFormats == enabled)
        #expect(restored.format == document.format)
        #expect(restored.currentFormat == document.format)
        #expect(Set(fixture.defaults.stringArray(forKey: "pad.enabledFormats") ?? PadFormat.allCases.map(\.rawValue)) == Set(enabled.map(\.rawValue)))
        for format in enabled {
            document.format = format
            #expect(PadDocument(defaults: fixture.defaults, presentsWindow: false).format == format)
        }
        for format in PadFormat.allCases where !enabled.contains(format) {
            let prior = document.format
            document.format = format
            #expect(document.format == prior)
        }
        if let only = enabled.first, enabled.count == 1 {
            document.setFormatEnabled(only, enabled: false)
            #expect(document.enabledFormats == [only])
            #expect(document.format == only)
        }
        document.resetQuickPadPreferences()
        #expect(document.enabledFormats == PadFormat.allCases)
        #expect(document.format == .md)
        #expect(document.currentFormat == initial)
        #expect(Data(document.text.utf8) == Data(source.utf8))
        let reset = PadDocument(defaults: fixture.defaults, presentsWindow: false)
        #expect(reset.enabledFormats == PadFormat.allCases)
        #expect(reset.format == .md)
    }

    @Test(arguments: [[], ["unknown"], ["txt", "txt", "unknown"], ["rtf", "md"]])
    func invalidStoredFormatsProduceAnOrderedNonemptySet(stored: [String]) throws {
        let fixture = try FormatSwitchFixture(format: .rtf)
        defer { fixture.cleanUp() }
        fixture.defaults.set(stored, forKey: "pad.enabledFormats")
        let restored = PadDocument(defaults: fixture.defaults, presentsWindow: false)
        let valid = PadFormat.allCases.filter { stored.contains($0.rawValue) }
        #expect(restored.enabledFormats == (valid.isEmpty ? PadFormat.allCases : valid))
        #expect(restored.enabledFormats.contains(restored.format))
        #expect(fixture.defaults.stringArray(forKey: "pad.enabledFormats") == restored.enabledFormats.map(\.rawValue))
    }

    @Test func incorrectlyTypedStoredFormatsUseAndPersistAllFormats() throws {
        let fixture = try FormatSwitchFixture(format: .txt)
        defer { fixture.cleanUp() }
        fixture.defaults.set("rtf", forKey: "pad.enabledFormats")
        let restored = PadDocument(defaults: fixture.defaults, presentsWindow: false)
        #expect(restored.enabledFormats == PadFormat.allCases)
        #expect(restored.format == .txt)
        #expect(fixture.defaults.stringArray(forKey: "pad.enabledFormats") == ["md", "txt", "rtf"])
    }

    @Test func fileWindowInitializationDoesNotWriteQuickPadPreferences() throws {
        let fixture = try FormatSwitchFixture(format: .rtf)
        defer { fixture.cleanUp() }
        fixture.defaults.set(["txt"], forKey: "pad.enabledFormats")
        _ = PadDocument(defaults: fixture.defaults, presentsWindow: false, role: .file)
        #expect(fixture.defaults.string(forKey: "pad.format") == "rtf")
        #expect(fixture.defaults.stringArray(forKey: "pad.enabledFormats") == ["txt"])
    }

    @Test func disabledMenuActionDoesNotCaptureOrConvert() async throws {
        let fixture = try FormatSwitchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Keep this"
        document.setFormatEnabled(.rtf, enabled: false)
        document.editorSnapshot = { Issue.record("Disabled action must not request a snapshot"); return "stale" }
        await document.changeFormat(to: .rtf)
        #expect(document.currentFormat == .md)
        #expect(document.text == "Keep this")
        #expect(!document.isBusy)
    }

    @Test func formatDisabledDuringSnapshotCannotConvert() async throws {
        let fixture = try FormatSwitchFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.editorSnapshot = {
            document.setFormatEnabled(.rtf, enabled: false)
            return "Latest source"
        }
        document.editorConversion = { _ in Issue.record("Disabled target must not convert"); throw CocoaError(.featureUnsupported) }
        await document.changeFormat(to: .rtf)
        #expect(document.currentFormat == .md)
        #expect(document.text == "Latest source")
        #expect(!document.isBusy)
    }

    @Test func formatDisabledDuringConversionCannotReplaceDraft() async throws {
        let alerts = AlertRecorder()
        let fixture = try FormatSwitchFixture(alerts: alerts)
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Keep this"
        document.editorConversion = { _ in
            document.setFormatEnabled(.rtf, enabled: false)
            return PadConversion(text: Self.richJSON, changes: PadFormatLoss.changes(for: ["heading"]))
        }
        await document.changeFormat(to: .rtf)
        #expect(document.currentFormat == .md)
        #expect(document.text == "Keep this")
        #expect(alerts.alerts.isEmpty)
        #expect(!document.isBusy)
    }

    @Test func disabledRTFStillOpensAndUneditedSaveAsCopiesExactBytes() async throws {
        let fixture = try FormatSwitchFixture(selectSaveFile: { directory, _ in directory.appending(path: "copy.rtf") })
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.setFormatEnabled(.rtf, enabled: false)
        let original = fixture.root.appending(path: "letter.rtf")
        let bytes = try RTFConverter.rtfData(from: PadRichText.document(from: Self.richJSON))
        try bytes.write(to: original)
        document.open(original)
        #expect(document.currentFormat == .rtf)
        document.save()
        #expect(try Data(contentsOf: original) == bytes)
        await document.saveAs(targetFormat: .rtf)
        #expect(try Data(contentsOf: #require(document.url)) == bytes)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(document.currentFormat == .rtf)
        #expect(!document.enabledFormats.contains(.rtf))
    }

    @Test func folderCancellationAndFailureKeepSelectionAndWriting() async throws {
        let fixture = try FormatSwitchFixture(choosesSaveFolder: true)
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "Keep this draft"
        let id = document.documentID
        fixture.selectedFolder = fixture.root
        await document.chooseFolder()
        #expect(document.folder == fixture.root)
        #expect(document.folderError == nil)
        let bookmark = fixture.defaults.data(forKey: "pad.folderBookmark")
        #expect(bookmark != nil)
        fixture.selectedFolder = nil
        await document.chooseFolder()
        #expect(document.folder == fixture.root)
        #expect(document.folderError == nil)
        #expect(fixture.defaults.data(forKey: "pad.folderBookmark") == bookmark)
        fixture.selectedFolder = fixture.root.appending(path: "Unavailable", directoryHint: .isDirectory)
        await document.chooseFolder()
        #expect(document.folder == fixture.root)
        #expect(document.folderError == "PadPad can’t use this folder. Choose another one.")
        #expect(fixture.defaults.data(forKey: "pad.folderBookmark") == bookmark)
        #expect(document.text == "Keep this draft")
        #expect(document.documentID == id)
        #expect(document.url == nil)
        #expect(!document.isBusy)
        fixture.selectedFolder = fixture.root
        await document.chooseFolder()
        #expect(document.folderError == nil)
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
