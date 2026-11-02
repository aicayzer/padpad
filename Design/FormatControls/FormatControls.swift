import AppKit
import SwiftUI

@main
struct FormatControlsApp: App {
    var body: some Scene {
        Window("Format Control Comparison", id: "comparison") {
            ComparisonView()
        }
        .defaultSize(width: 720, height: 900)
        .windowResizability(.contentMinSize)
    }
}

private enum Format: String, CaseIterable, Identifiable {
    case markdown = "Markdown", plainText = "Plain Text", rtf = "RTF"
    var id: Self { self }
}

@MainActor @Observable
private final class ExampleSelection {
    var enabled = Set(Format.allCases)
    var defaultFormat = Format.markdown
    var summary: String { enabled.count == 1 ? "1 format" : "\(enabled.count) formats" }
    var names: String { Format.allCases.filter { enabled.contains($0) }.map(\.rawValue).joined(separator: ", ") }

    func binding(for format: Format) -> Binding<Bool> {
        Binding(get: { self.enabled.contains(format) }, set: { self.set(format, enabled: $0) })
    }

    func set(_ format: Format, enabled newValue: Bool) {
        if newValue { enabled.insert(format) }
        else if enabled.count > 1 { enabled.remove(format) }
        if !enabled.contains(defaultFormat) {
            defaultFormat = Format.allCases.first { enabled.contains($0) }!
        }
    }
}

private enum Example: Int, CaseIterable, Identifiable {
    case automaticMenu, borderlessMenu, popup, borderlessPopup, pullDown
    case buttonPopover, borderlessPopover, disclosure, verticalChecks, horizontalChecks
    case switches, segments, listPopover, sheet

    var id: Self { self }
    var title: String {
        let names = [
            "System menu", "Borderless system menu", "AppKit pop-up button",
            "Borderless AppKit pop-up button", "AppKit pull-down button",
            "Button with checkbox popover", "Borderless button with checkbox popover",
            "Disclosure group", "Vertical checkboxes", "Horizontal checkboxes",
            "Separate switches", "Multiple-selection segmented control",
            "Button with selection list", "Button with sheet"
        ]
        return "\(rawValue + 1). \(names[rawValue])"
    }
    var detail: String {
        switch self {
        case .automaticMenu: "SwiftUI Menu with its automatic system style. Ticked items; closes after selection."
        case .borderlessMenu: "SwiftUI Menu with the system borderless style. Ticked items; closes after selection."
        case .popup: "NSPopUpButton with a separate count label and independently checked menu items. System-drawn double arrow and bezel."
        case .borderlessPopup: "The same NSPopUpButton with its native borderless appearance. No custom arrow or background."
        case .pullDown: "NSPopUpButton in pull-down mode. The count stays in the button; the menu contains ticked formats."
        case .buttonPopover, .borderlessPopover: "Standard system button and popover containing native checkboxes. Stays open for multiple changes. No imitation picker arrow."
        case .disclosure: "Native DisclosureGroup reveals checkboxes in the form. The section grows when expanded."
        case .verticalChecks: "All choices remain visible as native checkboxes in one row."
        case .horizontalChecks: "All choices remain visible as native checkboxes across one row. Requires more horizontal space."
        case .switches: "One native switch per format. Uses three settings rows."
        case .segments: "NSSegmentedControl with selectAny tracking. Each segment can be selected independently; this is not a single-choice SwiftUI picker."
        case .listPopover: "Native List with multiple selection inside a standard popover. Uses the standard Command-click and Shift-click selection behavior."
        case .sheet: "Standard button opens a native sheet containing checkboxes. Changes apply immediately; Done closes the sheet."
        }
    }
}

private struct ComparisonView: View {
    @State private var generation = 0

    var body: some View {
        Form {
            Section {
                Text("Compare enabled-format controls")
                    .font(.title2.bold())
                Text("Each example is independent. Changes here do not affect PadPad. Hover over a control, open it, then activate another window to compare its inactive appearance.")
                    .foregroundStyle(.secondary)
                Text("The Default format row uses the same single-selection SwiftUI Picker in every example. It is a reference, not an enabled-formats alternative.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Example.allCases) { example in
                ExampleView(example: example)
            }
        }
        .formStyle(.grouped)
        .id(generation)
        .frame(minWidth: 680, minHeight: 600)
        .toolbar {
            Button("Reset Examples") { generation += 1 }
        }
    }
}

private struct ExampleView: View {
    let example: Example
    @State private var selection = ExampleSelection()
    @State private var showingPopover = false
    @State private var showingSheet = false
    @State private var expanded = false

