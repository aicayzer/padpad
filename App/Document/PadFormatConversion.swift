import Foundation
import InkKitRTF
import UniformTypeIdentifiers

enum PadFormat: String, CaseIterable, Identifiable {
    case md, txt, rtf

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }

    /// The name people see in menus, alerts and accessibility labels.
    var name: String {
        switch self {
        case .md: "Markdown"
        case .txt: "Plain Text"
        case .rtf: "RTF"
        }
    }

    /// Markdown and RTF use the InkKit editor; plain text uses the native text view.
    var usesEditor: Bool { self != .txt }

    var contentType: UTType {
        switch self {
        case .md: UTType(filenameExtension: "md") ?? .plainText
        case .txt: .plainText
        case .rtf: .rtf
        }
    }
}

/// A document converted to another format, with what the conversion changes.
struct PadConversion: Equatable {
    let text: String
    /// Short sentences that name what changes, in the order the alert lists them. Empty when nothing is lost.
    let changes: [String]
}

/// RTF documents are stored in `PadDocument.text` as the canonical JSON of their `RichTextDocument`,
/// so the existing text-based state, dirty checks and snapshots work for every format. A document
/// with no blocks is the empty string, like an empty Markdown or plain text document.
enum PadRichText {
    static let emptyJSON = #"{"blocks":[],"version":1}"#

    static func text(for document: RichTextDocument) throws(RTFConversionError) -> String {
        document.blocks.isEmpty ? "" : String(decoding: try document.jsonData(), as: UTF8.self)
    }

    static func document(from text: String) throws(RTFConversionError) -> RichTextDocument {
        text.isEmpty ? RichTextDocument() : try RichTextDocument(json: Data(text.utf8))
    }

    /// Canonical stored text for JSON that the editor produced.
    static func canonicalText(json: String) throws(RTFConversionError) -> String {
        try text(for: RichTextDocument(json: Data(json.utf8)))
    }

    /// The JSON the editor loads.
    static func json(for text: String) -> String { text.isEmpty ? emptyJSON : text }
}

extension PadFormat {
    /// Reads a file's bytes and stored text. A directory, such as an RTFD package with an `.rtf` name, is refused.
    func read(_ file: URL) throws -> (bytes: Data, text: String) {
        var isDirectory: ObjCBool = false
        if self == .rtf, FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw RTFConversionError.notRTF
        }
        let bytes = try Data(contentsOf: file)
        return (bytes, try decode(bytes))
    }

    /// The stored text for a file's bytes. Refuses rather than loses: an RTF conversion error keeps the file closed.
    func decode(_ bytes: Data) throws -> String {
        switch self {
        case .md, .txt:
            guard let content = String(data: bytes, encoding: .utf8) else { throw PadError.encoding }
            return content
        case .rtf:
            return try PadRichText.text(for: RTFConverter.document(fromRTF: bytes))
        }
    }

    /// The complete file bytes for stored text. Conversion finishes before anything is written.
    func encode(_ text: String) throws -> Data {
        switch self {
        case .md, .txt: return Data(text.utf8)
        case .rtf: return try RTFConverter.rtfData(from: PadRichText.document(from: text))
        }
    }
}

enum PadFormatLoss {
    /// Inkkit's stable `FormatLossCode` values, as short sentences.
    static func change(for code: String) -> String {
        switch code {
        case "heading": "Headings become bold text."
        case "code-block": "Code blocks become code-formatted paragraphs."
        case "diagram": "Diagrams become their source text."
        case "quote": "Quotes become ordinary paragraphs."
        case "callout": "Callouts become ordinary paragraphs."
        case "task": "Task checkboxes are removed."
        case "rule": "Horizontal rules are removed."
        case "footnote": "Footnotes become ordinary text."
        case "comment": "Comments are removed."
        case "highlight": "Highlighting is removed."
        case "image": "Images are removed."
        case "file": "Embedded files are removed."
        case "wiki-link": "Wiki links become ordinary text."
        case "literal": "Raw HTML and unformatted Markdown become ordinary text."
        case "link": "Links without an address become ordinary text."
        case "table-alignment": "Table column alignment is removed."
        case "list-start": "Numbered lists that start at 0 start at 1."
        case "list-item-blocks": "List items with several paragraphs become one paragraph."
        case "list-depth": "Lists nested more than 9 levels deep are flattened."
        case "link-underline": "Underlined links lose their underline."
        case "invalid-character": "Characters RTF can’t store become replacement characters (�)."
        case "alignment": "Centered, right-aligned and justified text becomes left-aligned."
        case "mark-spaces": "Spaces at the edges of underlined, struck-through or linked text lose that formatting."
        case "empty-line": "Lines with only a line break become empty paragraphs, and empty paragraphs at the end are removed."
        default: "Some formatting is removed."
        }
    }

    /// RTF to plain text always drops formatting, so the switch is always confirmed.
    static let plainText = [
        "Bold, italic, links and other formatting are removed.",
        "Lists and tables become plain lines of text.",
    ]

    static func changes(for codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.map(change(for:)).filter { seen.insert($0).inserted }
    }
}

extension PadAlert {
    /// Confirms a conversion that loses something. Nothing changes unless the person chooses Convert.
    static func conversion(to format: PadFormat, savingCopy: Bool, changes: [String]) -> PadAlert {
        let name = format == .txt ? "plain text" : format.name
        let title = savingCopy ? "Save a copy as \(name)?" : "Convert this draft to \(name)?"
        var lines = changes
        if savingCopy { lines.append("The original file doesn’t change.") }
        return PadAlert(title: title, message: lines.joined(separator: "\n"), action: .convert)
    }
}
