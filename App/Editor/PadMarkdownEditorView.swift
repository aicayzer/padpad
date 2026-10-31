import AppKit
import SwiftUI
import WebKit

struct PadMarkdownEditorView: NSViewRepresentable {
    let editor: PadMarkdownEditorController
    func makeNSView(context: Context) -> WKWebView { editor.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PadMarkdownToolbar: View {
    @Bindable var editor: PadMarkdownEditorController

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                headingMenu
                formatButton("Bold", image: "bold", command: .bold, size: 15)
                formatButton("Italic", image: "italic", command: .italic, size: 15)
                linkButton
                formatButton("Inline code", image: "chevron.left.forwardslash.chevron.right", command: .code)
                formatButton("Code block", image: "curlybraces", command: .codeBlock, size: 13.5)
                formatButton("Quote", image: "text.quote", command: .quote, size: 13.5)
                listMenu
            }
            .fixedSize()
            overflowMenu
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .disabled(!editor.canPerformMenuCommands || editor.editingMode != "formatted")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown formatting")
        .accessibilityIdentifier("markdownFormatting")
    }

    private var headingMenu: some View {
        Menu { headingCommands } label: {
            PadFormattingGlyph(text: "H", design: .rounded, selected: active(.heading))
        }
        .modifier(PadFormattingControlFrame())
        .tint(active(.heading) ? .primary : .secondary)
        .help("Headings")
        .accessibilityLabel("Headings")
        .accessibilityIdentifier("headingFormatting")
        .accessibilityValue(active(.heading) ? "On" : "Off")
    }

    private var listMenu: some View {
        Menu { listCommands } label: {
            PadFormattingGlyph(symbol: active(.orderedList) ? "list.number" : "list.bullet",
                               selected: active(.bulletList) || active(.orderedList))
        }
        .modifier(PadFormattingControlFrame())
        .tint(active(.bulletList) || active(.orderedList) ? .primary : .secondary)
        .help("Lists")
        .accessibilityLabel("Lists")
        .accessibilityValue(active(.bulletList) || active(.orderedList) ? "On" : "Off")
    }

    private var headingCommands: some View {
        Group {
            ForEach(1...3, id: \.self) { level in
                Toggle("Heading \(level)", isOn: Binding(
                    get: { editor.activeMarks.contains("heading\(level)") },
                    set: { _ in editor.format(.heading, argument: String(level)) }
                )).disabled(editor.formatAvailability["heading\(level)"] != true)
            }
        }
    }

    private var styleCommands: some View {
        Group {
            formatToggle("Bold", command: .bold)
            formatToggle("Italic", command: .italic)
            formatToggle("Underline", command: .underline)
        }
    }

    private var alignmentCommands: some View {
        Group {
            formatToggle("Align Left", command: .alignLeft)
            formatToggle("Center", command: .alignCenter)
            formatToggle("Justify", command: .alignJustify)
            formatToggle("Align Right", command: .alignRight)
        }
    }

    private var listCommands: some View {
        Group {
            formatToggle("Bulleted list", command: .bulletList)
            formatToggle("Numbered list", command: .orderedList)
        }
    }

    private var linkButton: some View {
        Button { editor.presentLink() } label: {
            PadFormattingGlyph(symbol: "link", selected: active(.link), size: 13.5)
        }
        .buttonStyle(.plain)
        .modifier(PadFormattingControlFrame())
        .help("Link (⌘K)")
        .accessibilityLabel("Link")
        .accessibilityValue(active(.link) ? "On" : "Off")
        .accessibilityAddTraits(active(.link) ? .isSelected : [])
    }

