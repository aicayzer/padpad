import AppKit
import KeyboardShortcuts
import Observation

enum EditingAction: String, CaseIterable, Identifiable, Codable {
    case newFile, open, save, saveAs, restoreDefaultSize, copyAllContents

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newFile: "New Draft"
        case .open: "Open File"
        case .save: "Save"
        case .saveAs: "Save As"
        case .restoreDefaultSize: "Restore Default Size"
        case .copyAllContents: "Copy All Contents"
        }
    }
    var defaultShortcut: KeyboardShortcuts.Shortcut {
        switch self {
        case .newFile: .init(.n, modifiers: .command)
        case .open: .init(.o, modifiers: .command)
        case .save: .init(.s, modifiers: .command)
        case .saveAs: .init(.s, modifiers: [.command, .shift])
        case .restoreDefaultSize: .init(.zero, modifiers: .command)
        case .copyAllContents: .init(.c, modifiers: [.command, .shift])
        }
    }
}

@MainActor
@Observable
final class EditingShortcuts {
    private static let preferenceKey = "pad.editingShortcuts"
    private let defaults: UserDefaults
    private let globalShortcut: () -> KeyboardShortcuts.Shortcut?
    private var shortcuts: [EditingAction: KeyboardShortcuts.Shortcut]
    private(set) var error: String?

    init(defaults: UserDefaults = .standard,
         globalShortcut: @escaping () -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: .pad) }) {
        self.defaults = defaults
        self.globalShortcut = globalShortcut
        if let data = defaults.data(forKey: Self.preferenceKey),
           let saved = try? JSONDecoder().decode([EditingAction: KeyboardShortcuts.Shortcut?].self, from: data) {
            shortcuts = saved.compactMapValues { $0 }
            // Missing original actions were explicitly disabled. Only newly introduced
            // actions receive defaults, and existing assignments always take priority.
            for action in [EditingAction.restoreDefaultSize, .copyAllContents] where !saved.keys.contains(action) {
                let shortcut = action.defaultShortcut
                if globalShortcut() != shortcut && !shortcuts.values.contains(shortcut) {
                    shortcuts[action] = shortcut
                }
            }
        } else {
            shortcuts = Self.standardShortcuts
            for action in [EditingAction.restoreDefaultSize, .copyAllContents] where globalShortcut() == action.defaultShortcut {
                shortcuts[action] = nil
            }
        }
    }

    private static var standardShortcuts: [EditingAction: KeyboardShortcuts.Shortcut] {
        Dictionary(uniqueKeysWithValues: EditingAction.allCases.map { ($0, $0.defaultShortcut) })
    }

    var isDefault: Bool { shortcuts == Self.standardShortcuts }

    func shortcut(for action: EditingAction) -> KeyboardShortcuts.Shortcut? { shortcuts[action] }

    func action(for event: NSEvent) -> EditingAction? {
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return nil }
        return EditingAction.allCases.first { shortcuts[$0] == shortcut }
    }

    func validate(_ shortcut: KeyboardShortcuts.Shortcut, for action: EditingAction) -> KeyboardShortcuts.ValidationResult {
        guard shortcut.modifiers.contains(.command), shortcut.toSwiftUI != nil else {
            return .disallow(reason: "Choose a shortcut that includes Command.")
        }
        // Keep native editing, navigation, and application commands available.
        let nativeCommands: [KeyboardShortcuts.Shortcut] = [
            .init(.a, modifiers: .command), .init(.c, modifiers: .command),
            .init(.v, modifiers: .command), .init(.v, modifiers: [.command, .shift]),
            .init(.v, modifiers: [.command, .option, .shift]), .init(.x, modifiers: .command),
            .init(.z, modifiers: .command), .init(.z, modifiers: [.command, .shift]),
            .init(.f, modifiers: .command), .init(.h, modifiers: .command),
            .init(.h, modifiers: [.command, .option]), .init(.m, modifiers: .command),
            .init(.m, modifiers: [.command, .option]), .init(.w, modifiers: .command),
            .init(.w, modifiers: [.command, .option]), .init(.q, modifiers: .command),
            .init(.comma, modifiers: .command), .init(.r, modifiers: .command)
        ]
        let navigationKeys: Set<KeyboardShortcuts.Key> = [.leftArrow, .rightArrow, .upArrow, .downArrow, .delete, .deleteForward]
        if nativeCommands.contains(shortcut) || shortcut.key.map({ navigationKeys.contains($0) }) == true {
            return .disallow(reason: "PadPad or macOS already uses this shortcut. Choose another one.")
        }
        if globalShortcut() == shortcut {
            return .disallow(reason: "This shortcut already shows or hides PadPad. Choose another one.")
        }
        if let other = EditingAction.allCases.first(where: { $0 != action && shortcuts[$0] == shortcut }) {
            return .disallow(reason: "“\(other.title)” already uses this shortcut. Choose another one.")
        }
        return .allow
    }

    func validateGlobal(_ shortcut: KeyboardShortcuts.Shortcut) -> KeyboardShortcuts.ValidationResult {
        if let action = EditingAction.allCases.first(where: { shortcuts[$0] == shortcut }) {
            return .disallow(reason: "“\(action.title)” already uses this shortcut. Choose another one.")
        }
        return .allow
    }

    @discardableResult
    func set(_ shortcut: KeyboardShortcuts.Shortcut?, for action: EditingAction) -> Bool {
        if let shortcut, case .disallow(let reason) = validate(shortcut, for: action) {
            error = reason
            return false
        }
        shortcuts[action] = shortcut
        persist()
        return true
    }

    func restoreDefaults() {
        if let global = globalShortcut(), Self.standardShortcuts.values.contains(global) {
            error = "One of these defaults shows or hides PadPad. Change that shortcut first."
            return
        }
        shortcuts = Self.standardShortcuts
        persist()
    }

    private func persist() {
        let saved = Dictionary(uniqueKeysWithValues: EditingAction.allCases.map { ($0, shortcuts[$0]) })
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.preferenceKey)
        }
        error = nil
    }
}
