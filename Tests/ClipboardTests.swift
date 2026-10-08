import AppKit
import Testing
@testable import Pad

@MainActor
@Suite struct ClipboardTests {
    @Test func failedNativeWriteRestoresPreviousRepresentations() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try PadClipboardContents(text: "Previous", html: "<p>Previous</p>").write(to: board)
        #expect(throws: CocoaError.self) {
            try PadClipboardContents(text: "Replacement", html: "<p>Replacement</p>").write(to: board, writer: { _ in false })
        }
        #expect(board.string(forType: .string) == "Previous")
        #expect(board.string(forType: .html) == "<p>Previous</p>")
    }

    @Test func formattedCopyUsesFreshEditorAndSourceCopyRetainsMarkdown() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.cleanUp() }
        let document = fixture.document
        document.text = "outdated"
        var captured = false
        document.editorSnapshot = { captured = true; return "**Latest** & text" }
        document.editorClipboard = {
            #expect(captured)
            return PadClipboardContents(text: "Latest & text", html: "<p><strong>Latest</strong> &amp; text</p>")
        }
        await document.copyAllContents(to: fixture.pasteboard)
        #expect(document.text == "**Latest** & text")
        #expect(fixture.pasteboard.string(forType: .string) == "Latest & text")
        #expect(fixture.pasteboard.string(forType: .html) == "<p><strong>Latest</strong> &amp; text</p>")
        #expect(!document.isBusy)
        document.editorSnapshot = { "**Even newer**" }
        document.editorClipboard = { Issue.record("Source copy must not render HTML"); throw CocoaError(.fileReadUnknown) }
        await document.copyAllContents(asMarkdown: true, to: fixture.pasteboard)
        #expect(fixture.pasteboard.string(forType: .string) == "**Even newer**")
        #expect(fixture.pasteboard.string(forType: .html) == nil)
    }

    @Test func plainTextCopyKeepsLiteralCharactersAndRemovesStaleHTML() async throws {
        let fixture = try ClipboardFixture(format: "txt")
        defer { fixture.cleanUp() }
        fixture.document.text = "**literal** & <br />; \nnext"
        fixture.document.editorSnapshot = { Issue.record("Plain text must not read Markdown"); return nil }
        fixture.pasteboard.setString("<strong>Old</strong>", forType: .html)
        await fixture.document.copyAllContents(to: fixture.pasteboard)
        #expect(fixture.pasteboard.string(forType: .string) == fixture.document.text)
        #expect(fixture.pasteboard.string(forType: .html) == nil)
    }

    @Test(arguments: [false, true])
    func failedReadDoesNotOverwriteClipboard(exportFails: Bool) async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.cleanUp() }
        fixture.document.text = "Keep me"
        fixture.pasteboard.setString("Previous clipboard", forType: .string)
        let changeCount = fixture.pasteboard.changeCount
        fixture.document.editorSnapshot = {
            if !exportFails { throw CocoaError(.fileReadUnknown) }
            return "Keep me"
        }
        fixture.document.editorClipboard = { throw CocoaError(.fileReadUnknown) }
        await fixture.document.copyAllContents(to: fixture.pasteboard)
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(fixture.pasteboard.string(forType: .string) == "Previous clipboard")
        #expect(fixture.document.text == "Keep me")
        #expect(fixture.document.error != nil)
        #expect(!fixture.document.isBusy)
    }
}

@MainActor
private struct ClipboardFixture {
    let document: PadDocument
    let pasteboard = NSPasteboard.withUniqueName()
    let defaults: UserDefaults
    let suite = "pad-clipboard-\(UUID().uuidString)"

    init(format: String = "md") throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(format, forKey: "pad.format")
        document = PadDocument(defaults: defaults, presentsWindow: false)
    }

    func cleanUp() {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
    }
}
