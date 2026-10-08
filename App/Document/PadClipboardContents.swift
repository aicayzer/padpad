import AppKit

struct PadClipboardContents: Equatable {
    let text: String
    var html: String?

    @MainActor
    func write(to pasteboard: NSPasteboard, writer: (([NSPasteboardWriting]) -> Bool)? = nil) throws {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string), html.map({ item.setString($0, forType: .html) }) ?? true else {
            throw CocoaError(.fileWriteUnknown)
        }
        let previous = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        guard writer?([item]) ?? pasteboard.writeObjects([item]) else {
            pasteboard.clearContents()
            if !previous.isEmpty { pasteboard.writeObjects(previous) }
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
