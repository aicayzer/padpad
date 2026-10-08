import AppKit
import Testing
import WebKit
@testable import Pad

@MainActor
@Suite(.serialized, .opensWindows)
struct MarkdownBridgeTests {
    @Test func queuedReplacementLoadsApplyOnlyTheLatestDocument() async throws {
        let editor = PadMarkdownEditorController()
        editor.load("Initial\n", documentID: UUID())
        _ = try await editor.snapshot()
        _ = try await editor.webView.evaluateJavaScript("window.receivedLoads = []; const originalLoad = window.editor.load; window.editor.load = (...args) => {window.receivedLoads.push(args[0]); return originalLoad(...args)}; true")
        for index in 0..<20 { editor.load("Document \(index)\n", documentID: UUID()) }
        #expect(try await editor.snapshot() == nil)
        let calls = try await editor.webView.evaluateJavaScript("window.receivedLoads") as? [String]
        #expect(calls == ["Document 19\n"])
        let source = try await editor.webView.evaluateJavaScript("window.editor.snapshot().text") as? String
        #expect(source == "Document 19\n")
    }

    @Test func clipboardAcknowledgmentReportsFailureAndRejectsStaleDocuments() async throws {
        let editor = PadMarkdownEditorController()
        let id = UUID()
        editor.load("Keep this text\n", documentID: id)
        _ = try await editor.snapshot()
        var writes = 0
        editor.clipboardWriter = { _ in writes += 1; throw CocoaError(.fileWriteUnknown) }
        _ = try await editor.webView.evaluateJavaScript("window.editor.clipboardResponse = (id, value) => { window.clipboardReply = {id, ...value}; }; true")
        for stale in [false, true] {
            _ = try await editor.webView.evaluateJavaScript("(() => {const scope = window.editor.snapshot(); window.clipboardReply = null; webkit.messageHandlers.host.postMessage({type:'writeClipboard',requestId:'fixture',generation:scope.generation - \(stale ? 1 : 0),documentId:scope.documentId,text:'Replacement',html:'<p>Replacement</p>'}); return true; })()")
            var response: [String: Any]?
            for _ in 0..<100 {
                response = try await editor.webView.evaluateJavaScript("window.clipboardReply") as? [String: Any]
                if response != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(response?["id"] as? String == "fixture")
            #expect(response?["error"] is String)
        }
        #expect(writes == 1)
        #expect(editor.isReady)
        #expect(try await editor.snapshot() == nil)
    }

    @Test func aRecoverableWarningDoesNotDisableSnapshots() async throws {
        let editor = PadMarkdownEditorController()
        var warnings = 0
        editor.onError = { _ in warnings += 1 }
        editor.load("Keep this text\n", documentID: UUID())
        _ = try await editor.snapshot()
        _ = try await editor.webView.evaluateJavaScript("webkit.messageHandlers.host.postMessage({type:'editorWarning',message:'The pasted image is unavailable.'}); true")
        for _ in 0..<100 {
            if warnings == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(warnings == 1)
        #expect(editor.isReady)
        #expect(try await editor.snapshot() == nil)
    }

    @Test func toolbarStateIncludesHeadingListsAndQuotesAndRepeatedHeadingReturnsToBody() async throws {
        let editor = PadMarkdownEditorController()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.webView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        editor.load("Selected words", documentID: UUID())
        try await ready(editor)
        for level in 1...3 {
            editor.format(.heading, argument: String(level))
            _ = try await editor.snapshot()
            try await toolbarState(editor, contains: "heading\(level)", active: true)
            #expect(editor.activeMarks.contains("heading"))
            editor.format(.heading, argument: String(level))
            _ = try await editor.snapshot()
            try await toolbarState(editor, contains: "heading", active: false)
        }
        for command in [PadMarkdownFormatCommand.bulletList, .orderedList, .quote] {
            editor.format(command)
            _ = try await editor.snapshot()
            try await toolbarState(editor, contains: command.rawValue, active: true)
            editor.format(command)
            _ = try await editor.snapshot()
            try await toolbarState(editor, contains: command.rawValue, active: false)
        }
    }

    private func toolbarState(_ editor: PadMarkdownEditorController, contains value: String, active: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while editor.activeMarks.contains(value) != active, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(editor.activeMarks.contains(value) == active)
    }

    @Test func sourcePreservationFormattingReplacementAndSnapshotFailure() async throws {
        let editor = PadMarkdownEditorController()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.webView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        var changes: [(String, UUID)] = []
        editor.onChanged = { changes.append(($0, $1)) }
        let first = UUID()
        let original = "Original with **bold** and _italic_.\n"
        editor.load(original, documentID: first)
        try await ready(editor)
        #expect(try await editor.snapshot() == nil)
        let html = try await editor.webView.evaluateJavaScript("document.querySelector('.ProseMirror').innerHTML") as? String
        #expect(html?.contains("<strong>bold</strong>") == true)
        #expect(html?.contains("<em>italic</em>") == true)

        // Formatting is an actual editor transaction, not a native text-model simulation.
        editor.format(.heading, argument: "2")
        let edited = try await editor.snapshot()
        #expect(edited?.hasPrefix("## Original") == true)
        #expect(changes.last?.1 == first)

        let replacement = UUID()
        editor.load("Replacement", documentID: replacement)
        #expect(try await editor.snapshot() == nil)
        editor.format(.heading, argument: "3")
        #expect(try await editor.snapshot()?.hasPrefix("### Replacement") == true)
        #expect(changes.last?.1 == replacement)

        // A broken bridge must never look like an unchanged document to a destructive operation.
        _ = try await editor.webView.evaluateJavaScript("delete window.editor")
        await #expect(throws: (any Error).self) {
            _ = try await editor.snapshot()
        }
    }

    @Test func saveAsFormatRoundTripReloadsNativeEditsIntoTheMountedEditor() async throws {
        let suite = "pad-format-roundtrip-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appending(path: "plain.txt")
        let document = PadDocument(defaults: defaults, defaultFolder: folder, presentsWindow: false,
                                   copyPath: { _ in }, selectSaveFile: { _, _ in destination })
        document.text = "Original **Markdown**"
        document.mountMarkdownEditor()
        let editor = try #require(document.markdownEditor)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.webView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        try await ready(editor)
        await document.saveAs()
        #expect(document.currentFormat == .txt)

        document.text = "Native edits with **new bold**"
        destination = folder.appending(path: "formatted.md")
        await document.saveAs()
        #expect(document.currentFormat == .md)
        try await ready(editor)
        #expect(try await editor.snapshot() == nil)
        let html = try await editor.webView.evaluateJavaScript("document.querySelector('.ProseMirror').innerHTML") as? String
        #expect(html?.contains("<strong>new bold</strong>") == true)
        #expect(html?.contains("Original") == false)

        // An unchanged snapshot must preserve the newly loaded source rather than the old Markdown.
        document.save()
        try await settled(document)
        #expect(document.text == "Native edits with **new bold**")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Native edits with **new bold**")
        editor.format(.heading, argument: "2")
        document.save()
        try await settled(document)
        #expect(try String(contentsOf: destination, encoding: .utf8).hasPrefix("## Native edits"))
    }

    @Test func clipboardExportPreservesSelectionAndRejectsReplacedDocument() async throws {
        let editor = PadMarkdownEditorController()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.webView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        editor.load("**Bold** & plain", documentID: UUID())
        try await ready(editor)
        _ = try await editor.webView.evaluateJavaScript("""
            (() => {
                const text = document.querySelector('.ProseMirror strong').firstChild;
                const range = document.createRange();
                range.setStart(text, 1); range.setEnd(text, 3);
                const selection = getSelection();
                selection.removeAllRanges(); selection.addRange(range);
            })()
            """)
        let selectionBefore = try await editor.webView.evaluateJavaScript("getSelection().toString()") as? String
        let copied = try await editor.clipboardSnapshot()
        #expect(copied.text == "Bold & plain")
        #expect(copied.html?.contains("<strong>Bold</strong>") == true)
        #expect(try await editor.webView.evaluateJavaScript("getSelection().toString()") as? String == selectionBefore)
        #expect(try await editor.snapshot() == nil)
        var started = false
        let pending = Task {
            started = true
            return try await editor.clipboardSnapshot()
        }
        while !started { await Task.yield() }
        editor.load("Replacement", documentID: UUID())
        do {
            _ = try await pending.value
            Issue.record("A replaced document must not export stale contents")
        } catch {
            if case PadMarkdownEditorError.documentChanged = error {} else { Issue.record("Unexpected error: \(error)") }
        }
    }

    private func settled(_ document: PadDocument) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while document.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!document.isBusy, "The editor snapshot did not finish")
        #expect(document.error == nil)
    }

    @Test func queuedAndLiveKeystrokesKeepTheirOrderDuringFocusHandoff() async throws {
        let suite = "pad-input-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = PadDocument(defaults: defaults, presentsWindow: false)
        document.mountMarkdownEditor()
        let editor = try #require(document.markdownEditor)
        let window = PadPanel(files: document)
        window.isReleasedWhenClosed = false
        window.contentView = editor.webView
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            // PadPanel.close performs document actions; this test owns only the window.
        }
        editor.load("", documentID: UUID())
        try await ready(editor)
        let focusDeadline = ContinuousClock.now + .seconds(5)
        while !window.isKeyWindow, ContinuousClock.now < focusDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(window.isKeyWindow)
        let queued = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                                                  timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                                  characters: "I", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
        let live = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 2, windowNumber: window.windowNumber, context: nil,
                                                characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46))
        editor.enqueue([queued])
        // The second key arrives before the asynchronous JavaScript focus call returns.
        window.sendEvent(live)
        let captured = try await editor.snapshot()
        #expect(captured?.trimmingCharacters(in: .whitespacesAndNewlines) == "Im")
    }

    private func ready(_ editor: PadMarkdownEditorController) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !editor.isReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(editor.isReady, "The bundled Markdown editor did not become ready")
    }
}