    /// The commands the loaded format supports, as InkKit's command state reports it: RTF has
    /// alignment, and no headings, quotes or code blocks. Availability enables each item.
    var menuCommands: some View {
        Group {
            if editor.documentFormat == .rtf {
                Menu("Alignment") { alignmentCommands }
            } else {
                Menu("Headings") { headingCommands }
            }
            Menu("Text style") { styleCommands }
            Divider()
            Button("Link") { editor.presentLink() }.disabled(editor.formatAvailability["link"] != true)
            formatToggle("Inline code", command: .code)
            if editor.documentFormat != .rtf {
                formatToggle("Code block", command: .codeBlock)
                formatToggle("Quote", command: .quote)
            }
            Divider()
            Menu("Lists") { listCommands }
            Menu("Table") {
                Button("Insert Table") { editor.table("insert") }.disabled(editor.tableAvailability["insert"] != true)
                Button("Add Row Before") { editor.table("addRowBefore") }.disabled(editor.tableAvailability["addRowBefore"] != true)
                Button("Add Row After") { editor.table("addRowAfter") }.disabled(editor.tableAvailability["addRowAfter"] != true)
                Button("Add Column Before") { editor.table("addColumnBefore") }.disabled(editor.tableAvailability["addColumnBefore"] != true)
                Button("Add Column After") { editor.table("addColumnAfter") }.disabled(editor.tableAvailability["addColumnAfter"] != true)
                Button("Delete Row") { editor.table("deleteRow") }.disabled(editor.tableAvailability["deleteRow"] != true)
                Button("Delete Column") { editor.table("deleteColumn") }.disabled(editor.tableAvailability["deleteColumn"] != true)
                Button("Delete Table") { editor.table("deleteTable") }.disabled(editor.tableAvailability["deleteTable"] != true)
                Button("Align Left") { editor.table("alignLeft") }.disabled(editor.tableAvailability["alignLeft"] != true)
                Button("Align Center") { editor.table("alignCenter") }.disabled(editor.tableAvailability["alignCenter"] != true)
                Button("Align Right") { editor.table("alignRight") }.disabled(editor.tableAvailability["alignRight"] != true)
                Button("Exit Table") { editor.table("exit") }.disabled(editor.tableAvailability["exit"] != true)
            }
        }
    }

    private var overflowMenu: some View {
        Menu { menuCommands } label: {
            PadFormattingGlyph(symbol: "ellipsis")
        }
        .fixedSize()
        .modifier(PadFormattingControlFrame())
        .tint(.secondary)
        .help("More formatting")
        .accessibilityLabel("More formatting")
        .accessibilityIdentifier("formattingOverflow")
    }

    private func active(_ command: PadMarkdownFormatCommand) -> Bool {
        editor.activeMarks.contains(command.rawValue)
    }

    private func formatToggle(_ title: String, command: PadMarkdownFormatCommand) -> some View {
        Toggle(title, isOn: Binding(get: { active(command) }, set: { _ in editor.format(command) }))
            .disabled(editor.formatAvailability[command.rawValue] != true)
    }

    private func formatButton(_ title: String, image: String, command: PadMarkdownFormatCommand, size: CGFloat = 14) -> some View {
        Button { editor.format(command) } label: {
            PadFormattingGlyph(symbol: image, selected: active(command), size: size)
        }
        .buttonStyle(.plain)
        .modifier(PadFormattingControlFrame())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(active(command) ? "On" : "Off")
        .accessibilityAddTraits(active(command) ? .isSelected : [])
    }
}

// Flatten every glyph into the same monochrome image so native menus and
// ordinary buttons cannot apply different symbol palettes or accent colors.
private struct PadFormattingGlyph: View {
    var symbol: String?
    var text: String?
    var design: NSFontDescriptor.SystemDesign = .default
    var selected = false
    var size: CGFloat = 14

    var body: some View {
        Image(nsImage: image).renderingMode(.original).frame(width: 22, height: 22)
    }

    private var image: NSImage {
        let canvas = NSSize(width: 22, height: 22)
        let image = NSImage(size: canvas, flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color = NSColor(calibratedWhite: selected ? (dark ? 0.9 : 0.28) : 0.6, alpha: 1)
            if let text {
                let fontSize: CGFloat = 15
                let base = NSFont.systemFont(ofSize: fontSize, weight: .medium)
                let font = base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
                let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                let extent = string.size()
                // Align the visible capital, rather than its line-height box.
                string.draw(at: NSPoint(x: (rect.width - extent.width) / 2,
                                        y: (rect.height - font.capHeight) / 2 + font.descender - 1))
            } else {
                let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
                guard let source = NSImage(systemSymbolName: symbol ?? "ellipsis", accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration) else { return false }
                let raster = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                raster.size = canvas
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: raster)
                source.draw(in: NSRect(x: (22 - source.size.width) / 2, y: (22 - source.size.height) / 2,
                                       width: source.size.width, height: source.size.height))
                NSGraphicsContext.current?.compositingOperation = .sourceIn
                color.setFill()
                NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
                NSGraphicsContext.restoreGraphicsState()
                raster.draw(in: rect)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

private struct PadFormattingControlFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: 26, height: 28)
            .contentShape(Capsule())
    }
}

