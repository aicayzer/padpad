import AppKit
import InkKitRTF
import Observation
import WebKit

enum PadMarkdownFormatCommand: String {
    case paragraph, heading, bold, italic, underline, code, codeBlock, quote, bulletList, orderedList, link
    case alignLeft, alignCenter, alignRight, alignJustify
}

enum PadMarkdownEditorError: Error {
    case notReady, documentChanged, invalidResponse, unavailable, composing
    case script(String)
    case snapshotRejected(code: String, message: String)
}

struct PadMarkdownEditorFeedback: Equatable {
    enum Source: String { case edit, clipboard, print }

    let code: String
    let source: Source
}

@MainActor
@Observable
final class PadMarkdownEditorController: NSObject, PadDiagnosticSource {
    var diagnosticScope = UUID()
    @ObservationIgnored weak var diagnostics: PadDiagnostics?
    @ObservationIgnored private var diagnosticsEnabled = false
    private(set) var isReady = false
    private(set) var editingMode = "formatted"
    /// The loaded document's format, as InkKit's command state reports it.
    private(set) var documentFormat: PadFormat = .md
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var canReplace = false
    private(set) var formatAvailability: [String: Bool] = [:]
    private(set) var tableAvailability: [String: Bool] = [:]
    var showingFind = false {
        didSet {
            if showingFind {
                if oldValue, let content = webView.window?.contentView, let field = findField(in: content) {
                    webView.window?.makeFirstResponder(field)
                    field.selectText(nil)
                } else { webView.window?.makeFirstResponder(findInputResponder) }
            } else { findInputResponder.discardEvents() }
        }
    }
    @ObservationIgnored private let findInputResponder = OverlayInputResponder()
    var searchText = ""
    var replacementText = ""
    @ObservationIgnored private var printRenderer: PadPrintRenderer?
    private(set) var activeMarks: Set<String> = []
    var onChanged: (String, UUID) -> Void = { _, _ in }
    var onError: (any Error) -> Void = { _ in }
    var onFeedback: (PadMarkdownEditorFeedback, UUID) -> Void = { _, _ in }
    var onReady: () -> Void = {}
    var accentOverride: NSColor? { didSet { applyAccent() } }
    var allowsFocus = true
    var showingLink = false
    private(set) var linkRect: CGRect?
    var hasExternalMarkedText: () -> Bool = { false }

    @ObservationIgnored var clipboardWriter: (PadClipboardContents) throws -> Void = { try $0.write(to: .general) }
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var editorURL: URL?
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private var readingWidth: Double?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var documentID: UUID?
    @ObservationIgnored private var pendingLoad: (source: String, format: PadFormat, reload: Bool)?
    @ObservationIgnored private var loadedFormat: PadFormat?
    @ObservationIgnored private var failure: (any Error)?
    @ObservationIgnored private var loadTask: Task<Void, any Error>?
    @ObservationIgnored private var pendingEvents: [MarkdownInputBuffer.Input] = []
    @ObservationIgnored private let inputBuffer = MarkdownInputBuffer()
    @ObservationIgnored private var focusTask: Task<Void, any Error>?
    @ObservationIgnored private var focusRevision = 0
    @ObservationIgnored private var hasFocusedDocument = false

    var ownsFirstResponder: Bool {
        guard let responder = webView.window?.firstResponder else { return false }
        if responder === inputBuffer { return true }
        guard let view = responder as? NSView else { return false }
        return view === webView || view.isDescendant(of: webView)
    }

    private var keyboardFocusRevision = 0

    func keyboardFocusDidChange() {
        keyboardFocusRevision &+= 1
        diagnostics?.record(.focus, scope: diagnosticScope, format: documentFormat, generation: generation)
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        diagnosticsEnabled = enabled
        guard pageReady else { return }
        webView.evaluateJavaScript("window.editor.setDiagnosticsEnabled(\(enabled))", completionHandler: nil)
    }

