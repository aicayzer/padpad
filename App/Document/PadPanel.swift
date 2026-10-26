import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

@MainActor
private final class PadShareAnchor {
    weak var view: NSView?
}

private struct PadShareAnchorView: NSViewRepresentable {
    let anchor: PadShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

final class PadPanel: NSPanel, PadDocumentWindow {
    private let files: PadDocument
    private let quit: @MainActor () -> Void
    private var previousFrame: NSRect?
    private var restoreAfterFullScreen = false
    private static let maximumWidth: CGFloat = 1_200
    private var trackingWindowMove = false
    private var snapTrackingTimer: Timer?
    private lazy var snapGuide = PadSnapGuide()
    private let pendingTitleInput = OverlayInputResponder()
    private let pendingEditorInput = MarkdownInputBuffer()
    private var editorFocusScheduled = false

    var pendingEditorEventCount: Int { pendingEditorInput.eventCount }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(files: PadDocument, quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.files = files
        self.quit = quit
        let settings = files.appSettings
        let width = files.isQuickPad ? settings?.quickPadWidth ?? 740 : settings?.fileWindowWidth ?? 800
        let height = files.isQuickPad ? settings?.quickPadHeight ?? 480 : settings?.fileWindowHeight ?? 860
        let mask: NSWindow.StyleMask = files.isQuickPad
            ? [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]
            : [.titled, .closable, .miniaturizable, .resizable]
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: mask,
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = files.isQuickPad && files.floating ? .floating : .normal
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        becomesKeyOnlyIfNeeded = false
        if files.isQuickPad {
            collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                standardWindowButton(button)?.isHidden = true
            }
        } else {
            collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        }
        // AppKit draws outside the window; a SwiftUI shadow gets clipped at the hosting bounds.
        hasShadow = true
        isMovableByWindowBackground = true
        contentView = NSHostingView(rootView: PadView(files: files, prepareTitleFocus: { [weak self] in
            guard let self else { return }
            pendingTitleInput.discardEvents()
            makeFirstResponder(pendingTitleInput)
        }).environment(files.appSettings ?? AppSettings())
            // Hosting derives the native minimum from the content's constraints.
            .frame(minWidth: 520, maxWidth: files.isQuickPad ? Self.maximumWidth : nil, minHeight: 320))
        maxSize = NSSize(width: files.isQuickPad ? Self.maximumWidth : CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude)
        pendingEditorInput.attach(to: self)
        if files.startsInReadingMode { makeFirstResponder(self) }
        pendingEditorInput.onInput = { [weak self] in self?.requestEditorFocus() }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillMove),
                                               name: NSWindow.willMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved),
                                               name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(exitedFullScreen),
                                               name: NSWindow.didExitFullScreenNotification, object: self)
        restoreDefaultSize(animate: false)
        if !files.isQuickPad, let screen = screen ?? NSScreen.main {
            let count = max(0, (files.workspace?.documents.count ?? 1) - 1)
            let offset = CGFloat(count % 6) * 24
            let point = NSPoint(x: frame.minX + offset, y: frame.maxY - offset)
            setFrameTopLeftPoint(point)
            setFrame(constrainFrameRect(frame, to: screen), display: false)
        }
    }

    override func orderOut(_ sender: Any?) {
        endSnapTracking(commit: false)
        super.orderOut(sender)
    }

    @objc private func windowWillMove() {
        guard files.isQuickPad, !styleMask.contains(.fullScreen),
              files.appSettings?.snapQuickPadToCenter != false,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        trackingWindowMove = true
        updateSnapGuide()
        guard snapTrackingTimer == nil else { return }
        // Native window dragging uses the event-tracking run loop. Keep preview
        // and release detection active there as well as after dragging returns.
        let timer = Timer(timeInterval: 1.0 / 60, target: self,
                          selector: #selector(trackSnapDrag), userInfo: nil, repeats: true)
        snapTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    @objc private func windowMoved() {
        if trackingWindowMove { updateSnapGuide() }
    }

    @objc private func trackSnapDrag() {
        guard isVisible, files.appSettings?.snapQuickPadToCenter != false else {
            endSnapTracking(commit: false)
            return
        }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            endSnapTracking(commit: true)
        } else {
            updateSnapGuide()
        }
    }

    private func snapDestination() -> NSRect? {
        // Follow the pointer's display while crossing between screens.
        guard let display = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? screen ?? NSScreen.main else { return nil }
        return PadQuickPadPlacement.frame(size: frame.size, in: display.visibleFrame)
    }

    private func updateSnapGuide() {
        guard let target = snapDestination() else { return }
        snapGuide.show(target: target, near: PadQuickPadPlacement.isNear(frame, target: target), below: self)
    }

    private func endSnapTracking(commit: Bool) {
        let wasTracking = trackingWindowMove
        trackingWindowMove = false
        snapTrackingTimer?.invalidate()
        snapTrackingTimer = nil
        snapGuide.hide()
        guard commit, wasTracking, let target = snapDestination(),
              PadQuickPadPlacement.isNear(frame, target: target) else { return }
        setFrameOrigin(target.origin)
    }

    @objc private func applicationBecameActive() { requestEditorFocus() }

    func requestEditorFocus() {
        guard !files.onboarding.isPresented else { return }
        guard !editorFocusScheduled else { return }
        editorFocusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editorFocusScheduled = false
            guard !self.files.onboarding.isPresented else { return }
            guard self.isKeyWindow, self.isVisible, !self.files.settingsPresented else { return }
            guard !self.files.holdInitialReadingFocus() else { return }
            guard !self.pendingEditorInput.isComposing else { return }
            guard !self.files.startsInReadingMode || self.firstResponder !== self else { return }
            let awaitingEditor = self.firstResponder === self.pendingEditorInput || self.firstResponder === self
            if self.files.currentFormat == .md {
                guard let editor = self.files.markdownEditor else { return }
                // Replacing the document can temporarily buffer input while DOM focus catches up.
                guard awaitingEditor || editor.ownsFirstResponder else { return }
                editor.enqueueInputs(self.pendingEditorInput.takeInputs())
                return
            }
            guard awaitingEditor, let content = self.contentView,
                  let editor = self.editor(in: content), editor.isEditable else { return }
            self.makeFirstResponder(editor)
        }
    }

    func prepareMarkdownSnapshot() {
        guard files.currentFormat == .md, let editor = files.markdownEditor else { return }
        editor.hasExternalMarkedText = { [weak self] in self?.pendingEditorInput.isComposing == true }
        guard !pendingEditorInput.isComposing, pendingEditorInput.eventCount > 0 else { return }
        editor.enqueueInputs(pendingEditorInput.takeInputs())
    }

    func prepareReading() {
        pendingTitleInput.discardEvents()
        pendingEditorInput.discardEvents()
        makeFirstResponder(self)
    }

    func prepareOnboarding() {
        pendingTitleInput.discardEvents()
        pendingEditorInput.discardEvents()
        makeFirstResponder(nil)
    }

    func resumeEditor() {
        guard !files.onboarding.isPresented else { return }
        pendingEditorInput.attach(to: self)
        makeFirstResponder(pendingEditorInput)
        files.isActive = true
        requestEditorFocus()
    }

    private func editor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, !(editor is MarkdownInputBuffer), !editor.isFieldEditor { return editor }
        for child in view.subviews {
            if let editor = editor(in: child) { return editor }
        }
        return nil
    }

    override func sendEvent(_ event: NSEvent) {
        if handleOnboardingNavigation(event) { return }
        if !files.onboarding.isPresented, files.currentFormat == .md, firstResponder !== pendingEditorInput,
           files.markdownEditor?.capturePendingInput(event) == true { return }
        super.sendEvent(event)
        files.acceptMarkdownContentClick(event)
    }

    // Onboarding may be summoned as a nonactivating panel before SwiftUI has a
    // focused control. Handle its navigation here, independently of button focus.
    private func handleOnboardingNavigation(_ event: NSEvent) -> Bool {
        guard files.onboarding.isPresented, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let key = Int(event.keyCode)
        guard [kVK_Return, kVK_LeftArrow, kVK_RightArrow, kVK_Space].contains(key) else { return false }
        guard !event.isARepeat else { return true }
        let shortcut = KeyboardShortcuts.getShortcut(for: .pad)
        // A configured bare navigation key belongs to the real global-shortcut
        // callback. It must never also navigate or finish on its local key-down.
        if shortcut?.modifiers.isEmpty == true,
           (key == kVK_Return && shortcut?.key == .return ||
            key == kVK_LeftArrow && shortcut?.key == .leftArrow ||
            key == kVK_RightArrow && shortcut?.key == .rightArrow ||
            key == kVK_Space && shortcut?.key == .space) { return true }
        switch key {
        case kVK_Space:
            // Editing-style focus keeps Tab navigation available independently of
            // macOS's all-controls preference; Space activates that focused action.
            switch files.onboarding.focusedControl {
            case .close: files.close()
            case .next: files.onboarding.startPractice()
            case .back: files.onboarding.showIntroduction()
            case .skip: files.finishOnboarding(includeExample: false)
            case .done:
                if files.onboarding.practiceCount > 0 { files.finishOnboarding(includeExample: true) }
            case nil: return false
            }
        case kVK_LeftArrow: files.onboarding.showIntroduction()
        case kVK_RightArrow: files.onboarding.startPractice()
        default:
            if files.onboarding.stage == .intro {
                files.onboarding.startPractice()
            } else if files.onboarding.practiceCount > 0 {
                files.finishOnboarding(includeExample: true)
            }
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard files.workspace?.isTransitioning != true else { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let action = files.editingShortcuts.action(for: event) {
            guard !files.onboarding.isPresented else { return true }
            switch action {
            case .newFile: (files.workspace?.quickPad ?? files).commandNew()
            case .open: Task { await files.openPicker() }
            case .save: files.save()
            case .saveAs: Task { await files.saveAs() }
            case .restoreDefaultSize: restoreDefaultSize()
            case .copyAllContents: Task { await files.copyAllContents() }
            }
            return true
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "w": files.close()
            case "r": files.requestRename()
            case ",":
                files.settingsPresented = true
                files.showSettings()
            case "q": quit()
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if files.isQuickPad { files.close() }
        else { super.cancelOperation(sender) }
    }

    override func close() { files.close() }

    func finishClosing() {
        super.close()
    }

    func restoreDefaultSize(animate: Bool = true) {
        let settings = files.appSettings
        let width = files.isQuickPad ? settings?.quickPadWidth ?? 740 : settings?.fileWindowWidth ?? 800
        let height = files.isQuickPad ? settings?.quickPadHeight ?? 480 : settings?.fileWindowHeight ?? 860
        guard let screen = screen ?? NSScreen.main else { return }
        if styleMask.contains(.fullScreen) {
            restoreAfterFullScreen = true
            toggleFullScreen(nil)
            return
        }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(width, visible.width), height: min(height, visible.height))
        previousFrame = nil
        setFrame(NSRect(origin: frame.origin, size: size), display: true, animate: animate)
        if files.isQuickPad {
            setFrameOrigin(PadQuickPadPlacement.frame(size: size, in: screen.visibleFrame).origin)
        } else {
            center()
        }
        setFrame(constrainFrameRect(frame, to: screen), display: true)
    }

    @objc private func exitedFullScreen() {
        guard restoreAfterFullScreen else { return }
        restoreAfterFullScreen = false
        restoreDefaultSize()
    }

    func constrainToAvailableScreen() {
        guard !styleMask.contains(.fullScreen), let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var target = frame
        target.size.width = min(target.width, visible.width)
        target.size.height = min(target.height, visible.height)
        target.origin.x = max(visible.minX, min(target.minX, visible.maxX - target.width))
        target.origin.y = max(visible.minY, min(target.minY, visible.maxY - target.height))
        if target != frame { setFrame(target, display: true) }
    }

    func toggleExpanded() {
        if !files.isQuickPad { zoom(nil); return }
        if let previousFrame {
            setFrame(previousFrame, display: true, animate: true)
            self.previousFrame = nil
        } else if let screen = screen ?? NSScreen.main {
            previousFrame = frame
            var expanded = screen.visibleFrame.insetBy(dx: 24, dy: 24)
            expanded.size.width = min(expanded.width, Self.maximumWidth)
            expanded.origin.x = screen.visibleFrame.midX - expanded.width / 2
            setFrame(expanded, display: true, animate: true)
        }
    }

    override func becomeKey() {
        super.becomeKey()
        files.markdownEditor?.keyboardFocusDidChange()
        files.workspace?.didFocus(files)
        files.refreshIfNeeded()
        files.settingsPresented = false
        guard !files.onboarding.isPresented else {
            files.isActive = false
            return
        }
        if !files.startsInReadingMode, !(firstResponder is NSTextView), files.markdownEditor?.ownsFirstResponder != true {
            pendingEditorInput.attach(to: self)
            makeFirstResponder(pendingEditorInput)
        }
        files.isActive = true
        requestEditorFocus()
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result { files.markdownEditor?.keyboardFocusDidChange() }
        if result, let editor = responder as? NSTextView,
           !(editor is MarkdownInputBuffer), !editor.isFieldEditor {
            // SwiftUI must finish mounting the editor and its binding before replaying input.
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor, self.isKeyWindow, self.firstResponder === editor else { return }
                for input in self.pendingEditorInput.takeInputs() {
                    guard self.isKeyWindow, self.firstResponder === editor else { break }
                    switch input {
                    case .text(let text): editor.insertText(text, replacementRange: editor.selectedRange())
                    case .key(let event): self.sendEvent(event)
                    }
                }
            }
        }
        return result
    }

    override func resignKey() {
        super.resignKey()
        files.markdownEditor?.keyboardFocusDidChange()
        pendingTitleInput.discardEvents()
        files.isActive = false
        files.lostFocus()
    }

}