// Anchor the native popover to geometry measured through InkKit’s public facade.
struct PadMarkdownLinkPresenter: ViewModifier {
    @Bindable var editor: PadMarkdownEditorController
    @State private var linkURL = ""
    @State private var validLink: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: editor.showingLink) { _, showing in
                if showing { linkURL = editor.linkAddress }
            }
            .task(id: linkURL) { validLink = await editor.normalizedLink(linkURL) }
            .popover(isPresented: $editor.showingLink, attachmentAnchor: editor.linkRect.map { .rect(.rect($0)) } ?? .rect(.bounds), arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Link URL", text: $linkURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { insertLink() }
                    HStack {
                        if editor.activeMarks.contains("link") {
                            Button("Remove Link") {
                                editor.format(.link)
                                editor.showingLink = false
                            }
                        }
                        Spacer()
                        Button("Cancel") { editor.showingLink = false }
                        Button("Add Link") { insertLink() }
                            .disabled(validLink == nil)
                    }
                }
                .foregroundStyle(.primary)
                .tint(.primary)
                .padding(12)
                .frame(width: 300)
            }
    }

    private func insertLink() {
        let input = linkURL
        Task {
            // Check the text as it is now, not the last result, which may lag behind typing.
            guard let address = await editor.normalizedLink(input) else { return }
            editor.format(.link, argument: address)
            editor.showingLink = false
        }
    }

}

struct PadMarkdownFindBar: View {
    @Bindable var editor: PadMarkdownEditorController
    @Environment(\.displayScale) private var displayScale

    private var hasMatches: Bool { editor.searchState.query == editor.searchText && editor.searchState.total > 0 }
    private var canReplace: Bool { hasMatches && editor.canReplace }
    private var matchLabel: String {
        let state = editor.searchState
        if state.total > 0 && state.current == 0 { return state.total == 1 ? "1 match" : "\(state.total) matches" }
        return "\(state.current)/\(state.total)"
    }
    private var matchAccessibilityLabel: String {
        let state = editor.searchState
        if state.total > 0 && state.current == 0 { return state.total == 1 ? "1 match" : "\(state.total) matches" }
        return "\(state.current) of \(state.total) matches"
    }

    var body: some View {
        HStack(spacing: 4) {
            iconButton(editor.showingReplacement ? "Hide Replacement" : "Show Replacement", symbol: "chevron.right") {
                withAnimation(.easeInOut(duration: 0.16)) { editor.showingReplacement.toggle() }
            }
            .rotationEffect(.degrees(editor.showingReplacement ? 90 : 0))
            .accessibilityValue(editor.showingReplacement ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("find.disclosure")

            Grid(horizontalSpacing: 4, verticalSpacing: 6) {
                GridRow {
                    HStack(spacing: 6) {
                        OverlaySearchField(placeholder: "Find", text: $editor.searchText, fontSize: 13,
                            isCurrent: { editor.showingFind }, submit: { editor.find(direction: 1) },
                            dismiss: editor.dismissFind, previousSubmit: { editor.find(direction: -1) })
                            .onChange(of: editor.searchText) { _, _ in editor.find() }
                        if !editor.searchText.isEmpty {
                            Text(matchLabel)
                                .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                                .accessibilityLabel(matchAccessibilityLabel)
                        }
                    }
                    .modifier(PadFindFieldStyle(displayScale: displayScale))
                    iconButton("Previous Match", symbol: "chevron.up") { editor.find(direction: -1) }.disabled(!hasMatches)
                    iconButton("Next Match", symbol: "chevron.down") { editor.find(direction: 1) }.disabled(!hasMatches)
                    iconButton("Close Find", symbol: "xmark", action: editor.dismissFind)
                }
                if editor.showingReplacement {
                    GridRow {
                        OverlaySearchField(placeholder: "Replace with", text: $editor.replacementText, fontSize: 13,
                            isCurrent: { editor.showingFind && editor.showingReplacement },
                            submit: { if canReplace { editor.replace(all: false) } },
                            dismiss: editor.dismissFind, initiallyFocused: false)
                            .modifier(PadFindFieldStyle(displayScale: displayScale))
                        iconButton("Replace", symbol: "arrow.uturn.right") { editor.replace(all: false) }.disabled(!canReplace)
                        iconButton("Replace All", symbol: "arrow.triangle.2.circlepath") { editor.replace(all: true) }.disabled(!canReplace)
                        Color.clear.frame(width: 26, height: 26).accessibilityHidden(true)
                    }
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .frame(maxWidth: 428)
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find and Replace")
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct PadFindFieldStyle: ViewModifier {
    let displayScale: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 28)
            .padding(.horizontal, 8)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.primary.opacity(0.22), lineWidth: 1 / displayScale)
                    .allowsHitTesting(false)
            }
    }
}
