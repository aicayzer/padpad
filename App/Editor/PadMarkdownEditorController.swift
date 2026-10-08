import AppKit
import Observation
import WebKit

enum PadMarkdownFormatCommand: String {
    case paragraph, heading, bold, italic, code, codeBlock, quote, bulletList, orderedList, link
}

enum PadMarkdownEditorError: LocalizedError {
    case notReady, documentChanged, invalidResponse, unavailable, composing
    case script(String), warning(String)

    var errorDescription: String? {
        switch self {
        case .composing: "Finish typing before saving or closing."
        case .notReady: "The editor is still loading. Try again in a moment."
        case .documentChanged: "Your text changed. Try again."
        case .invalidResponse: "Couldn’t read your text. Try again."
        case .unavailable: "The editor is unavailable. Your text is still open."
        case .script: "The editor couldn’t complete that action. Your text is still open."
        case .warning(let message): message
        }
    }
}

@MainActor
@Observable
final class PadMarkdownEditorController: NSObject {
    private(set) var isReady = false
    private(set) var activeMarks: Set<String> = []
    var onChanged: (String, UUID) -> Void = { _, _ in }
    var onError: (any Error) -> Void = { _ in }
    var onReady: () -> Void = {}
    var accentOverride: NSColor? { didSet { applyAccent() } }
    var allowsFocus = true
    var showingLink = false
    var hasExternalMarkedText: () -> Bool = { false }

    @ObservationIgnored var clipboardWriter: (PadClipboardContents) throws -> Void = { try $0.write(to: .general) }
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var editorURL: URL?
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private var readingWidth: Double?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var documentID: UUID?
    @ObservationIgnored private var pendingLoad: (markdown: String, reload: Bool)?
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

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false
        webView = PadMarkdownWebView(frame: .zero, configuration: configuration)
        super.init()
        inputBuffer.onInput = { [weak self] in self?.focus() }
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

    func load(_ markdown: String, documentID: UUID) {
        replace(markdown, documentID: documentID, reload: false)
    }

    func reload(_ markdown: String, documentID: UUID) {
        replace(markdown, documentID: documentID, reload: true)
    }

    private func replace(_ markdown: String, documentID: UUID, reload: Bool) {
        generation += 1
        self.documentID = documentID
        activeMarks = []
        pendingEvents.removeAll()
        inputBuffer.discardEvents()
        focusTask?.cancel()
        focusTask = nil
        if ownsFirstResponder { webView.window?.makeFirstResponder(inputBuffer) }
        isReady = false
        hasFocusedDocument = false
        pendingLoad = (markdown, reload)
        if pageReady { applyPendingLoad() }
    }

    private func applyPendingLoad() {
        guard let pendingLoad else { return }
        self.pendingLoad = nil
        let expectedGeneration = generation
        let function = pendingLoad.reload ? "reload" : "load"
        let script = "window.editor.\(function)(\(json(pendingLoad.markdown)), \(expectedGeneration), \(json(documentID?.uuidString ?? "")))"
        loadTask = Task { @MainActor [weak self] in
            guard let self else { throw PadMarkdownEditorError.unavailable }
            do {
                _ = try await self.webView.evaluateJavaScript(script)
                guard self.generation == expectedGeneration else { throw PadMarkdownEditorError.documentChanged }
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
        guard let payload = result as? [String: Any],
              payload["generation"] as? Int == expectedGeneration,
              payload["documentId"] as? String == documentID?.uuidString,
              let markdown = payload["text"] as? String,
              payload["format"] as? String == "md", payload["revision"] is Int,
              let dirty = payload["dirty"] as? Bool else { throw PadMarkdownEditorError.invalidResponse }
        return dirty ? markdown : nil
    }

    func clipboardSnapshot() async throws -> PadClipboardContents {
        let expectedGeneration = generation
        _ = try await snapshot()
        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
        let result = try await webView.callAsyncJavaScript("return await window.editor.clipboard()", arguments: [:], in: nil, contentWorld: .page)
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

    func capturePendingInput(_ event: NSEvent) -> Bool {
        guard (!hasFocusedDocument || focusTask != nil), event.type == .keyDown,
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
                let inserted = try await webView.evaluateJavaScript("window.editor.insertText(\(json(text)), \(expectedGeneration))") as? Bool
                guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
                guard inserted == true else { throw PadMarkdownEditorError.notReady }
                pendingEvents.removeFirst()
            case .key(let event):
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                   let key = bufferedKey(event) {
                    let flags = event.modifierFlags
                    let script = "window.editor.keyDown(\(json(key)), \(json("")), \(flags.contains(.command)), \(flags.contains(.control)), \(flags.contains(.option)), \(flags.contains(.shift)), \(expectedGeneration))"
                    if try await webView.evaluateJavaScript(script) as? Bool == true {
                        guard expectedGeneration == generation else { throw PadMarkdownEditorError.documentChanged }
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

    func table(_ command: String) {
        guard isReady else { return }
        call("table", json(command))
        focus()
    }

    func pasteAsPlainText(_ text: String) {
        guard isReady else { return }
        call("pasteAsPlainText", json(text))
        focus()
    }

    func format(_ command: PadMarkdownFormatCommand, argument: String? = nil) {
        guard isReady else { return }
        call("format", json(command.rawValue), argument.map { json($0) } ?? "null")
        focus()
    }

    private func call(_ function: String, _ arguments: String...) {
        let expectedGeneration = generation
        webView.evaluateJavaScript("window.editor.\(function)(\(arguments.joined(separator: ",")))") { [weak self] _, error in
            guard let self, expectedGeneration == self.generation, let error else { return }
            self.report(error)
        }
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
            applyAccent()
            applyReadingWidth()
            call("setKeymap", json([
                "bold": ["Mod-b"], "italic": ["Mod-i"], "code": ["Mod-e"],
                "heading1": ["Mod-Alt-1"], "heading2": ["Mod-Alt-2"],
                "heading3": ["Mod-Alt-3"], "paragraph": ["Mod-Alt-0"],
                "quote": ["Mod-Shift-b"], "bulletList": ["Mod-Alt-8"],
                "orderedList": ["Mod-Alt-7"], "codeBlock": ["Mod-Alt-c"],
            ]))
            applyPendingLoad()
        case "changed":
            guard let receivedGeneration = message["generation"] as? Int, receivedGeneration == generation,
                  let markdown = message["markdown"] as? String, let documentID else { return }
            onChanged(markdown, documentID)
        case "state":
            guard isReady else { return }
            if let receivedGeneration = message["generation"] as? Int, receivedGeneration != generation { return }
            var active = Set(message["marks"] as? [String] ?? [])
            if let block = message["block"] as? [String: Any], let type = block["type"] as? String,
               type != "paragraph" {
                active.insert(type)
                if type == "heading", let level = block["level"] as? Int { active.insert("heading\(level)") }
            }
            if message["quoted"] as? Bool == true { active.insert("quote") }
            activeMarks = active
        case "openLink":
            guard let href = message["href"] as? String, let url = URL(string: href),
                  let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        case "requestLink":
            showingLink = true
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
            onError(PadMarkdownEditorError.warning(message["message"] as? String ?? "The editor couldn’t complete that action."))
        case "error":
            report(PadMarkdownEditorError.script(message["message"] as? String ?? "Unknown error"))
        default: break
        }
    }

    private func report(_ error: any Error) {
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
    var onAttach: () -> Void = {}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach() }
    }
}
