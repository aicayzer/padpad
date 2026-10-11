import AppKit
import SwiftUI

struct PadPlainTextEditorView: NSViewRepresentable {
    @Binding var text: String
    var maxColumnWidth: CGFloat? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PadPlainTextScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let editor = Self.makeTextView()
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

    static func makeTextView() -> NSTextView {
        let content = NSTextContentStorage()
        let layout = PadTextSelectionLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer()
        layout.textContainer = container
        return PadPlainTextView(frame: .zero, textContainer: container)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        (scroll as? PadPlainTextScrollView)?.maxColumnWidth = maxColumnWidth
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
        editor.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}

private final class PadPlainTextView: NSTextView {
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
