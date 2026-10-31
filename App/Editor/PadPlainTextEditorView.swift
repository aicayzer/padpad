import AppKit
import SwiftUI

struct PadPlainTextEditorView: NSViewRepresentable {
    @Binding var text: String
    var maxColumnWidth: CGFloat? = nil
    /// Called when a paste or drop holds only an image, which plain text can't keep.
    var onImageRefused: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PadPlainTextScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let editor = Self.makeTextView()
        editor.onImageRefused = { [weak coordinator = context.coordinator] in coordinator?.onImageRefused() }
        context.coordinator.onImageRefused = onImageRefused
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .textColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainerInset = NSSize(width: 0, height: 24)
        editor.string = text
        scroll.maxColumnWidth = maxColumnWidth
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    static func makeTextView() -> PadPlainTextView {
        let content = NSTextContentStorage()
        let layout = PadTextSelectionLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer()
        layout.textContainer = container
        return PadPlainTextView(frame: .zero, textContainer: container)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onImageRefused = onImageRefused
        (scroll as? PadPlainTextScrollView)?.maxColumnWidth = maxColumnWidth
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
        editor.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onImageRefused: () -> Void = {}
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}

/// Whether a paste or drop holds only an image. Text that comes with an image is pasted as usual.
enum PadPlainTextImage {
    static func isImageOnly(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        guard !types.contains(.string) else { return false }
        return NSImage.canInit(with: pasteboard)
    }
}

final class PadPlainTextView: NSTextView {
    /// Reports a refused image so the host can show its message.
    var onImageRefused: () -> Void = {}

    override func paste(_ sender: Any?) {
        if refuseImage(in: .general) { return }
        super.paste(sender)
    }

    // The text view disables Paste when it can read nothing on the pasteboard, which would swallow an image-only paste silently.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), PadPlainTextImage.isImageOnly(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), PadPlainTextImage.isImageOnly(.general) { return true }
        return super.validateMenuItem(item)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if refuseImage(in: .general) { return }
        super.pasteAsPlainText(sender)
    }

    // The text view declines a drop it can't read, so accept an image-only drop here and refuse it on release.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        PadPlainTextImage.isImageOnly(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        PadPlainTextImage.isImageOnly(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if refuseImage(in: sender.draggingPasteboard) { return false }
        return super.performDragOperation(sender)
    }

    private func refuseImage(in pasteboard: NSPasteboard) -> Bool {
        guard PadPlainTextImage.isImageOnly(pasteboard) else { return false }
        onImageRefused()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerOrigin.y)
        ("Start typing…" as NSString).draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.placeholderTextColor
        ])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override var textContainerOrigin: NSPoint {
        // Keep the existing top alignment. Both vertical insets become trailing
        // scrollable space so the final line can clear the floating footer.
        NSPoint(x: super.textContainerOrigin.x, y: 0)
    }
}

final class PadPlainTextScrollView: NSScrollView {
    // The setting includes the view's existing 10-point margins on each side.
    var maxColumnWidth: CGFloat? {
        didSet {
            guard maxColumnWidth != oldValue else { return }
            updateColumnWidth()
        }
    }

    private func updateColumnWidth() {
        guard let editor = documentView as? NSTextView else { return }
        let availableWidth = contentSize.width
        let columnWidth = maxColumnWidth.map { min(availableWidth, max(1, $0 - 20)) } ?? availableWidth
        let horizontalInset = max(0, (availableWidth - columnWidth) / 2)
        guard editor.textContainerInset.width != horizontalInset else { return }
        editor.textContainerInset = NSSize(width: horizontalInset, height: 24)
        editor.needsDisplay = true
    }

    override func tile() {
        super.tile()
        updateColumnWidth()
        guard let editor = documentView as? NSTextView else { return }
        // Empty space beneath a short document must remain part of the native editor.
        editor.minSize = contentSize
        if editor.frame.height < contentSize.height { editor.frame.size.height = contentSize.height }
    }
}

final class PadTextSelectionLayoutManager: NSTextLayoutManager {
    override func enumerateTextSegments(in textRange: NSTextRange, type: SegmentType,
                                        options: SegmentOptions = [],
                                        using block: (NSTextRange?, CGRect, CGFloat, NSTextContainer) -> Bool) {
        // Selection segments extend continued lines to the container edge. Native painting
        // should use the typographic bounds, just as Markdown's text-only highlights do.
        super.enumerateTextSegments(in: textRange, type: type == .selection ? .standard : type,
                                    options: options, using: block)
    }
}
