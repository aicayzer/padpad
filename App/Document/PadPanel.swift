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

/// The quick pad: a floating, nonactivating panel. File windows are `PadFileWindow`.
final class PadPanel: NSPanel, PadDocumentWindow {
    private let files: PadDocument
    private var previousFrame: NSRect?
    private var restoreAfterFullScreen = false
    private var trackingWindowMove = false
    private var snapTrackingTimer: Timer?
    private lazy var snapGuide = PadSnapGuide()
    private lazy var input = PadWindowInput(window: self, files: files)

    var pendingEditorEventCount: Int { input.pendingEditorEventCount }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(files: PadDocument, quit: (@MainActor () -> Void)? = nil) {
        self.files = files
        let size = files.defaultWindowSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        if let quit { input.quit = quit }
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = files.floating ? .floating : .normal
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        // AppKit draws outside the window; a SwiftUI shadow gets clipped at the hosting bounds.
        hasShadow = true
        isMovableByWindowBackground = true
        contentView = NSHostingView(rootView: PadView(files: files, prepareTitleFocus: { [weak self] in
            self?.input.prepareTitleFocus()
        }).environment(files.appSettings ?? AppSettings())
            // Hosting derives the native minimum from the content's constraints.
            .frame(minWidth: PadWindowSize.minimum.width, minHeight: PadWindowSize.minimum.height))
        input.attach()
        if files.startsInReadingMode { _ = makeFirstResponder(self) }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillMove),
                                               name: NSWindow.willMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved),
                                               name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(exitedFullScreen),
                                               name: NSWindow.didExitFullScreenNotification, object: self)
        restoreDefaultSize(animate: false)
    }

    override func orderOut(_ sender: Any?) {
        endSnapTracking(commit: false)
        super.orderOut(sender)
    }

    @objc private func windowWillMove() {
        guard !styleMask.contains(.fullScreen),
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

    @objc private func applicationBecameActive() { input.requestEditorFocus() }

    func requestEditorFocus() { input.requestEditorFocus() }
    func prepareMarkdownSnapshot() { input.prepareMarkdownSnapshot() }
    func prepareReading() { input.prepareReading() }
    func prepareOnboarding() { input.prepareOnboarding() }
    func resumeEditor() { input.resumeEditor() }

    override func sendEvent(_ event: NSEvent) {
        if handleOnboardingNavigation(event) || input.capturesPendingInput(event) { return }
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
        input.performKeyEquivalent(with: event, restoreDefaultSize: { restoreDefaultSize() })
            ?? super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { files.close() }

    override func close() { files.close() }

    func finishClosing() {
        super.close()
    }

    func restoreDefaultSize(animate: Bool = true) {
        guard let screen = screen ?? NSScreen.main else { return }
        if styleMask.contains(.fullScreen) {
            restoreAfterFullScreen = true
            toggleFullScreen(nil)
            return
        }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let preferred = files.defaultWindowSize
        let size = NSSize(width: min(preferred.width, visible.width), height: min(preferred.height, visible.height))
        previousFrame = nil
        files.isExpanded = false
        setFrame(NSRect(origin: frame.origin, size: size), display: true, animate: animate)
        setFrameOrigin(PadQuickPadPlacement.frame(size: size, in: screen.visibleFrame).origin)
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

    /// Fills the screen, keeping a small margin, or returns to the size and place it had before.
    func toggleExpanded() {
        if let previousFrame {
            self.previousFrame = nil
            setFrame(previousFrame, display: true, animate: true)
        } else if let screen = screen ?? NSScreen.main {
            previousFrame = frame
            setFrame(screen.visibleFrame.insetBy(dx: 24, dy: 24), display: true, animate: true)
        }
        files.isExpanded = previousFrame != nil
    }

    override func becomeKey() {
        super.becomeKey()
        input.didBecomeKey()
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result { input.didMakeFirstResponder(responder) }
        return result
    }

    override func resignKey() {
        super.resignKey()
        input.didResignKey()
    }
}

struct PadView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Bindable var files: PadDocument
    let prepareTitleFocus: () -> Void
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var renamedDocument: UUID?
    @FocusState private var editing: Bool
    @State private var shareAnchor = PadShareAnchor()
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
            if presented { editing = false; renaming = false }
        }
    }

    private var editorLayout: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let titleSpace = max(40, geometry.size.width - 240)
                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        windowButton("xmark.circle.fill", label: files.isQuickPad ? "Close PadPad" : "Close file") {
                            files.close()
                        }
                        windowButton(files.isExpanded ? "arrow.down.right.and.arrow.up.left.circle.fill"
                                                      : "arrow.up.left.and.arrow.down.right.circle.fill",
                                     label: files.isExpanded ? "Restore Size" : "Expand") {
                            files.expand()
                        }
                        .accessibilityIdentifier("expandWindow")
                    }
                    .padding(.trailing, -2)
                    HStack(spacing: 5) {
                        if renaming {
                            HStack(spacing: 2) {
                                OverlaySearchField(placeholder: "Name", text: $titleDraft, fontSize: 14,
                                                   fontWeight: .semibold, selectsTextOnFocus: true,
                                                   isCurrent: { renaming && files.isActive && renamedDocument == files.documentID },
                                                   submit: { commitRename() },
                                                   dismiss: { finishRename() },
                                                   blur: { commitRename(refocus: false) })
                                    .frame(width: titleSpace)
                            }
                            .frame(height: 22)
                        } else {
                            Text(files.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                // A draft's title is fainter than a saved file's name, so it never reads as a file name.
                                .foregroundStyle(files.url == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("documentTitle")
                                .accessibilityValue(files.draftStatus ?? "")
                                .help(files.draftStatus.map { "\($0) Double-click to name it." } ?? "Rename (⌘R or double-click)")
                                .fixedSize(horizontal: false, vertical: true)
                                .onTapGesture(count: 2, perform: beginRename)
                                .simultaneousGesture(WindowDragGesture())
                        }
                    }
                    .frame(maxWidth: titleSpace + 12, alignment: .leading)
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        if files.currentFormat.usesEditor, let editor = files.markdownEditor {
                            Menu {
                                PadFormattingCommands(editor: editor)
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
                        actionIcon("square.and.arrow.up", label: "Share", verticalOffset: -1) {
                            files.share(from: shareAnchor.view)
                        }
                        .background(PadShareAnchorView(anchor: shareAnchor).allowsHitTesting(false))
                        .disabled(!files.canShare)
                    }
                    .fixedSize()
                    Button { files.save() } label: {
                        // Reserve the longer label's width, so the header doesn't shift when the label changes.
                        ZStack {
                            Text("Saved").hidden()
                            Text(files.isSaved ? "Saved" : "Save")
                        }
                    }
                    .buttonStyle(PadToolbarButtonStyle(primary: true, quiet: files.isSaved))
                    .disabled(!files.canSave)
                    .accessibilityLabel("Save")
                    .accessibilityValue(files.isSaved ? "Saved" : "")
                    .fixedSize()
                }
                .padding(.leading, 8)
                .padding(.trailing, 10)
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
                    .gesture(WindowDragGesture())
            }

            ZStack(alignment: .bottom) {
                if files.currentFormat.usesEditor {
                    if let editor = files.markdownEditor {
                        PadMarkdownEditorView(editor: editor)
                            .modifier(PadMarkdownLinkPresenter(editor: editor))
                            .overlay(alignment: .topTrailing) {
                                if editor.showingFind { PadMarkdownFindBar(editor: editor) }
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
                    PadPlainTextEditorView(text: $files.text, maxColumnWidth: readingColumnWidth.map { CGFloat($0) },
                                           onImageRefused: { files.refuseImage() })
                        .id(files.documentID)
                        .background(EditorFocusMount())
                        .focused($editing)
                        .padding([.horizontal, .top], 10)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    message
                        // The message takes the room it needs before the spacer, so it wraps only at its maximum.
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    if settings.showFormatToggle, files.isQuickPad, files.url == nil {
                        if files.hasFormatChoices {
                            Button {
                                Task { await files.cycleFormat() }
                            } label: {
                                Text(files.currentFormat.title)
                            }
                            .buttonStyle(PadFormatButtonStyle())
                            .fixedSize()
                            .accessibilityIdentifier("documentFormat")
                            .accessibilityLabel(files.currentFormat.name)
                            .accessibilityValue(files.currentFormat.title)
                            .help("Change to \(files.nextFormat?.name ?? files.currentFormat.name)")
                        } else {
                            Text(files.currentFormat.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 24, minHeight: 16)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .accessibilityIdentifier("documentFormatLabel")
                                .accessibilityLabel(files.currentFormat.name)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .padding([.horizontal, .bottom], 7)
        }
    }

    @ViewBuilder private var message: some View {
        if let error = files.error {
            PadMessageView(message: error, identifier: "documentError", dismiss: { files.dismissMessage() })
        } else if let feedback = files.editorFeedback {
            PadMessageView(message: feedback.message, identifier: "editorFeedback", dismiss: { files.dismissMessage() })
        } else if let notice = files.notice {
            if files.noticeRevealsFile {
                PadMessageView(message: PadMessage(text: notice), identifier: "documentNotice",
                               reveal: { files.revealInFinder() }, hold: { files.holdNotice($0) })
            } else {
                PadMessageView(message: PadMessage(text: notice), identifier: "documentNotice")
            }
        }
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
        .onChange(of: files.isActive, initial: true) {
            if files.isActive {
                if !renaming, !files.startsInReadingMode { editing = true }
            } else if renaming {
                commitRename(refocus: false)
            }
        }
    }

    private func beginRename() {
        guard files.isActive, !files.isBusy, !files.onboarding.isPresented, !renaming else { return }
        editing = false
        titleDraft = files.editableName
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

    private func windowButton(_ symbol: String, label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .frame(width: 22, height: 26)
        }
        .accessibilityLabel(label)
        .help(label)
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
    /// A primary button with nothing to do right now, such as Save when the file is up to date.
    var quiet = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled && primary && !quiet ? .primary : .secondary)
            .frame(height: 16)
            .padding(.horizontal, primary ? 14 : 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(backgroundOpacity(pressed: configuration.isPressed)), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovered = $0 }
    }

    private func backgroundOpacity(pressed: Bool) -> Double {
        let active = isEnabled && (hovered || pressed)
        if primary { return active ? 0.16 : 0.1 }
        return active ? 0.1 : 0
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

/// Sizes its child to the text it holds, never wider than `maximum`.
private struct PadMessageWidth: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maximum, maximum), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// One message pill for the whole app. A confirmation clears itself; a problem stays until it is clicked or its cause goes away.
struct PadMessageView: View {
    let message: PadMessage
    let identifier: String
    /// Present for problems only: clicking anywhere on the pill dismisses it.
    var dismiss: (() -> Void)?
    /// Present for a notice about a saved file: clicking it shows the file in Finder.
    var reveal: (() -> Void)?
    /// Keeps the notice on screen while the pointer is over it.
    var hold: ((Bool) -> Void)?
    @State private var hovering = false

    // Long enough for a sentence and its hint, short enough to stay a message and not a banner.
    static let maximumWidth: CGFloat = 420

    var body: some View {
        PadMessageWidth(maximum: Self.maximumWidth) {
            if let dismiss {
                Button(action: dismiss) {
                    pill {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.text).fontWeight(.medium).foregroundStyle(.primary)
                            if let hint = message.hint { Text(hint).foregroundStyle(.secondary) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Error: \([message.text, message.hint].compactMap(\.self).joined(separator: " "))")
                .accessibilityHint("Dismiss")
                .accessibilityIdentifier(identifier)
            } else if let reveal {
                Button(action: reveal) {
                    pill { Text(message.text).underline(hovering).foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    hovering = inside
                    hold?(inside)
                }
                .help("Show in Finder")
                .accessibilityLabel(message.text)
                .accessibilityHint("Shows the file in Finder")
                .accessibilityIdentifier(identifier)
            } else {
                pill { Text(message.text).foregroundStyle(.secondary) }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(identifier)
            }
        }
    }

    private func pill(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.system(size: 13))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.rect(cornerRadius: 10))
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }
}