struct PadView: View {
    // Retained for a future return to inline formatting controls.
    private static let usesCenteredFormattingToolbar = false
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Bindable var files: PadDocument
    let prepareTitleFocus: () -> Void
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var renameWidth: CGFloat = 100
    @State private var renamedDocument: UUID?
    @FocusState private var editing: Bool
    @State private var shareAnchor = PadShareAnchor()
    @State private var showingFormatting = false
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .pad)

    // The editor sits inside seven points of window padding on each side.
    private var readingColumnWidth: Double? { settings.readingWidth.map { max(1, $0 - 14) } }

    var body: some View {
        ZStack {
            if files.onboarding.isPresented {
                PadOnboardingView(onboarding: files.onboarding, shortcut: shortcut,
                                  onContinue: { files.finishOnboarding(includeExample: true) },
                                  onSkip: { files.finishOnboarding(includeExample: false) },
                                  onClose: { files.close() })
            } else {
                editorContent
            }
        }
        .tint(settings.accentColor)
        .onAppear {
            let action = openSettings
            files.showSettings = { action() }
        }
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            let workspace = files.workspace
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in workspace?.open(url) }
                }
            }
            return !providers.isEmpty
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            shortcut = KeyboardShortcuts.getShortcut(for: .pad)
        }
        .onChange(of: files.renameRequest) { _, _ in beginRename() }
        .onChange(of: files.onboarding.isPresented) { _, presented in
            if presented { editing = false; renaming = false; showingFormatting = false }
        }
    }

    private var editorLayout: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let centerWidth: CGFloat = Self.usesCenteredFormattingToolbar && showingFormatting && files.currentFormat == .md
                    ? (geometry.size.width >= 820 ? 280 : geometry.size.width >= 700 ? 144 : 36) : 0
                let titleSpace = Self.usesCenteredFormattingToolbar && showingFormatting
                    ? max(40, (geometry.size.width - centerWidth) / 2 - 100)
                    : max(40, geometry.size.width - 216)
                ZStack {
                    HStack(spacing: 6) {
                        Button { files.close() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                                .frame(width: 22, height: 26)
                        }
                        .padding(.trailing, -2)
                        .accessibilityLabel(files.isQuickPad ? "Close PadPad" : "Close file")
                        HStack(spacing: 5) {
                            if renaming {
                                HStack(spacing: 2) {
                                    OverlaySearchField(placeholder: "Name", text: $titleDraft, fontSize: 14,
                                                       fontWeight: .semibold, selectsTextOnFocus: true,
                                                       isCurrent: { renaming && files.isActive && renamedDocument == files.documentID },
                                                       submit: { commitRename() },
                                                       dismiss: { finishRename() },
                                                       blur: { commitRename(refocus: false) })
                                        .frame(width: min(renameWidth, max(40, titleSpace - 36)))
                                }
                                .frame(height: 22)
                            } else {
                                Text(files.displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .accessibilityIdentifier("documentTitle")
                                    .help("Rename (⌘R or double-click)")
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onTapGesture(count: 2, perform: beginRename)
                                    .simultaneousGesture(WindowDragGesture())
                            }
                        }
                        .frame(maxWidth: titleSpace + 12, alignment: .leading)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            if files.currentFormat == .md, let editor = files.markdownEditor {
                                Group {
                                    if Self.usesCenteredFormattingToolbar {
                                        Button {
                                            showingFormatting.toggle()
                                            editor.focus()
                                        } label: {
                                            Image(systemName: "textformat").frame(width: 16)
                                        }
                                        .buttonStyle(PadToolbarButtonStyle(selected: showingFormatting))
                                        .accessibilityLabel("Formatting")
                                        .accessibilityIdentifier("formattingToggle")
                                        .accessibilityValue(showingFormatting ? "Shown" : "Hidden")
                                        .accessibilityAddTraits(showingFormatting ? .isSelected : [])
                                        .help(showingFormatting ? "Hide formatting" : "Show formatting")
                                        .disabled(!editor.isReady)
                                    } else {
                                        Menu {
                                            PadMarkdownToolbar(editor: editor).menuCommands
                                                .disabled(!editor.canPerformMenuCommands)
                                        } label: {
                                            Image(systemName: "textformat").frame(width: 16)
                                        }
                                        .menuStyle(.button)
                                        .menuIndicator(.hidden)
                                        .buttonStyle(PadToolbarButtonStyle())
                                        .accessibilityLabel("Formatting")
                                        .accessibilityIdentifier("formattingMenu")
                                        .help("Formatting")
                                        .disabled(!editor.isReady)
                                    }
                                }
                            }
                            actionIcon("square.and.arrow.up", label: "Share", verticalOffset: -1) {
                                files.share(from: shareAnchor.view)
                            }
                            .background(PadShareAnchorView(anchor: shareAnchor).allowsHitTesting(false))
                            .disabled(!files.canShare)
                        }
                        .fixedSize()
                        Button("Save") { files.save() }
                            .buttonStyle(PadToolbarButtonStyle(primary: true))
                            .disabled(!files.isDirty)
                            .fixedSize()
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 10)
                    if Self.usesCenteredFormattingToolbar, showingFormatting, files.currentFormat == .md, let editor = files.markdownEditor {
                        PadMarkdownToolbar(editor: editor)
                            .frame(width: centerWidth)
                    }
                }
                .frame(width: geometry.size.width, height: 38)
            }
            .frame(height: 38)
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .labelStyle(.iconOnly)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { files.expand() }
                    .simultaneousGesture(WindowDragGesture())
            }

            ZStack(alignment: .bottom) {
                if files.currentFormat == .md {
                    if let editor = files.markdownEditor {
                        VStack(spacing: 0) {
                            if editor.showingFind { PadMarkdownFindBar(editor: editor) }
                            PadMarkdownEditorView(editor: editor)
                                .modifier(PadMarkdownLinkPresenter(editor: editor))
                        }
                            .onChange(of: settings.readingWidth, initial: true) {
                                editor.setReadingWidth(readingColumnWidth)
                            }
                            .onChange(of: settings.accentColor, initial: true) {
                                editor.accentOverride = NSColor(settings.accentColor)
                            }
                            .onChange(of: editor.showingLink) {
                                if !editor.showingLink { files.lostFocus() }
                            }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onAppear { files.mountMarkdownEditor() }
                    }
                } else {
                    PadPlainTextEditorView(text: $files.text, maxColumnWidth: readingColumnWidth.map { CGFloat($0) })
                        .id(files.documentID)
                        .background(EditorFocusMount())
                        .focused($editing)
                        .padding([.horizontal, .top], 10)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    if files.error == nil, files.editorFeedback == nil, let message = files.notice {
                        documentMessage(message, identifier: "documentNotice")
                    }
                    Spacer(minLength: 0)
                    if settings.showFormatToggle, files.isQuickPad, files.url == nil {
                        Button(files.currentFormat.title) {
                            Task { await files.toggleFormat() }
                        }
                        .buttonStyle(PadFormatButtonStyle())
                        .accessibilityIdentifier("documentFormat")
                        .accessibilityLabel(files.currentFormat == .md ? "Markdown" : "Plain text")
                        .accessibilityValue(files.currentFormat.title)
                        .help(files.currentFormat == .md ? "Switch to plain text" : "Switch to Markdown")
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .padding(.bottom, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .padding([.horizontal, .bottom], 7)
            // Inside the glass, so the window has no see-through strip under the editor card.
            if let message = files.error {
                detachedWarning(message, identifier: "documentError")
            } else if let feedback = files.editorFeedback {
                detachedWarning(feedback.message, identifier: "editorFeedback",
                                dismiss: { files.dismissEditorFeedback() })
            }
        }
    }

    private func detachedWarning(_ message: String, identifier: String,
                                 dismiss: (() -> Void)? = nil) -> some View {
        PadDocumentWarningView(message: message, identifier: identifier, dismiss: dismiss)
    }

    private func documentMessage(_ message: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(message)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    private var editorContent: some View {
        editorLayout
        .glassEffect(.regular, in: .rect(cornerRadius: 15))
        .ignoresSafeArea()
        .tint(settings.accentColor)
        .disabled(files.isBusy || files.workspace?.isTransitioning == true)
        .defaultFocus($editing, !files.startsInReadingMode)
        .onAppear {
            let action = openSettings
            files.showSettings = { action() }
        }
        .onChange(of: files.documentID) {
            if files.startsInReadingMode { editing = false }
            finishRename(refocus: false)
        }
        .onChange(of: files.currentFormat) { showingFormatting = false }
        .onChange(of: files.isActive, initial: true) {
            if files.isActive {
                if !renaming, !files.startsInReadingMode { editing = true }
            } else if renaming {
                commitRename(refocus: false)
            }
        }
    }

    private func titleWidth(_ text: String, weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: weight)]).width
    }

    private func beginRename() {
        guard files.isActive, !files.isBusy, !files.onboarding.isPresented, !renaming else { return }
        editing = false
        titleDraft = files.editableName
        renameWidth = max(100, titleWidth(titleDraft, weight: .semibold) + 12)
        renamedDocument = files.documentID
        prepareTitleFocus()
        renaming = true
    }

    private func commitRename(refocus: Bool = true) {
        guard renaming, renamedDocument == files.documentID else { return }
        if titleDraft.trimmingCharacters(in: .whitespacesAndNewlines) != files.editableName {
            // A failed rename preserves the original name and leaves the editor usable.
            _ = files.rename(to: titleDraft)
        }
        finishRename(refocus: refocus)
    }

    private func finishRename(refocus: Bool = true) {
        renaming = false
        guard refocus else { return }
        editing = files.isActive
        DispatchQueue.main.async {
            guard files.isActive, !renaming else { return }
            files.markdownEditor?.focus()
        }
    }

    private func actionIcon(_ symbol: String, label: String, verticalOffset: CGFloat,
                            perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .frame(width: 16)
                .offset(y: verticalOffset)
        }
        .buttonStyle(PadToolbarButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct PadFormatButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 24, minHeight: 16)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.85),
                        in: RoundedRectangle(cornerRadius: 5))
            .glassEffect(isEnabled && (hovered || isFocused || configuration.isPressed) ? .regular : .identity,
                         in: .rect(cornerRadius: 5))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}

