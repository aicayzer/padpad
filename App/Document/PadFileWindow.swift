import AppKit
import SwiftUI

/// An independent file window using the same compact shell as the quick pad.
final class PadFileWindow: NSWindow, PadDocumentWindow {
    private let files: PadDocument
    private lazy var input = PadWindowInput(window: self, files: files)

    init(files: PadDocument) {
        self.files = files
        super.init(contentRect: NSRect(origin: .zero, size: files.defaultWindowSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        contentView = NSHostingView(rootView: PadView(files: files, prepareTitleFocus: { [weak self] in
            self?.input.prepareTitleFocus()
        })
            .environment(files.appSettings ?? AppSettings())
            .frame(minWidth: PadWindowSize.minimum.width, minHeight: PadWindowSize.minimum.height))
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        isExcludedFromWindowsMenu = false
        input.attach()
        if files.startsInReadingMode { _ = makeFirstResponder(self) }
        restoreDefaultSize(animate: false)
        let offset = CGFloat(max(0, (files.workspace?.documents.count ?? 1) - 1) % 6) * 24
        setFrameTopLeftPoint(NSPoint(x: frame.minX + offset, y: frame.maxY - offset))
        constrainToAvailableScreen()
    }

    override func close() { files.close() }
    func finishClosing() { super.close() }
    func toggleExpanded() {
        zoom(nil)
        files.isExpanded = isZoomed
    }

    func restoreDefaultSize(animate: Bool = true) {
        guard !styleMask.contains(.fullScreen), let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let preferred = files.defaultWindowSize
        let size = NSSize(width: min(preferred.width, visible.width), height: min(preferred.height, visible.height))
        setFrame(NSRect(origin: frame.origin, size: size), display: true, animate: animate)
        center()
        files.isExpanded = false
        constrainToAvailableScreen()
    }

    func constrainToAvailableScreen() {
        guard !styleMask.contains(.fullScreen), let screen = screen ?? NSScreen.main else { return }
        setFrame(constrainFrameRect(frame, to: screen), display: true)
    }

    func requestEditorFocus() { input.requestEditorFocus() }
    func prepareMarkdownSnapshot() { input.prepareMarkdownSnapshot() }
    func prepareReading() { input.prepareReading() }
    func prepareOnboarding() { input.prepareOnboarding() }
    func resumeEditor() { input.resumeEditor() }

    override func sendEvent(_ event: NSEvent) {
        if input.capturesPendingInput(event) { return }
        super.sendEvent(event)
        files.acceptMarkdownContentClick(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        input.performKeyEquivalent(with: event, restoreDefaultSize: { restoreDefaultSize() })
            ?? super.performKeyEquivalent(with: event)
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
