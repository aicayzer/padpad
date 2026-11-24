import AppKit
import SwiftUI
import WebKit

struct PadMarkdownEditorView: NSViewRepresentable {
    let editor: PadMarkdownEditorController
    func makeNSView(context: Context) -> WKWebView { editor.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// The formatting commands the loaded format supports, as InkKit's command state reports it: RTF has
/// alignment, and no headings, quotes or code blocks. Availability enables each item. The header's Aa menu
/// and the Format menu both show these.
struct PadFormattingCommands: View {
    @Bindable var editor: PadMarkdownEditorController

    var body: some View {
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
            ForEach(Self.tableCommands, id: \.action) { command in
                Button(command.title) { editor.table(command.action) }
                    .disabled(editor.tableAvailability[command.action] != true)
            }
        }
    }

    private static let tableCommands: [(title: String, action: String)] = [
        ("Insert Table", "insert"),
        ("Add Row Before", "addRowBefore"), ("Add Row After", "addRowAfter"),
        ("Add Column Before", "addColumnBefore"), ("Add Column After", "addColumnAfter"),
        ("Delete Row", "deleteRow"), ("Delete Column", "deleteColumn"), ("Delete Table", "deleteTable"),
        ("Align Left", "alignLeft"), ("Align Center", "alignCenter"), ("Align Right", "alignRight"),
        ("Exit Table", "exit")
    ]

    @ViewBuilder private var headingCommands: some View {
        ForEach(1...3, id: \.self) { level in
            Toggle("Heading \(level)", isOn: Binding(
                get: { editor.activeMarks.contains("heading\(level)") },
                set: { _ in editor.format(.heading, argument: String(level)) }
            )).disabled(editor.formatAvailability["heading\(level)"] != true)
        }
    }

    @ViewBuilder private var styleCommands: some View {
        formatToggle("Bold", command: .bold)
        formatToggle("Italic", command: .italic)
        formatToggle("Underline", command: .underline)
    }

    @ViewBuilder private var alignmentCommands: some View {
        formatToggle("Align Left", command: .alignLeft)
        formatToggle("Center", command: .alignCenter)
        formatToggle("Justify", command: .alignJustify)
        formatToggle("Align Right", command: .alignRight)
    }

    @ViewBuilder private var listCommands: some View {
        formatToggle("Bulleted list", command: .bulletList)
        formatToggle("Numbered list", command: .orderedList)
        if editor.documentFormat != .rtf { formatToggle("Checklist", command: .taskList) }
    }

    private func formatToggle(_ title: String, command: PadMarkdownFormatCommand) -> some View {
        Toggle(title, isOn: Binding(get: { editor.activeMarks.contains(command.rawValue) }, set: { _ in editor.format(command) }))
            .disabled(editor.formatAvailability[command.rawValue] != true)
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