    func diagnosticReport() async -> [String: Any]? {
        guard diagnosticsEnabled, pageReady else { return nil }
        let expectedGeneration = generation
        let result = try? await webView.evaluateJavaScript("window.editor.diagnosticReport()")
        guard diagnosticsEnabled, generation == expectedGeneration, let result else { return nil }
        return PadDiagnosticSanitizer.report(result)
    }

    static func diagnosticCode(_ error: any Error) -> String {
        guard let error = error as? PadMarkdownEditorError else { return "native" }
        switch error {
        case .notReady: return "not-ready"
        case .documentChanged: return "stale-document"
        case .invalidResponse: return "invalid-response"
        case .unavailable: return "unavailable"
        case .composing: return "composition"
        case .script: return "script"
        case .snapshotRejected(let code, _): return PadDiagnosticSanitizer.code(code)
        }
    }

    var canPerformMenuCommands: Bool {
        // AppKit focus is not observable. The panel invalidates this projection
        // whenever its first responder or key-window ownership changes.
        _ = keyboardFocusRevision
        return isReady
            && webView.window?.isKeyWindow == true && ownsFirstResponder
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false
        webView = PadMarkdownWebView(frame: .zero, configuration: configuration)
        super.init()
        inputBuffer.onInput = { [weak self] in
            guard let self else { return }
            self.diagnostics?.record(.buffer, scope: self.diagnosticScope, format: self.documentFormat,
                                     generation: self.generation, count: self.inputBuffer.eventCount)
            self.focus()
        }
        (webView as? PadMarkdownWebView)?.onAttach = { [weak self] in self?.onReady() }
        configuration.userContentController.add(PadMarkdownMessageProxy(target: self), name: "host")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            window.addEventListener('error', event => {
              webkit.messageHandlers.host.postMessage({type:'error', message:String(event.message)})
            });
            window.addEventListener('unhandledrejection', event => {
              webkit.messageHandlers.host.postMessage({type:'error', message:String(event.reason)})
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor") else {
            failure = PadMarkdownEditorError.unavailable
            return
        }
        editorURL = url
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// Loads Markdown source, or the stored JSON of an RTF document (see `PadRichText`).
    func load(_ source: String, format: PadFormat = .md, documentID: UUID) {
        replace(source, format: format, documentID: documentID, reload: false)
    }

    func reload(_ source: String, format: PadFormat = .md, documentID: UUID) {
        replace(source, format: format, documentID: documentID, reload: true)
    }

    private func replace(_ source: String, format: PadFormat, documentID: UUID, reload: Bool) {
        generation += 1
        diagnostics?.record(.load, scope: diagnosticScope, format: format, generation: generation)
        self.documentID = documentID
        activeMarks = []
        canUndo = false
        canRedo = false
        canReplace = false
        formatAvailability = [:]
        tableAvailability = [:]
        showingFind = false
        pendingEvents.removeAll()
        inputBuffer.discardEvents()
        focusTask?.cancel()
        focusTask = nil
        if ownsFirstResponder { webView.window?.makeFirstResponder(inputBuffer) }
        isReady = false
        hasFocusedDocument = false
        pendingLoad = (source, format, reload)
        if pageReady { applyPendingLoad() }
    }

    private func applyPendingLoad() {
        guard let pendingLoad else { return }
        self.pendingLoad = nil
        let expectedGeneration = generation
        // Plain text drafts keep their source in the editor as Markdown, ready for a switch back.
        let format = pendingLoad.format == .rtf ? PadFormat.rtf : .md
        // A reload keeps the selection within one format; a different format is a new load.
        let function = pendingLoad.reload && loadedFormat == format ? "reload" : "load"
        let source = format == .rtf ? PadRichText.json(for: pendingLoad.source) : pendingLoad.source
        let script = "window.editor.\(function)(\(json(source)), \(expectedGeneration), \(json(documentID?.uuidString ?? "")), \(json(format.rawValue)))"
        loadedFormat = nil
        loadTask = Task { @MainActor [weak self] in
            guard let self else { throw PadMarkdownEditorError.unavailable }
            do {
                guard self.generation == expectedGeneration else { throw PadMarkdownEditorError.documentChanged }
                _ = try await self.webView.evaluateJavaScript(script)
                guard self.generation == expectedGeneration else { throw PadMarkdownEditorError.documentChanged }
                self.loadedFormat = format
                self.failure = nil
                self.isReady = true
                self.onReady()

            } catch {
                if self.generation == expectedGeneration { self.report(error) }
                throw error
            }
        }
    }

    /// A nil result means the loaded source is unchanged, preserving its original formatting.
    /// An RTF snapshot returns the document's stored JSON (see `PadRichText`).
    func snapshot() async throws -> String? {
        let expectedGeneration = generation
        let deadline = ContinuousClock.now + .seconds(15)
        while !pageReady, failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        }
        if let loadTask { try await loadTask.value }
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        if let failure { throw failure }
        guard isReady else { throw PadMarkdownEditorError.notReady }
        guard !inputBuffer.isComposing, !hasExternalMarkedText() else { throw PadMarkdownEditorError.composing }
        if !pendingEvents.isEmpty || inputBuffer.eventCount > 0 {
            guard webView.window?.isKeyWindow == true, allowsFocus else {
                throw PadMarkdownEditorError.notReady
            }
            focus()
        }
        if let focusTask { try await focusTask.value }
        guard !inputBuffer.isComposing, !hasExternalMarkedText() else { throw PadMarkdownEditorError.composing }
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        let result = try await webView.evaluateJavaScript("window.editor.snapshot(\(expectedGeneration))")
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        guard let payload = result as? [String: Any] else { throw PadMarkdownEditorError.invalidResponse }
        if let code = payload["snapshotError"] as? String {
            diagnostics?.record(.refusal, scope: diagnosticScope, format: documentFormat, generation: generation,
                                code: code, reason: payload["reason"] as? String)
            diagnostics?.captureIncident(from: self)
            guard let message = payload["message"] as? String else { throw PadMarkdownEditorError.invalidResponse }
            switch code {
            case "not-ready", "stale-document", "composition", "operation-pending", "preservation":
                throw PadMarkdownEditorError.snapshotRejected(code: code, message: message)
            default:
                let error = PadMarkdownEditorError.script(message)
                report(error)
                throw error
            }
        }
        guard payload["generation"] as? Int == expectedGeneration,
              payload["documentId"] as? String == documentID?.uuidString,
              let format = loadedFormat, payload["format"] as? String == format.rawValue,
              payload["revision"] is Int,
              let dirty = payload["dirty"] as? Bool else { throw PadMarkdownEditorError.invalidResponse }
        guard let content = Self.content(of: payload, format: format) else { throw PadMarkdownEditorError.invalidResponse }
        return dirty ? content : nil
    }

    /// Markdown carries its `text`; RTF carries its `document` as JSON text, stored in canonical form.
    private static func content(of payload: [String: Any], format: PadFormat) -> String? {
        if format == .rtf {
            guard payload["text"] == nil, let document = payload["document"] as? String else { return nil }
            return try? PadRichText.canonicalText(json: document)
        }
        guard payload["document"] == nil else { return nil }
        return payload["text"] as? String
    }

    /// Converts the current document with InkKit, for a switch or Save As between Markdown and RTF.
    /// The editor is unchanged; the caller loads the result as a new generation once the person confirms.
    func convert(to target: PadFormat) async throws -> PadConversion {
        let expectedGeneration = generation
        _ = try await snapshot()
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        let result = try await webView.evaluateJavaScript("window.editor.convert(\(json(target.rawValue)), \(expectedGeneration))")
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        guard let payload = result as? [String: Any] else { throw PadMarkdownEditorError.invalidResponse }
        if let code = payload["snapshotError"] as? String {
            throw PadMarkdownEditorError.snapshotRejected(code: code, message: payload["message"] as? String ?? "")
        }
        guard payload["format"] as? String == target.rawValue,
              let text = Self.content(of: payload, format: target),
              let lost = payload["lost"] as? [[String: Any]] else { throw PadMarkdownEditorError.invalidResponse }
        let codes = try lost.map { entry in
            guard let code = entry["code"] as? String else { throw PadMarkdownEditorError.invalidResponse }
            return code
        }
        return PadConversion(text: text, changes: PadFormatLoss.changes(for: codes))
    }

    func clipboardSnapshot() async throws -> PadClipboardContents {
        let expectedGeneration = generation
        _ = try await snapshot()
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        let result = try await webView.callAsyncJavaScript("return await window.editor.clipboard(\(expectedGeneration))", arguments: [:], in: nil, contentWorld: .page)
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        guard let payload = result as? [String: Any],
              let text = payload["text"] as? String,
              let html = payload["html"] as? String else { throw PadMarkdownEditorError.invalidResponse }
        return PadClipboardContents(text: text, html: html)
    }

    func focus() {
        guard allowsFocus, isReady, let window = webView.window, window.isKeyWindow,
              focusTask == nil, !inputBuffer.isComposing else { return }
        inputBuffer.attach(to: window)
        if hasFocusedDocument, pendingEvents.isEmpty, inputBuffer.eventCount == 0,
           let responder = window.firstResponder as? NSView, !(responder is MarkdownInputBuffer),
           responder === webView || responder.isDescendant(of: webView) {
            // Refocusing the same editor must not disturb native marked text or dead keys.
            call("focus")
            return
        }
        // Do not admit live WebKit keystrokes ahead of the ones waiting for DOM focus.
        // The temporary responder keeps both queues ordered across the asynchronous handoff.
        window.makeFirstResponder(inputBuffer)
        let expectedGeneration = generation
        focusRevision += 1
        let expectedFocusRevision = focusRevision
        focusTask = Task { @MainActor [weak self, weak window] in
            guard let self else { throw PadMarkdownEditorError.unavailable }
            defer {
                if self.generation == expectedGeneration, self.focusRevision == expectedFocusRevision {
                    self.focusTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                guard self.generation == expectedGeneration else { throw PadMarkdownEditorError.documentChanged }
                guard let window, window.isKeyWindow, self.ownsFirstResponder else {
                    throw CancellationError()
                }
                try await self.drainPendingEvents(window: window, generation: expectedGeneration)
            } catch {
                if self.generation == expectedGeneration, !(error is CancellationError) { self.report(error) }
                throw error
            }
        }
    }

    func contentWasClicked() {
        guard isReady, focusTask == nil, pendingEvents.isEmpty,
              inputBuffer.eventCount == 0, !inputBuffer.isComposing else { return }
        hasFocusedDocument = true
    }

    func capturePendingInput(_ event: NSEvent) -> Bool {
        guard ownsFirstResponder, (!hasFocusedDocument || focusTask != nil), event.type == .keyDown,
              let window = webView.window else { return false }
        // A mounted WebKit view can receive keys before its editable DOM has focus.
        inputBuffer.attach(to: window)
        guard window.makeFirstResponder(inputBuffer) else { return false }
        inputBuffer.keyDown(with: event)
        return true
    }

    func enqueue(_ events: [NSEvent]) {
        guard let window = webView.window else { return }
        inputBuffer.attach(to: window)
        window.makeFirstResponder(inputBuffer)
        for event in events { inputBuffer.keyDown(with: event) }
        focus()
    }

    func enqueueInputs(_ inputs: [MarkdownInputBuffer.Input]) {
        diagnostics?.record(.buffer, scope: diagnosticScope, format: documentFormat, generation: generation, count: inputs.count)
        pendingEvents.append(contentsOf: inputs)
        focus()
    }

    private func drainPendingEvents(window: NSWindow, generation expectedGeneration: Int) async throws {
        while true {
            try Task.checkCancellation()
            guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
            guard window.isKeyWindow, ownsFirstResponder else { throw CancellationError() }
            pendingEvents.append(contentsOf: inputBuffer.takeInputs())
            guard !inputBuffer.isComposing else {
                window.makeFirstResponder(inputBuffer)
                return
            }
            guard !pendingEvents.isEmpty else {
                // Native WebKit focus can restore an old DOM selection. Complete that
                // transition before setting the ProseMirror selection and admitting keys.
                guard window.makeFirstResponder(webView) else { throw PadMarkdownEditorError.notReady }
                _ = try await webView.evaluateJavaScript("window.editor.focus()")
                try Task.checkCancellation()
                guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
                guard window.isKeyWindow, ownsFirstResponder else { throw CancellationError() }
                if inputBuffer.isComposing || inputBuffer.eventCount > 0 { continue }
                hasFocusedDocument = true
                focusTask = nil
                return
            }
            let input = pendingEvents[0]
            switch input {
            case .text(let text):
                let result = try await webView.evaluateJavaScript("window.editor.insertText(\(json(text)), \(expectedGeneration))")
                guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
                if let refusal = commandRefusal(result) {
                    // The editor refused this text and is still usable; tell the person and carry on.
                    pendingEvents.removeFirst()
                    showFeedback(refusal)
                    continue
                }
                guard result as? Bool == true else { throw PadMarkdownEditorError.notReady }
                pendingEvents.removeFirst()
            case .key(let event):
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                   let key = bufferedKey(event) {
                    let flags = event.modifierFlags
                    let input = "{key: \(json(key)), metaKey: \(flags.contains(.command)), ctrlKey: \(flags.contains(.control)), altKey: \(flags.contains(.option)), shiftKey: \(flags.contains(.shift))}"
                    let script = "window.editor.keyDown(\(input), \(expectedGeneration))"
                    let result = try await webView.evaluateJavaScript(script)
                    guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
                    if let refusal = commandRefusal(result) {
                        pendingEvents.removeFirst()
                        showFeedback(refusal)
                        continue
                    }
                    if result as? Bool == true {
                        pendingEvents.removeFirst()
                        continue
                    }
                }
                // App commands leave the input bridge before their document operation snapshots.
                pendingEvents.removeFirst()
                hasFocusedDocument = true
                focusTask = nil
                window.makeFirstResponder(webView)
                window.sendEvent(event)
                if !pendingEvents.isEmpty || inputBuffer.eventCount > 0 { focus() }
                return
            }
        }
    }

    private func bufferedKey(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76: return "Enter"
        case 51: return "Backspace"
        case 117: return "Delete"
        case 48: return "Tab"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        default: return event.charactersIgnoringModifiers
        }
    }

    private func findField(in view: NSView) -> OverlayTextField? {
        if let field = view as? OverlayTextField, field.placeholderString == "Find" { return field }
        for child in view.subviews {
            if let field = findField(in: child) { return field }
        }
        return nil
    }

    func setEditingMode(_ mode: String) {
        guard isReady else { return }
        call("setEditingMode", json(mode), json(generation))
    }

    func undo() { guard canUndo else { return }; call("undo", json(generation)) }
    func redo() { guard canRedo else { return }; call("redo", json(generation)) }
    func find() { guard isReady else { return }; call("find", json(searchText), json(generation)) }
    func replace(all: Bool) {
        guard canReplace, !searchText.isEmpty else { return }
        call(all ? "replaceAll" : "replace", json(searchText), json(replacementText), json(generation))
    }

    func printDocument() async throws {
        guard printRenderer == nil else { return }
        let expectedGeneration = generation
        _ = try await snapshot()
        let result = try await webView.callAsyncJavaScript("return await window.editor.printable(generation)",
            arguments: ["generation": expectedGeneration], in: nil, contentWorld: .page)
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        if let payload = result as? [String: Any], let code = payload["snapshotError"] as? String {
            throw PadMarkdownEditorError.snapshotRejected(code: code, message: payload["message"] as? String ?? "Couldn’t prepare printing.")
        }
        guard let payload = result as? [String: Any],
              payload["generation"] as? Int == expectedGeneration,
              payload["documentId"] as? String == documentID?.uuidString,
              let revision = payload["revision"] as? Int, payload["format"] as? String == loadedFormat?.rawValue,
              let html = payload["html"] as? String, payload["styles"] is String,
              payload["assetCount"] is Int, payload["warnings"] is [Any] else {
            throw PadMarkdownEditorError.invalidResponse
        }
        let renderer = PadPrintRenderer()
        printRenderer = renderer
        defer { printRenderer = nil }
        try await renderer.loadHTML(html)
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        let current = try await webView.evaluateJavaScript("window.editor.snapshot(\(expectedGeneration))") as? [String: Any]
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        try PadPrintScope(documentID: documentID?.uuidString ?? "", generation: expectedGeneration, revision: revision).validate(current)
        if let warnings = payload["warnings"] as? [[String: Any]], !warnings.isEmpty {
            showFeedback(PadMarkdownEditorFeedback(code: "export-degraded", source: .print))
        }
        guard let window = webView.window else { throw PadMarkdownEditorError.documentChanged }
        _ = await renderer.printDocument(in: window)
    }

    func table(_ command: String) {
        guard isReady, tableAvailability[command] == true else { return }
        call("table", json(command), json(generation))
        focus()
    }

    func pasteAsPlainText(_ text: String) {
        guard isReady else { return }
        call("pasteAsPlainText", json(text), json(generation))
        focus()
    }

    func presentLink() {
        guard isReady, formatAvailability["link"] == true else { return }
        let expectedGeneration = generation
        webView.evaluateJavaScript("window.editor.linkContext(\(expectedGeneration))") { [weak self] value, error in
            guard let self, self.generation == expectedGeneration else { return }
            if let error { self.report(error); return }
            let context = value as? [String: Any]
            if let rect = context?["rect"] as? [String: Double],
               let left = rect["left"], let top = rect["top"],
               let width = rect["width"], let height = rect["height"] {
                self.linkRect = CGRect(x: left, y: top, width: max(1, width), height: max(1, height))
            } else {
                self.linkRect = nil
            }
            self.showingLink = true
        }
    }

    func format(_ command: PadMarkdownFormatCommand, argument: String? = nil) {
        // InkKit names each heading level; a link takes its destination as an option.
        let name = command == .heading ? "heading\(argument ?? "")" : command.rawValue
        guard isReady, formatAvailability[name] == true else { return }
        let options = command == .link ? argument.map { json(["destination": $0]) } : nil
        call("format", json(name), options ?? "null", json(generation))
        focus()
    }

    private func call(_ function: String, _ arguments: String...) {
        let expectedGeneration = generation
        webView.evaluateJavaScript("window.editor.\(function)(\(arguments.joined(separator: ",")))") { [weak self] result, error in
            guard let self, expectedGeneration == self.generation else { return }
            if let refusal = self.commandRefusal(result) {
                self.showFeedback(refusal)
            } else if let error { self.report(error) }
        }
    }

    /// The bridge answers an edit that InkKit refused with `commandError`; the editor stays usable.
    private func commandRefusal(_ result: Any?) -> PadMarkdownEditorFeedback? {
        guard let payload = result as? [String: Any], let code = payload["commandError"] as? String else { return nil }
        diagnostics?.record(.refusal, scope: diagnosticScope, format: documentFormat, generation: generation,
                            code: code, reason: payload["reason"] as? String)
        diagnostics?.captureIncident(from: self)
        return PadMarkdownEditorFeedback(code: code, source: .edit)
    }

    private func json(_ value: some Encodable) -> String {
        // Encoding a string cannot fail; JSON escaping keeps document text out of executable code.
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    /// Width of the complete writing column, including its existing page margins.
    /// Applying layout never reloads the document or changes its source or selection.
    func setReadingWidth(_ width: Double?) {
        let sanitized = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard sanitized != readingWidth else { return }
        readingWidth = sanitized
        applyReadingWidth()
    }

    private func applyReadingWidth() {
        guard pageReady else { return }
        call("setReadingWidth", readingWidth.map { json($0) } ?? "null")
    }

    private func applyAccent() {
        guard pageReady else { return }
        webView.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let color = (accentOverride ?? NSColor.controlAccentColor).usingColorSpace(.sRGB) else { return }
            let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
            let hex = String(format: "#%02X%02X%02X", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
            call("setAccent", json(hex))
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            setDiagnosticsEnabled(diagnosticsEnabled)
            applyAccent()
            applyReadingWidth()
            call("setKeymap", json([
                "bold": ["Mod-b"], "italic": ["Mod-i"], "underline": ["Mod-u"], "code": ["Mod-e"],
                "heading1": ["Mod-Alt-1"], "heading2": ["Mod-Alt-2"],
                "heading3": ["Mod-Alt-3"], "paragraph": ["Mod-Alt-0"],
                "quote": ["Mod-Shift-b"], "bulletList": ["Mod-Alt-8"],
                "orderedList": ["Mod-Alt-7"], "codeBlock": ["Mod-Alt-c"],
            ]))
            applyPendingLoad()
        case "changed":
            guard let receivedGeneration = message["generation"] as? Int, receivedGeneration == generation,
                  let documentID, message["documentId"] as? String == documentID.uuidString,
                  let format = loadedFormat, message["format"] as? String == format.rawValue,
                  let content = Self.content(of: message, format: format) else { return }
            onChanged(content, documentID)
        case "commands":
            guard message["generation"] as? Int == generation,
                  message["documentId"] as? String == documentID?.uuidString,
                  let commands = message["commands"] as? [String: Any],
                  let mode = message["mode"] as? String else { return }
            editingMode = mode
            if let format = (message["format"] as? String).flatMap(PadFormat.init(rawValue:)) { documentFormat = format }
            canUndo = commands["undo"] as? Bool ?? false
            canRedo = commands["redo"] as? Bool ?? false
            canReplace = commands["replace"] as? Bool ?? false
            formatAvailability = commands["format"] as? [String: Bool] ?? [:]
            tableAvailability = commands["table"] as? [String: Bool] ?? [:]
            let caret = message["caret"] as? [String: Any] ?? [:]
            var active = Set(caret["marks"] as? [String] ?? [])
            if let block = caret["block"] as? [String: Any], let type = block["type"] as? String,
               type != "paragraph" {
                active.insert(type)
                if type == "heading", let level = block["level"] as? Int { active.insert("heading\(level)") }
            }
            if caret["quoted"] as? Bool == true { active.insert("quote") }
            if let align = caret["align"] as? String { active.insert("align" + align.capitalized) }
            activeMarks = active
        case "openLink":
            guard let href = message["href"] as? String, let url = URL(string: href),
                  let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        case "requestLink":
            presentLink()
        case "writeClipboard":
            guard let requestID = message["requestId"] as? String else { return }
            var response: [String: String] = [:]
            do {
                guard message["generation"] as? Int == generation,
                      message["documentId"] as? String == documentID?.uuidString,
                      let text = message["text"] as? String, let html = message["html"] as? String else {
                    throw PadMarkdownEditorError.documentChanged
                }
                try clipboardWriter(PadClipboardContents(text: text, html: html))
            } catch { response = ["error": error.localizedDescription] }
            call("clipboardResponse", json(requestID), json(response))
        case "copy":
            guard let text = message["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "editorWarning":
            guard message["generation"] as? Int == generation,
                  message["documentId"] as? String == documentID?.uuidString,
                  let code = message["code"] as? String,
                  let rawSource = message["source"] as? String,
                  let source = PadMarkdownEditorFeedback.Source(rawValue: rawSource) else { return }
            diagnostics?.record(.refusal, scope: diagnosticScope, format: documentFormat, generation: generation,
                                code: code, reason: message["reason"] as? String)
            diagnostics?.captureIncident(from: self)
            showFeedback(PadMarkdownEditorFeedback(code: code, source: source))
        case "error":
            report(PadMarkdownEditorError.script(message["message"] as? String ?? "Unknown error"))
        default: break
        }
    }

    private func showFeedback(_ feedback: PadMarkdownEditorFeedback) {
        guard let documentID else { return }
        onFeedback(feedback, documentID)
    }

    private func report(_ error: any Error) {
        diagnostics?.record(.error, scope: diagnosticScope, format: documentFormat, generation: generation,
                            code: Self.diagnosticCode(error))
        diagnostics?.captureIncident(from: self)
        failure = error
        isReady = false
        onError(error)
    }
}

@MainActor
private final class PadMarkdownMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: PadMarkdownEditorController?
    init(target: PadMarkdownEditorController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        target?.receive(message.body)
    }
}

extension PadMarkdownEditorController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == editorURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { report(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { report(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        report(PadMarkdownEditorError.unavailable)
    }
}

@MainActor
private final class PadMarkdownWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit traverses subviews for key equivalents even when a native field
        // owns focus. Only the focused editor may handle its editing shortcuts.
        guard let window, window.isKeyWindow,
              let responder = window.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self) else { return false }
        return super.performKeyEquivalent(with: event)
    }

    var onAttach: () -> Void = {}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach() }
    }
}