private struct PadToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var primary = false
    var selected = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled && (primary || selected) ? .primary : .secondary)
            .frame(height: 16)
            .padding(.horizontal, primary ? 14 : 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(primary || (isEnabled && (hovered || configuration.isPressed)) ? 0.1 : 0), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovered = $0 }
    }
}

// The native editor can mount after SwiftUI's initial focus request has already run.
private struct EditorFocusMount: NSViewRepresentable {
    func makeNSView(context: Context) -> MountView { MountView() }

    func updateNSView(_ view: MountView, context: Context) { view.requestFocus() }

    final class MountView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            requestFocus()
        }

        override func layout() {
            super.layout()
            requestFocus()
        }

        func requestFocus() { (window as? any PadDocumentWindow)?.requestEditorFocus() }
    }
}

struct PadWarningContent {
    let message: String
    let guidance: String?

    init(_ error: String) {
        // These are PadPad's own messages. Keep actionable recovery on its own line.
        if let recovery = error.range(of: " Choose ") {
            message = String(error[..<recovery.lowerBound])
                .replacingOccurrences(of: " Your text is still open.", with: "")
            guidance = String(error[error.index(after: recovery.lowerBound)...])
        } else {
            message = error
            guidance = nil
        }
    }
}

struct PadDocumentWarningView: View {
    let message: String
    let identifier: String
    var dismiss: (() -> Void)?

    var body: some View {
        let content = PadWarningContent(message)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(content.message)
                if let guidance = content.guidance { Text(guidance).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
            if let dismiss {
                Button("Dismiss Message", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .help("Dismiss message")
                    .accessibilityIdentifier("dismissEditorFeedback")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 7)
        .padding(.bottom, 7)
    }
}
