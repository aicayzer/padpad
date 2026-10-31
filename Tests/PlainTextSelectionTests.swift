import AppKit
import Testing
@testable import Pad

@MainActor
struct PlainTextSelectionTests {
    @Test func continuedSelectionStopsAtEachLinesText() throws {
        let editor = makeEditor("First short line\nSecond line\n\nThird")
        editor.setSelectedRange(NSRange(location: 0, length: 28))
        let rects = editor.selectionRects()
        #expect(rects.count == 2)
        #expect(rects.allSatisfy { $0.width < 150 })
        #expect(rects[0].minX == rects[1].minX)
        #expect(rects[1].minY > rects[0].minY)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 28))
        #expect(editor.string == "First short line\nSecond line\n\nThird")
    }

    @Test func partialAndWrappedSelectionsKeepNativeGeometry() throws {
        let editor = makeEditor("First short line\n\n" + String(repeating: "wrapped text ", count: 16))
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let partial = try #require(editor.selectionRects().first)
        #expect(partial.minX > editor.textContainerOrigin.x + 5)
        #expect(partial.width < 40)

        editor.selectAll(nil)
        let wrapped = editor.selectionRects()
        #expect(wrapped.count > 3)
        #expect(wrapped.allSatisfy { $0.maxX < editor.bounds.width })
        #expect(wrapped.last?.width ?? 560 < 550)
        #expect(editor.selectedRange().length == (editor.string as NSString).length)

        editor.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(editor.selectionRects().isEmpty)
    }

    @Test func nativeKeyboardSelectionAndPlainTextEditingRemainAvailable() {
        let editor = makeEditor("First line\nSecond line")
        editor.isRichText = false
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.moveToEndOfLineAndModifySelection(nil)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 10))
        editor.insertText("Replacement", replacementRange: editor.selectedRange())
        #expect(editor.string == "Replacement\nSecond line")
        #expect(editor.selectedRange().length == 0)
        #expect(editor.selectionRects().isEmpty)
        #expect(editor.textLayoutManager != nil)
        #expect(editor.isAccessibilityElement())
    }

    @Test func nativeCopyUndoAndMarkedInputRetainTheirSemantics() {
        let editor = makeEditor("First line\nSecond line")
        let history = UndoDelegate()
        editor.delegate = history
        editor.allowsUndo = true
        editor.isRichText = false
        editor.setSelectedRange(NSRange(location: 0, length: 10))
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        #expect(editor.writeSelection(to: clipboard, types: editor.writablePasteboardTypes))
        #expect(clipboard.string(forType: .string) == "First line")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 10))

        history.history.beginUndoGrouping()
        editor.insertText("Replacement", replacementRange: editor.selectedRange())
        history.history.endUndoGrouping()
        #expect(history.history.canUndo)
        history.history.undo()
        #expect(editor.string == "First line\nSecond line")
        history.history.redo()
        #expect(editor.string == "Replacement\nSecond line")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.setMarkedText("e", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "éReplacement\nSecond line")
        #expect(editor.textLayoutManager is PadTextSelectionLayoutManager)
    }

    @Test func selectionTracksResizeAndUnicodeWithoutChangingContents() {
        let text = "👩🏽‍💻 café العربية עברית\n" + String(repeating: "wrapped words ", count: 16)
        let editor = makeEditor(text)
        editor.selectAll(nil)
        let wide = editor.selectionRects()
        editor.frame.size.width = 280
        if let layout = editor.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        let narrow = editor.selectionRects()
        #expect(narrow.count > wide.count)
        #expect(narrow.allSatisfy { $0.maxX <= editor.bounds.width })
        #expect(editor.string == text)
        #expect(editor.selectedRange().length == (text as NSString).length)
    }

    @Test func nativeScrollingRevealsSelectionAndKeepsBlankSpaceEditable() {
        let editor = makeEditor("Short")
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = PadPlainTextScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        scroll.documentView = editor
        scroll.tile()
        #expect(editor.minSize.height == scroll.contentSize.height)
        #expect(editor.frame.height >= scroll.contentSize.height)

        editor.string = String(repeating: "Line\n", count: 80)
        if let layout = editor.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        editor.sizeToFit()
        let end = (editor.string as NSString).length - 2
        editor.setSelectedRange(NSRange(location: end, length: 1))
        editor.scrollRangeToVisible(editor.selectedRange())
        #expect(scroll.contentView.bounds.minY > 0)
        #expect(editor.selectionRects().allSatisfy { $0.width < 100 })
    }

    @Test func imageOnlyPasteboardIsRefusedAndTextWithAnImageIsKept() throws {
        let picture = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { bounds in
            NSColor.red.setFill(); bounds.fill(); return true
        }
        let imageOnly = NSPasteboard(name: NSPasteboard.Name("pad.test.\(UUID().uuidString)"))
        defer { imageOnly.releaseGlobally() }
        imageOnly.clearContents()
        #expect(imageOnly.writeObjects([picture]))
        #expect(PadPlainTextImage.isImageOnly(imageOnly))

        let withText = NSPasteboard(name: NSPasteboard.Name("pad.test.\(UUID().uuidString)"))
        defer { withText.releaseGlobally() }
        withText.clearContents()
        #expect(withText.writeObjects([picture, "Caption" as NSString]))
        #expect(!PadPlainTextImage.isImageOnly(withText))

        let textOnly = NSPasteboard(name: NSPasteboard.Name("pad.test.\(UUID().uuidString)"))
        defer { textOnly.releaseGlobally() }
        textOnly.clearContents()
        textOnly.setString("Plain", forType: .string)
        #expect(!PadPlainTextImage.isImageOnly(textOnly))
        #expect(!PadPlainTextImage.isImageOnly(NSPasteboard(name: NSPasteboard.Name("pad.test.\(UUID().uuidString)"))))
    }

    @MainActor private final class UndoDelegate: NSObject, NSTextViewDelegate {
        let history = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { history }
    }

    private func makeEditor(_ text: String) -> NSTextView {
        let editor = PadPlainTextEditorView.makeTextView()
        editor.frame = NSRect(x: 0, y: 0, width: 560, height: 500)
        editor.font = .systemFont(ofSize: 15)
        editor.string = text
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.size = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        if let layout = editor.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        return editor
    }
}

@MainActor
private extension NSTextView {
    func selectionRects() -> [NSRect] {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return [] }
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        for value in selectedRanges {
            let range = value.rangeValue
            guard range.length > 0,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            layout.enumerateTextSegments(in: textRange, type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
                if frame.width > 0 { rects.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
                return true
            }
        }
        return rects
    }
}