@MainActor
final class PadPrintRenderer: NSObject, WKNavigationDelegate {
    private let view: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 900), configuration: configuration)
    }()
    // Retain a window-backed rendering surface without showing the frozen page.
    private let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 720, height: 900),
        styleMask: [.borderless], backing: .buffered, defer: false)
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeout: Task<Void, Never>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    func loadHTML(_ html: String) async throws {
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.view.stopLoading()
                self?.finish(PadMarkdownEditorError.notReady)
            }
            view.loadHTMLString(html, baseURL: nil)
        }
        _ = try await view.callAsyncJavaScript("""
            await Promise.race([
                Promise.all([document.fonts.ready, ...Array.from(document.images, image => image.decode())]),
                new Promise((_, reject) => setTimeout(() => reject(new Error("Print assets timed out")), 15000))
            ]);
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
    }

    func printDocument(in presentingWindow: NSWindow? = nil, printInfo: NSPrintInfo = .shared, showsPanel: Bool = true) async -> Bool {
        let info = printInfo.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        let operation = view.printOperation(with: info)
        operation.showsPrintPanel = showsPanel
        operation.showsProgressPanel = showsPanel
        // WebKit paginates asynchronously, so printing must leave the main thread available.
        operation.canSpawnSeparateThread = true
        return await withCheckedContinuation { continuation in
            printContinuation = continuation
            operation.runModal(for: presentingWindow ?? window, delegate: self,
                didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc nonisolated private func printDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            let continuation = self.printContinuation
            self.printContinuation = nil
            continuation?.resume(returning: success)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(PadMarkdownEditorError.unavailable) }
    private func finish(_ error: (any Error)?) {
        timeout?.cancel()
        timeout = nil
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}

struct PadPrintScope {
    let documentID: String
    let generation: Int
    let revision: Int

    func validate(_ current: [String: Any]?) throws {
        guard current?["generation"] as? Int == generation,
              current?["documentId"] as? String == documentID,
              current?["revision"] as? Int == revision else { throw PadMarkdownEditorError.documentChanged }
    }
}
