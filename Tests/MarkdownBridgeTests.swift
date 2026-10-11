import AppKit
import Testing
import WebKit
import PDFKit
@testable import Pad

@MainActor
@Suite(.serialized, .opensWindows)
struct MarkdownBridgeTests {
    private final class ReadingPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    @Test func windowEventRoutingLeavesReadingAndNativeControlsAlone() async throws {
        let suite = "pad-reading-events-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set(false, forKey: "pad.saveAutomatically")
        let file = FileManager.default.temporaryDirectory.appending(path: "\(suite).md")
        let source = "# Read this\n\nExisting **writing**.\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let document = PadDocument(defaults: defaults, presentsWindow: false)
        try #require(document.openDocument(file))
        document.mountMarkdownEditor()
        let editor = try #require(document.markdownEditor)
        let window = PadPanel(files: document)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        editor.webView.frame = NSRect(x: 0, y: 0, width: 500, height: 550)
        let field = NSTextField(frame: NSRect(x: 0, y: 550, width: 500, height: 30))
        content.addSubview(editor.webView)
        content.addSubview(field)
        window.contentView = content
        defer {
            window.orderOut(nil)
            window.contentView = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await ready(editor)
        try #require(window.isKeyWindow)
        window.makeFirstResponder(window)
        func key(_ character: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: character, charactersIgnoringModifiers: character,
                                         isARepeat: false, keyCode: 12))
        }
        NSApp.sendEvent(try key("q"))
        #expect(try await editor.snapshot() == nil)
        #expect(window.firstResponder === window)
        #expect(!editor.ownsFirstResponder)
        #expect(try String(contentsOf: file, encoding: .utf8) == source)

        try #require(window.makeFirstResponder(field))
        NSApp.sendEvent(try key("q"))
        #expect(field.stringValue == "q")
        #expect(try await editor.snapshot() == nil)
        #expect(!editor.ownsFirstResponder)