    var body: some View {
        @Bindable var selection = selection
        Section {
            control
            Picker("Default format", selection: $selection.defaultFormat) {
                ForEach(Format.allCases.filter { selection.enabled.contains($0) }) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .tint(.primary)
        } header: {
            Text(example.title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(example.detail)
                Text("Enabled: \(selection.names)")
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch example {
        case .automaticMenu:
            LabeledContent("Enabled formats") {
                formatMenu.menuStyle(.automatic).tint(.primary).fixedSize()
            }
        case .borderlessMenu:
            LabeledContent("Enabled formats") {
                formatMenu.menuStyle(.borderlessButton).tint(.primary).fixedSize()
            }
        case .popup, .borderlessPopup, .pullDown:
            LabeledContent("Enabled formats") {
                NativeFormatMenu(selection: selection, bordered: example != .borderlessPopup,
                                 pullsDown: example == .pullDown)
                    .fixedSize()
            }
        case .buttonPopover:
            LabeledContent("Enabled formats") {
                popoverButton.buttonStyle(.bordered).tint(.primary)
            }
        case .borderlessPopover:
            LabeledContent("Enabled formats") {
                popoverButton.buttonStyle(.borderless).tint(.primary)
            }
        case .disclosure:
            DisclosureGroup(isExpanded: $expanded) {
                FormatCheckboxes(selection: selection)
            } label: {
                LabeledContent("Enabled formats", value: selection.summary)
            }
        case .verticalChecks:
            LabeledContent("Enabled formats") {
                FormatCheckboxes(selection: selection)
            }
        case .horizontalChecks:
            LabeledContent("Enabled formats") {
                HStack(spacing: 12) { checks }
            }
        case .switches:
            ForEach(Format.allCases) { format in
                Toggle(format.rawValue, isOn: selection.binding(for: format))
                    .toggleStyle(.switch)
                    .disabled(selection.enabled == [format])
            }
        case .segments:
            LabeledContent("Enabled formats") {
                NativeFormatSegments(selection: selection).fixedSize()
            }
        case .listPopover:
            LabeledContent("Enabled formats") {
                Button(selection.summary) { showingPopover = true }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .popover(isPresented: $showingPopover) {
                        selectionList
                    }
            }
        case .sheet:
            LabeledContent("Enabled formats") {
                Button(selection.summary) { showingSheet = true }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .sheet(isPresented: $showingSheet) {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Enabled formats").font(.headline)
                            FormatCheckboxes(selection: selection)
                            HStack {
                                Spacer()
                                Button("Done") { showingSheet = false }
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(24)
                        .frame(width: 300)
                    }
            }
        }
    }

    private var formatMenu: some View {
        Menu(selection.summary) { checks }
    }

    private var checks: some View {
        ForEach(Format.allCases) { format in
            Toggle(format.rawValue, isOn: selection.binding(for: format))
                .toggleStyle(.checkbox)
                .disabled(selection.enabled == [format])
        }
    }

    private var popoverButton: some View {
        Button(selection.summary) { showingPopover = true }
            .popover(isPresented: $showingPopover) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enabled formats").font(.headline)
                    FormatCheckboxes(selection: selection)
                }
                .padding(16)
            }
    }

    private var selectionList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enabled formats").font(.headline)
            List(Format.allCases, selection: Binding(
                get: { selection.enabled },
                set: { formats in
                    guard !formats.isEmpty else { return }
                    for format in Format.allCases where formats.contains(format) { selection.set(format, enabled: true) }
                    for format in Format.allCases where !formats.contains(format) { selection.set(format, enabled: false) }
                }
            )) { format in
                Text(format.rawValue).tag(format)
            }
            .frame(width: 240, height: 110)
            Text("Command-click to select more than one format.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

private struct FormatCheckboxes: View {
    let selection: ExampleSelection
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Format.allCases) { format in
                Toggle(format.rawValue, isOn: selection.binding(for: format))
                    .toggleStyle(.checkbox)
                    .disabled(selection.enabled == [format])
            }
        }
    }
}

private struct NativeFormatMenu: NSViewRepresentable {
    let selection: ExampleSelection
    let bordered: Bool
    let pullsDown: Bool

    func makeCoordinator() -> Coordinator { Coordinator(selection: selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: pullsDown)
        button.isBordered = bordered
        button.usesItemFromMenu = false
        button.altersStateOfSelectedItem = false
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.setAccessibilityLabel("Enabled formats")
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, format) in Format.allCases.enumerated() {
            let item = NSMenuItem(title: format.rawValue, action: #selector(Coordinator.toggle(_:)), keyEquivalent: "")
            item.tag = index
            item.target = context.coordinator
            menu.addItem(item)
        }
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = selection
        // A separate menu item supplies the summary without changing a format's label.
        (button.cell as? NSPopUpButtonCell)?.menuItem = NSMenuItem(title: selection.summary, action: nil, keyEquivalent: "")
        for item in button.itemArray {
            let format = Format.allCases[item.tag]
            item.state = selection.enabled.contains(format) ? .on : .off
            item.isEnabled = selection.enabled != [format]
        }
        button.setAccessibilityValue(selection.summary)
        button.invalidateIntrinsicContentSize()
    }

    @MainActor final class Coordinator: NSObject {
        var selection: ExampleSelection
        init(selection: ExampleSelection) { self.selection = selection }
        @objc func toggle(_ item: NSMenuItem) {
            let format = Format.allCases[item.tag]
            selection.set(format, enabled: !selection.enabled.contains(format))
        }
    }
}

private struct NativeFormatSegments: NSViewRepresentable {
    let selection: ExampleSelection

    func makeCoordinator() -> Coordinator { Coordinator(selection: selection) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        NSSegmentedControl(labels: Format.allCases.map(\.rawValue), trackingMode: .selectAny,
                           target: context.coordinator, action: #selector(Coordinator.changed(_:)))
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = selection
        for (index, format) in Format.allCases.enumerated() {
            control.setSelected(selection.enabled.contains(format), forSegment: index)
            control.setEnabled(selection.enabled != [format], forSegment: index)
        }
    }
    @MainActor final class Coordinator: NSObject {
        var selection: ExampleSelection
        init(selection: ExampleSelection) { self.selection = selection }
        @objc func changed(_ control: NSSegmentedControl) {
            let selected = Set(Format.allCases.enumerated().compactMap { index, format in
                control.isSelected(forSegment: index) ? format : nil
            })
            guard !selected.isEmpty else { return }
            for format in Format.allCases where selected.contains(format) { selection.set(format, enabled: true) }
            for format in Format.allCases where !selected.contains(format) { selection.set(format, enabled: false) }
        }
    }
}
