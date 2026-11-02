import AppKit
import SwiftUI

struct EnabledFormatsPicker: NSViewRepresentable {
    let enabledFormats: [PadFormat]
    let setEnabled: (PadFormat, Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = true
        button.usesItemFromMenu = false
        button.altersStateOfSelectedItem = false
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.setAccessibilityLabel("Enabled formats")
        button.setAccessibilityIdentifier("enabledFormats")
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, format) in PadFormat.allCases.enumerated() {
            let item = NSMenuItem(title: format.name, action: #selector(Coordinator.toggle(_:)), keyEquivalent: "")
            item.tag = index
            item.target = context.coordinator
            item.setAccessibilityIdentifier("enableFormat-\(format.rawValue)")
            menu.addItem(item)
        }
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let summary = enabledFormats.count == 1 ? "1 format" : "\(enabledFormats.count) formats"
        // Keep the summary separate from the independently checked format items.
        (button.cell as? NSPopUpButtonCell)?.menuItem = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        button.isEnabled = isEnabled
        for item in button.itemArray {
            let format = PadFormat.allCases[item.tag]
            item.state = enabledFormats.contains(format) ? .on : .off
            item.isEnabled = enabledFormats != [format]
        }
        button.setAccessibilityValue(summary)
        button.invalidateIntrinsicContentSize()
    }

    @MainActor final class Coordinator: NSObject {
        var parent: EnabledFormatsPicker
        init(_ parent: EnabledFormatsPicker) { self.parent = parent }

        @objc func toggle(_ item: NSMenuItem) {
            let format = PadFormat.allCases[item.tag]
            parent.setEnabled(format, !parent.enabledFormats.contains(format))
        }
    }
}