        // Explicit composition owns the input buffer before asynchronous DOM focus.
        editor.enqueue([try key("q")])
        NSApp.sendEvent(try key("q"))
        #expect(try await editor.snapshot()?.contains("qq") == true)
    }

    @Test func textSurfaceFocusDoesNotDrawAnOuterRing() async throws {
        let editor = PadMarkdownEditorController()
        let window = ReadingPanel(contentRect: NSRect(x: 100, y: 100, width: 500, height: 600),
                                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.webView
        let other = ReadingPanel(contentRect: NSRect(x: 650, y: 100, width: 250, height: 200),
                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            other.orderOut(nil); other.close()
        }
        window.makeKeyAndOrderFront(nil)
        #expect(window.isKeyWindow)
        editor.load("Read and edit this text", documentID: UUID())
        _ = try await editor.snapshot()
        let outline = try await editor.webView.evaluateJavaScript("""
        window.editor.focus();
        getComputedStyle(document.querySelector('.ProseMirror')).outlineStyle
        """) as? String
        #expect(outline == "none")
        other.makeKeyAndOrderFront(nil)
        #expect(other.isKeyWindow)
        editor.load("Background document", documentID: UUID())
        _ = try await editor.snapshot()
        #expect(other.isKeyWindow)
        #expect(!window.isKeyWindow)
    }

    @Test func browserCompositionRejectionDoesNotDisableLaterSnapshots() async throws {
        let editor = PadMarkdownEditorController()
        editor.load("Keep this text\n", documentID: UUID())
        _ = try await editor.snapshot()
        var failures = 0
        editor.onError = { _ in failures += 1 }

        // Native marked-text guards must retain the document without touching the script bridge.
        editor.hasExternalMarkedText = { true }
        do {
            _ = try await editor.snapshot()
            Issue.record("Native marked text should reject the snapshot")
        } catch PadMarkdownEditorError.composing {} catch { Issue.record("Unexpected native error: \(error)") }
        editor.hasExternalMarkedText = { false }

        // ProseMirror can begin composition independently after native guards have passed.
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.ProseMirror').dispatchEvent(new CompositionEvent('compositionstart', {bubbles:true})); true")
        do {
            _ = try await editor.snapshot()
            Issue.record("Browser composition should reject the snapshot")
        } catch PadMarkdownEditorError.snapshotRejected(let code, _) {
            #expect(code == "composition")
        } catch { Issue.record("Unexpected browser error: \(error)") }
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.ProseMirror').dispatchEvent(new CompositionEvent('compositionend', {bubbles:true})); true")
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.isReady)
        #expect(failures == 0)
        #expect(try await editor.snapshot() == nil)
        editor.format(.heading, argument: "2")
        #expect(try await editor.snapshot()?.hasPrefix("## Keep this text") == true)
        let clipboard = try await editor.clipboardSnapshot()
        #expect(clipboard.text == "Keep this text")
        #expect(clipboard.html?.contains("<h2") == true)
    }

    @Test func editingSurfaceRetainsViewportHeightAndTextSize() async throws {
        let editor = PadMarkdownEditorController()
        editor.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        editor.load("Short paragraph\n", documentID: UUID())
        _ = try await editor.snapshot()
        let output = try await editor.webView.evaluateJavaScript("""
            window.editor.setTextSize(21);
            const surface = document.querySelector('.ProseMirror');
            const style = getComputedStyle(surface);
            ({height: surface.getBoundingClientRect().height, viewport: innerHeight,
              fontSize: style.fontSize, paddingTop: style.paddingTop, paddingBottom: style.paddingBottom})
            """) as? [String: Any]
        let height = try #require(output?["height"] as? Double)
        let viewport = try #require(output?["viewport"] as? Double)
        #expect(viewport > 0)
        #expect(height >= viewport)
        #expect(output?["fontSize"] as? String == "21px")
        #expect(output?["paddingTop"] as? String == "10px")
        #expect(output?["paddingBottom"] as? String == "48px")
    }

    @Test func nativeTextPrintUsesContentHeight() throws {
        for long in [false, true] {
            let text = "PLAIN HEADING\n\n**literal markers**\n\n"
                + (long ? (0..<160).map { "Paragraph \($0) contains plain writing.\n\n" }.joined() : "")
                + "PLAIN FINAL TAIL\n"
            let url = FileManager.default.temporaryDirectory.appending(path: "pad-text-print-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let operation = NSPrintOperation(view: PadPlainTextPrintView.make(text), printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            #expect(operation.run())
            let pdf = try #require(PDFDocument(url: url))
            #expect(long ? pdf.pageCount > 1 : pdf.pageCount == 1)
            #expect(pdf.string?.contains("PLAIN HEADING") == true)
            #expect(pdf.string?.contains("**literal markers**") == true)
            #expect(pdf.string?.contains("PLAIN FINAL TAIL") == true)
        }
    }

    @Test func nativePrintExportsCompleteFrozenPDF() async throws {
        let editor = PadMarkdownEditorController()
        let text = "# PRINT HEADING\n\n**Bold body**\n\n| Name | Value |\n| --- | --- |\n| Table cell | 42 |\n\n"
            + (0..<160).map { "Paragraph \($0) contains printable writing.\n\n" }.joined()
            + "PRINT FINAL TAIL\n"
        editor.load(text, documentID: UUID())
        _ = try await editor.snapshot()
        let output = try await editor.webView.callAsyncJavaScript("return await window.editor.printable(window.editor.snapshot().generation)", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let html = try #require(output?["html"] as? String)
        let renderer = PadPrintRenderer()
        try await renderer.loadHTML(html)
        let url = FileManager.default.temporaryDirectory.appending(path: "pad-print-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        #expect(await renderer.printDocument(printInfo: info, showsPanel: false))
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount > 1)
        let contents = pdf.string ?? ""
        #expect(contents.contains("PRINT HEADING"))
        #expect(contents.contains("Bold body"))
        #expect(contents.contains("Table cell"))
        #expect(contents.contains("PRINT FINAL TAIL"))
    }

    @Test func staleCommandsRetainLaterSnapshots() async throws {
        let editor = PadMarkdownEditorController()
        editor.load("Keep this text\n", documentID: UUID())
        _ = try await editor.snapshot()
        for script in ["window.editor.setEditingMode('source', -1)", "window.editor.find('text', -1)", "window.editor.replaceAll('text', 'lost', -1)", "window.editor.undo(-1)"] {
            let result = try await editor.webView.evaluateJavaScript(script) as? [String: Any]
            #expect(result?["commandError"] as? String == "stale-document")
        }
        #expect(editor.isReady)
        #expect(try await editor.snapshot() == nil)
    }

    @Test func unknownSnapshotFailureStillDisablesTheBridge() async throws {
        let editor = PadMarkdownEditorController()
        editor.load("Retain this text\n", documentID: UUID())
        _ = try await editor.snapshot()
        _ = try await editor.webView.evaluateJavaScript("window.editor.snapshot = () => {throw new Error('Unexpected snapshot failure')}; true")
        await #expect(throws: (any Error).self) { _ = try await editor.snapshot() }
        for _ in 0..<100 {
            if !editor.isReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!editor.isReady)
        await #expect(throws: (any Error).self) { _ = try await editor.snapshot() }
    }

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
