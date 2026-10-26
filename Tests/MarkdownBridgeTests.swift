import AppKit
import Testing
import WebKit
import PDFKit
import SwiftUI
@testable import Pad

@MainActor
@Suite(.serialized, .opensWindows)
struct MarkdownBridgeTests {
    private final class ReadingPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    @Test func firstContentClickIntoReadyBackgroundDocumentKeepsEditingFocus() async throws {
        let suite = "pad-background-click-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set(false, forKey: "pad.saveAutomatically")
        let file = FileManager.default.temporaryDirectory.appending(path: "\(suite).md")
        try "Background document".write(to: file, atomically: true, encoding: .utf8)
        let secondFile = FileManager.default.temporaryDirectory.appending(path: "\(suite)-second.md")
        try "Foreground document".write(to: secondFile, atomically: true, encoding: .utf8)
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.addsToRecentItems = false
        let running = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        try #require(running.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        let oldPolicy = NSApp.activationPolicy()
        let settings = AppSettings(defaults: defaults)
        let workspace = PadWorkspace(settings: settings, defaults: defaults, presentAlert: AlertRecorder().present)
        workspace.open(file)
        workspace.open(secondFile)
        let document = try #require(workspace.document(at: file))
        let window = try #require(document.nativeWindow)
        let other = try #require(workspace.document(at: secondFile)?.nativeWindow)
        defer {
            window.orderOut(nil); window.contentView = nil
            other.orderOut(nil); other.contentView = nil
            NSApp.setActivationPolicy(oldPolicy)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: secondFile)
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while document.markdownEditor == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try #require(document.markdownEditor)
        try await ready(editor)
        try #require(!window.isKeyWindow)
        try #require(other.isKeyWindow)
        _ = try await editor.webView.evaluateJavaScript("""
        window.padClickWitness = [];
        document.querySelector('.ProseMirror').addEventListener('mousedown', event => {
          window.padClickWitness.push(event.isTrusted);
        }, true);
        true
        """)
        window.contentView?.layoutSubtreeIfNeeded()
        let bounds = editor.webView.bounds
        try #require(bounds.width > 40 && bounds.height > 40)
        let point = editor.webView.convert(NSPoint(x: bounds.midX,
                                                   y: editor.webView.isFlipped ? 20 : bounds.height - 20), to: nil)
        // Activation and native content mouse delivery happen in one actor turn.
        // The queued focus helper runs afterward, just as for a first body click.
        window.makeKeyAndOrderFront(nil)
        for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let click = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: number + 1, clickCount: 1, pressure: 1))
            NSApp.sendEvent(click)
        }
        let trusted = try await editor.webView.evaluateJavaScript("window.padClickWitness") as? [Bool]
        try #require(trusted == [true], "The native click must reach the actual content surface")
        let refreshDeadline = ContinuousClock.now + .seconds(15)
        while document.isBusy || !editor.isReady, ContinuousClock.now < refreshDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!document.isBusy && editor.isReady)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: "q", charactersIgnoringModifiers: "q",
                                              isARepeat: false, keyCode: 12))
        NSApp.sendEvent(key)
        #expect(try await editor.snapshot()?.contains("q") == true)
        #expect(editor.ownsFirstResponder)
    }

    @Test(arguments: [0, 30])
    func firstNativeEndCommandAfterContentClickPreservesSpaceAndTyping(keyHandlerWork: Int) async throws {
        let suite = "pad-click-command-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set(false, forKey: "pad.saveAutomatically")
        let file = FileManager.default.temporaryDirectory.appending(path: "\(suite).md")
        try "Background document".write(to: file, atomically: true, encoding: .utf8)
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.addsToRecentItems = false
        let running = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        try #require(running.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        let oldPolicy = NSApp.activationPolicy()
        let settings = AppSettings(defaults: defaults)
        let workspace = PadWorkspace(settings: settings, defaults: defaults, presentAlert: AlertRecorder().present)
        workspace.open(file)
        let document = try #require(workspace.document(at: file))
        let window = try #require(document.nativeWindow)
        defer {
            window.orderOut(nil); window.contentView = nil
            NSApp.setActivationPolicy(oldPolicy)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while document.markdownEditor == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try #require(document.markdownEditor)
        try await ready(editor)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let keyDeadline = ContinuousClock.now + .seconds(5)
        while !window.isKeyWindow, ContinuousClock.now < keyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(window.isKeyWindow)
        _ = try await editor.webView.evaluateJavaScript("""
        window.padClickWitness = [];
        document.querySelector('.ProseMirror').addEventListener('mousedown', event => {
          window.padClickWitness.push(event.isTrusted);
        }, true);
        window.padKeyWitness = [];
        document.addEventListener('keydown', event => {
          window.padKeyWitness.push({key: event.key, trusted: event.isTrusted});
          if (event.metaKey && event.key === 'ArrowDown') {
            // Model a busy web-content turn so its pending focus check can run
            // before the selectionchange caused by the native caret command.
            const deadline = performance.now() + \(keyHandlerWork);
            while (performance.now() < deadline) {}
          }
        }, true);
        true
        """)
        window.contentView?.layoutSubtreeIfNeeded()
        let bounds = editor.webView.bounds
        try #require(bounds.width > 40 && bounds.height > 40)
        let point = editor.webView.convert(NSPoint(x: 55,
                                                   y: editor.webView.isFlipped ? 20 : bounds.height - 20), to: nil)
        // Deliver a real content click, then press the first command as DOM focus arrives.
        for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let click = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: number + 1, clickCount: 1, pressure: 1))
            NSApp.sendEvent(click)
        }
        _ = try await editor.webView.callAsyncJavaScript("""
        if (!document.hasFocus()) {
          await new Promise((resolve, reject) => {
            const timeout = setTimeout(() => reject(new Error('Content did not gain focus')), 5000);
            document.addEventListener('focus', () => {
              clearTimeout(timeout);
              resolve();
            }, {capture: true, once: true});
          });
        }
        return true;
        """, arguments: [:], in: nil, contentWorld: .page)
        for (characters, flags, code) in [("\u{f701}", NSEvent.ModifierFlags.command, UInt16(125)), (" ", [], 49), ("q", [], 12)] {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: code))
            NSApp.sendEvent(key)
            // Leave the caret-only command observable before subsequent typing.
            if code == 125 { try await Task.sleep(for: .milliseconds(40)) }
            await Task.yield()
        }
        let trusted = try await editor.webView.evaluateJavaScript("window.padClickWitness") as? [Bool]
        try #require(trusted == [true], "The native click must reach the actual content surface")
        let refreshDeadline = ContinuousClock.now + .seconds(15)
        while document.isBusy || !editor.isReady, ContinuousClock.now < refreshDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!document.isBusy && editor.isReady)
        var finalSource = try await editor.snapshot()
        let inputDeadline = ContinuousClock.now + .seconds(5)
        while finalSource != "Background document q", ContinuousClock.now < inputDeadline {
            try await Task.sleep(for: .milliseconds(20))
            finalSource = try await editor.snapshot()
        }
        let deliveredKeys = try await editor.webView.evaluateJavaScript("window.padKeyWitness") as? [[String: Any]]
        #expect(deliveredKeys?.compactMap { $0["key"] as? String } == ["ArrowDown", " ", "q"])
        #expect(deliveredKeys?.allSatisfy { $0["trusted"] as? Bool == true } == true)
        #expect(finalSource == "Background document q")
        #expect(editor.ownsFirstResponder)
    }

    @Test(arguments: [false, true])
    func initialReadingLoadRejectsAutomaticEditorFocusButKeepsNativeFields(nativeField: Bool) async throws {
        let suite = "pad-reading-handoff-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set(false, forKey: "pad.saveAutomatically")
        let folder = FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appending(path: "First.md")
        let second = folder.appending(path: "Second.md")
        try "First document".write(to: first, atomically: true, encoding: .utf8)
        let source = "Second **document**"
        try source.write(to: second, atomically: true, encoding: .utf8)
        let document = PadDocument(defaults: defaults, defaultFolder: folder, presentAlert: AlertRecorder().present)
        try #require(document.openDocument(first))
        let window = try #require(document.nativeWindow)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while document.markdownEditor == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try #require(document.markdownEditor)
        try await ready(editor)
        try #require(window.isKeyWindow)
        let host = try #require(window.contentView)
        let content = NSView(frame: host.frame)
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        content.addSubview(field)
        window.contentView = content
        try #require(document.openDocument(second))
        try #require(!editor.isReady)
        // AppKit can choose the native WebKit view while its new document is loading.
        // Neither responder change below is a content click or a composition request.
        try #require(window.makeFirstResponder(nativeField ? field : editor.webView))
        let fieldResponder = window.firstResponder
        _ = try await editor.snapshot()
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: "q", charactersIgnoringModifiers: "q",
                                              isARepeat: false, keyCode: 12))
        NSApp.sendEvent(key)
        #expect(try await editor.snapshot() == nil)
        #expect(!editor.ownsFirstResponder)
        if nativeField {
            #expect(field.stringValue == "q")
            #expect(window.firstResponder === fieldResponder)
        } else {
            #expect(window.firstResponder === window)
        }
        // A same-document reload retains intentionally requested editing focus.
        editor.focus()
        _ = try await editor.snapshot()
        editor.reload(source, documentID: document.documentID)
        _ = try await editor.snapshot()
        #expect(editor.ownsFirstResponder)
    }

    @Test func plainPasteCommandRespectsNativeFieldOwnership() async throws {
        let previous = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let bytes = item.data(forType: type) { copy.setData(bytes, forType: type) }
            }
            return copy
        }
        defer {
            NSPasteboard.general.clearContents()
            if !previous.isEmpty { NSPasteboard.general.writeObjects(previous) }
        }
        let suite = "pad-plain-paste-owner-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set(false, forKey: "pad.saveAutomatically")
        let document = PadDocument(defaults: defaults, presentsWindow: false)
        document.text = "Preserved document"
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
        }
        window.makeKeyAndOrderFront(nil)
        try await ready(editor)
        try #require(window.isKeyWindow)
        try #require(window.makeFirstResponder(field))
        let responder = window.firstResponder
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("**native field**", forType: .string)
        // This is the custom menu's action, with a native field as first responder.
        document.pasteAsPlainText()
        #expect(try await editor.snapshot() == nil)
        #expect(field.stringValue == "**native field**")
        #expect(window.firstResponder === responder)
        #expect(!editor.ownsFirstResponder)
        editor.focus()
        _ = try await editor.snapshot()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("**editor literal**", forType: .string)
        document.pasteAsPlainText()
        #expect(try await editor.snapshot()?.contains("\\*\\*editor literal\\*\\*") == true)
        #expect(field.stringValue == "**native field**")
        #expect(editor.ownsFirstResponder)
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

    @Test func refusedEditReachesTheAppAndLeavesTheEditorUsable() async throws {
        let editor = PadMarkdownEditorController()
        editor.load("Keep this text\n", documentID: UUID())
        _ = try await editor.snapshot()
        var received: [PadMarkdownEditorFeedback] = []
        editor.onFeedback = { feedback, _ in received.append(feedback) }

        // InkKit refuses an edit while text composition is active.
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.ProseMirror').dispatchEvent(new CompositionEvent('compositionstart', {bubbles:true})); true")
        editor.pasteAsPlainText("typed")
        let deadline = ContinuousClock.now + .seconds(5)
        while received.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.ProseMirror').dispatchEvent(new CompositionEvent('compositionend', {bubbles:true})); true")

        let refusal = try #require(received.first)
        #expect(refusal.code == "composition")
        #expect(refusal.source == .edit)
        #expect(refusal.message.text == "Finish typing, then try again.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(received.count == 1)
        #expect(editor.isReady)
        #expect(try await editor.snapshot() == nil)
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

    @Test func readingWidthCentersTheWritingColumn() async throws {
        let editor = PadMarkdownEditorController()
        editor.webView.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        editor.load("Short paragraph\n", documentID: UUID())
        _ = try await editor.snapshot()
        let script = """
            (() => {
                const surface = document.querySelector('.ProseMirror');
                const column = document.getElementById('editor').clientWidth;
                return {left: parseFloat(getComputedStyle(surface).paddingLeft), column};
            })()
            """
        editor.setReadingWidth(400)
        let narrow = try #require(try await editor.webView.evaluateJavaScript(script) as? [String: Any])
        let column = try #require(narrow["column"] as? Double)
        #expect(abs(try #require(narrow["left"] as? Double) - ((column - 400) / 2 + 16)) < 0.5)
        editor.setReadingWidth(nil)
        let full = try #require(try await editor.webView.evaluateJavaScript(script) as? [String: Any])
        #expect(full["left"] as? Double == 16)
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

    @Test func recoverableWarningsAreScopedAndDoNotDisableSnapshots() async throws {
        let editor = PadMarkdownEditorController()
        var feedback: [PadMarkdownEditorFeedback] = []
        editor.onFeedback = { value, _ in feedback.append(value) }
        let id = UUID()
        editor.load("Keep this text\n", documentID: id)
        _ = try await editor.snapshot()
        _ = try await editor.webView.evaluateJavaScript("""
        for (const scope of [
          {documentId:'old-document', generation:1},
          {documentId:'\(id.uuidString)', generation:0},
          {documentId:'\(id.uuidString)', generation:1}
        ]) webkit.messageHandlers.host.postMessage({type:'editorWarning', code:'preservation', source:'edit', ...scope});
        true
        """)
        for _ in 0..<100 {
            if !feedback.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(feedback == [PadMarkdownEditorFeedback(code: "preservation", source: .edit)])
        #expect(editor.isReady)
        #expect(try await editor.snapshot() == nil)

        var changes: [String] = []
        editor.onChanged = { text, _ in changes.append(text) }
        _ = try await editor.webView.evaluateJavaScript("""
        for (const scope of [
          {documentId:'old-document', generation:1},
          {documentId:'\(id.uuidString)', generation:0},
          {documentId:'\(id.uuidString)', generation:1}
        ]) webkit.messageHandlers.host.postMessage({type:'changed', markdown:'Accepted', ...scope});
        true
        """)
        for _ in 0..<100 {
            if !changes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(changes == ["Accepted"])
    }

    @Test func editingClearsOnlyRecoverableEditFeedbackAndDismissalKeepsText() async throws {
        let suite = "pad-feedback-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set("md", forKey: "pad.format")
        defaults.set(false, forKey: "pad.saveAutomatically")
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = PadDocument(defaults: defaults, presentsWindow: false)
        document.text = "Keep this text\n"
        document.mountMarkdownEditor()
        let editor = try #require(document.markdownEditor)
        _ = try await editor.snapshot()
        let warning = PadMarkdownEditorFeedback(code: "preservation", source: .edit)
        editor.onFeedback(warning, document.documentID)
        #expect(document.editorFeedback == warning)
        #expect(document.error == nil)
        #expect(warning.message.text == "That edit isn’t possible here. Nothing changed.")

        // A failed save snapshot remains actionable even after editing recovers.
        let snapshot = document.editorSnapshot
        document.editorSnapshot = { throw PadMarkdownEditorError.unavailable }
        document.save()
        for _ in 0..<100 {
            if !document.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        document.editorSnapshot = snapshot
        let saveError = try #require(document.error)
        _ = try await editor.webView.evaluateJavaScript("window.editor.insertText('Later edit ', 1)")
        for _ in 0..<100 {
            if document.editorFeedback == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(document.editorFeedback == nil)
        #expect(document.error == saveError)
        #expect(document.text.contains("Later edit"))

        let exportWarning = PadMarkdownEditorFeedback(code: "diagram-unavailable", source: .clipboard)
        editor.onFeedback(exportWarning, document.documentID)
        _ = try await editor.webView.evaluateJavaScript("window.editor.insertText('More ', 1)")
        _ = try await editor.snapshot()
        #expect(document.editorFeedback == exportWarning)
        let retained = document.text
        // The pill shows the document error first, so the first click dismisses it and reveals the feedback.
        document.dismissMessage()
        #expect(document.error == nil)
        #expect(document.editorFeedback == exportWarning)
        document.dismissMessage()
        #expect(document.editorFeedback == nil)
        #expect(document.text == retained)
        editor.onFeedback(warning, UUID())
        #expect(document.editorFeedback == nil)

        editor.onFeedback(warning, document.documentID)
        await document.toggleFormat()
        #expect(document.currentFormat == .txt)
        #expect(document.editorFeedback == nil)
        editor.onFeedback(warning, document.documentID)
        #expect(document.editorFeedback == nil)
    }

    @Test(arguments: [false, true])
    func feedbackAppearanceAndDismissalRestoreNativeTyping(dark: Bool) async throws {
        let suite = "pad-feedback-appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set("md", forKey: "pad.format")
        defaults.set(false, forKey: "pad.saveAutomatically")
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let document = PadDocument(defaults: defaults, presentAlert: AlertRecorder().present)
        document.newFile()
        let window = try #require(document.nativeWindow)
        defer {
            NSApp.appearance = previousAppearance
            document.editorSnapshot = nil
            window.orderOut(nil)
            window.contentView = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while document.markdownEditor?.isReady != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try #require(document.markdownEditor)
        try await ready(editor)
        editor.onFeedback(PadMarkdownEditorFeedback(code: "preservation", source: .edit), document.documentID)
        let content = try #require(window.contentView)
        // SwiftUI redraws the newly published feedback on the next run-loop turn.
        try await Task.sleep(for: .milliseconds(100))
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let screenshot = try #require(bitmap.representation(using: .png, properties: [:]))
        let screenshotName = dark ? "editor-feedback-dark.png" : "editor-feedback-light.png"
        Attachment.record(screenshot, named: screenshotName)
        window.makeFirstResponder(window)
        #expect(!editor.ownsFirstResponder)
        document.dismissMessage()
        #expect(document.editorFeedback == nil)
        let focusDeadline = ContinuousClock.now + .seconds(5)
        while !editor.ownsFirstResponder, ContinuousClock.now < focusDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(editor.ownsFirstResponder)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        NSApp.sendEvent(key)
        #expect(try await editor.snapshot()?.trimmingCharacters(in: .newlines) == "q")
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
            #expect(editor.formatAvailability["heading\(level)"] == true)
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

    @Test func bufferedTypingKeepsInkKitSmartPunctuationDisabled() async throws {
        let editor = PadMarkdownEditorController()
        editor.load("", documentID: UUID())
        _ = try await editor.snapshot()
        let text = "\"plain\" -- ..."
        let encoded = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        // Send each character through the public typing facade, which applies
        // InkKit's input rules without involving macOS text substitutions.
        _ = try await editor.webView.evaluateJavaScript("""
        for (const character of \(encoded)) window.editor.insertText(character, 1);
        true
        """)
        #expect(try await editor.snapshot() == text + "\n")
    }

    @Test(arguments: ["Find", "Replace", "Link URL"])
    func editorKeyEquivalentsDoNotStealNativeFieldInput(fieldName: String) async throws {
        let editor = PadMarkdownEditorController()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        editor.webView.frame = NSRect(x: 0, y: 60, width: 600, height: 400)
        content.addSubview(editor.webView)
        let field = NSTextField(frame: NSRect(x: 20, y: 15, width: 300, height: 24))
        field.placeholderString = fieldName
        field.stringValue = "Native field"
        content.addSubview(field)
        window.contentView = content
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        editor.load("First\n\nSecond", documentID: UUID())
        try await ready(editor)
        editor.focus()
        _ = try await editor.snapshot()
        field.selectText(nil)
        try #require(window.firstResponder is NSTextView)
        #expect(!editor.ownsFirstResponder)
        #expect(!editor.canPerformMenuCommands)
        for (key, code, modifiers) in [("\u{f700}", UInt16(126), NSEvent.ModifierFlags.option),
                                       ("\u{f701}", 125, .option), ("b", 11, .command), ("z", 6, .command)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(!editor.webView.performKeyEquivalent(with: event))
        }
        #expect(try await editor.webView.evaluateJavaScript("window.editor.snapshot(1).text") as? String == "First\n\nSecond")
        #expect(field.stringValue == "Native field")
    }

    @Test(arguments: [false, true])
    func linkPopoverUsesSelectionGeometryAndPreservesSource(nearBottom: Bool) async throws {
        let suite = "pad-link-geometry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set(false, forKey: "pad.saveAutomatically")
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        let document = PadDocument(defaults: defaults, presentAlert: AlertRecorder().present)
        document.newFile()
        let window = try #require(document.nativeWindow)
        window.setContentSize(NSSize(width: 520, height: 320))
        defer {
            document.editorSnapshot = nil
            window.orderOut(nil); window.contentView = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let source = (nearBottom ? "One\n\nTwo\n\nThree\n\nFour\n\n" : "") + "Select café 🌍\r\n"
        document.text = source
        document.mountMarkdownEditor()
        let editor = try #require(document.markdownEditor)
        editor.load(source, documentID: document.documentID)
        try await ready(editor)
        editor.presentLink()
        let deadline = ContinuousClock.now + .seconds(5)
        while !editor.showingLink, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(editor.showingLink)
        let rect = try #require(editor.linkRect)
        #expect(rect.height > 0)
        #expect(rect.minY >= 0 && rect.maxY <= editor.webView.bounds.height)
        #expect(try await editor.webView.evaluateJavaScript("window.editor.snapshot().text") as? String == source)
        if ProcessInfo.processInfo.environment["PAD_QA_OUTPUT"] != nil {
            try await Task.sleep(for: .milliseconds(400))
            for (index, capturedWindow) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
                guard let content = capturedWindow.contentView,
                      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                Attachment.record(data, named: "link-\(nearBottom ? "bottom" : "top")-window-\(index).png")
                if capturedWindow !== window, let screen = capturedWindow.screen {
                    #expect(screen.visibleFrame.contains(capturedWindow.frame))
                }
            }
        }
        editor.showingLink = false
    }

    @Test(arguments: [false, true])
    func problemsKeepNativeWindowBoundsAndRecoveryText(fileWindow: Bool) async throws {
        let suite = "pad-problem-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "pad.onboardingCompleted")
        defaults.set(false, forKey: "pad.saveAutomatically")
        let file = FileManager.default.temporaryDirectory.appending(path: "\(suite).md")
        try "A few things to keep\n\nA thought for later.\n".write(to: file, atomically: true, encoding: .utf8)
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        let alerts = AlertRecorder()
        let document = PadDocument(defaults: defaults, role: fileWindow ? .file : .quickPad, presentAlert: alerts.present)
        #expect(document.openDocument(file))
        let window = try #require(document.nativeWindow)
        window.setContentSize(NSSize(width: 520, height: 320))
        document.mountMarkdownEditor()
        let editor = try #require(document.markdownEditor)
        try await ready(editor)
        defer {
            document.editorSnapshot = nil
            window.orderOut(nil); window.contentView = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        try await Task.sleep(for: .milliseconds(100))
        let frame = window.frame
        let editorHeight = editor.webView.bounds.height
        let retained = "A few things to keep\n\nA thought for later. Unsaved café 🌍\n"
        document.editorSnapshot = { retained }
        try FileManager.default.removeItem(at: file)
        document.refreshIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while alerts.alerts.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // A missing file needs a decision, so it is a sheet on this window and never a panel message.
        #expect(alerts.alerts == [expectedAlert(CocoaError(.fileReadNoSuchFile), during: .read)])
        #expect(alerts.windows.first == window)
        #expect(document.error == nil)
        #expect(!document.isBusy)
        #expect(document.text == retained)
        #expect(document.folderError == nil)

        // A small problem is a pill inside the editor card, so neither the window nor the editor moves.
        #expect(!document.rename(to: "bad/name"))
        #expect(document.error == PadError.invalidName.message())
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.frame == frame)
        #expect(abs(editor.webView.bounds.height - editorHeight) <= 1)
        #expect(!window.isOpaque && window.backgroundColor == .clear)
        if ProcessInfo.processInfo.environment["PAD_QA_OUTPUT"] != nil, let content = window.contentView {
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])),
                              named: "message-\(fileWindow ? "file" : "quick-pad").png")
            let pill = PadMessageView(message: try #require(document.error), identifier: "documentError", dismiss: {})
                .frame(width: 520)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: pill)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let rendered = try #require(NSBitmapImageRep(data: tiff))
            Attachment.record(try #require(rendered.representation(using: .png, properties: [:])),
                              named: "message-content-\(fileWindow ? "file" : "quick-pad").png")
        }
        window.orderOut(nil)
        #expect(!window.isVisible)
        document.show()
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.isVisible)
        #expect(window.frame == frame)
        #expect(document.error != nil)
        #expect(document.text == retained)
        document.dismissMessage()
        #expect(document.error == nil)
        // Focusing the window again rereads the missing file without repeating the alert.
        document.refreshIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(alerts.alerts.count == 1)
        #expect(window.frame == frame)
    }

    private func ready(_ editor: PadMarkdownEditorController) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !editor.isReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(editor.isReady, "The bundled Markdown editor did not become ready")
    }
}
