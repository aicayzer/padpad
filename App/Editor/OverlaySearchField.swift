import AppKit
import SwiftUI

/// In a nonactivating AppKit panel, SwiftUI's initial focus request can leave the editor as
/// first responder. Transfer focus only after this field belongs to the key window.
struct OverlaySearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var fontSize: CGFloat = 15
    var fontWeight: NSFont.Weight = .regular
    var selectsTextOnFocus = false
    let isCurrent: () -> Bool
    let submit: () -> Void
    let dismiss: () -> Void
    var move: ((Int) -> Void)?
    var blur: (() -> Void)?

    func makeNSView(context: Context) -> OverlayTextField {
        let field = OverlayTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: OverlayTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        field.selectsTextOnFocus = selectsTextOnFocus
        field.isCurrent = isCurrent
        field.blur = blur
        if field.stringValue != text { field.stringValue = text }
        field.requestInitialFocus()
    }

    static func dismantleNSView(_ field: OverlayTextField, coordinator: Coordinator) {
        field.cancelFocus()
        field.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OverlaySearchField
        init(_ parent: OverlaySearchField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? OverlayTextField)?.recordFocus()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, parent.isCurrent() else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard parent.isCurrent() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.dismiss()
            case #selector(NSResponder.moveUp(_:)):
                guard let move = parent.move else { return false }
                move(-1)
            case #selector(NSResponder.moveDown(_:)):
                guard let move = parent.move else { return false }
                move(1)
            default: return false
            }
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? OverlayTextField, field.hasFocused else { return }
            let owner = parent
            // AppKit can emit this while installing the field editor. Check the
            // settled responder; outside clicks commit synchronously in the monitor.
            DispatchQueue.main.async { [weak field] in
                guard let field, field.currentEditor() == nil, owner.isCurrent() else { return }
                owner.blur?()
            }
        }
    }
}

final class OverlayTextField: NSTextField {
    var isCurrent: () -> Bool = { false }
    var selectsTextOnFocus = false
    var blur: (() -> Void)?
    private var outsideClickMonitor: Any?
    private(set) var hasFocused = false
    private var generation = 0
    private var scheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        generation += 1
        scheduled = false
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
            requestInitialFocus()
        }
    }

    @objc private func windowBecameKey() { requestInitialFocus() }

    func requestInitialFocus() {
        guard !hasFocused, !scheduled, window != nil, isCurrent() else { return }
        scheduled = true
        let request = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, request == self.generation else { return }
            self.scheduled = false
            guard !self.hasFocused, self.isCurrent(), let window = self.window, window.isKeyWindow else { return }
            let pending = window.firstResponder as? OverlayInputResponder
            self.hasFocused = window.makeFirstResponder(self)
            if self.hasFocused {
                self.recordFocus()
                if self.selectsTextOnFocus { self.selectText(nil) }
                for event in pending?.takeEvents() ?? [] {
                    guard self.isCurrent(), window.isKeyWindow else { break }
                    window.sendEvent(event)
                }
            }
        }
    }

    func recordFocus() {
        hasFocused = true
        watchOutsideClicks()
    }

    private func watchOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.hasFocused, self.isCurrent(), let window = self.window else { return event }
            // Find can stay visible after focus returns to the document. Its
            // monitor must not clear another control's responder on later clicks.
            guard window.firstResponder === self ||
                  self.currentEditor().map({ window.firstResponder === $0 }) == true else { return event }
            let inside = event.window === window && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            guard !inside else { return event }
            // A blank part of the header needn't become a responder to finish renaming.
            window.makeFirstResponder(nil)
            if self.isCurrent() { self.blur?() }
            return event
        }
    }

    isolated deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    func cancelFocus() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        blur = nil
        generation += 1
        scheduled = false
        isCurrent = { false }
        NotificationCenter.default.removeObserver(self)
    }
}

/// SwiftUI mounts the field after the shortcut returns. Keep those first keystrokes out of the document.
final class OverlayInputResponder: NSResponder {
    private var events: [NSEvent] = []
    var eventCount: Int { events.count }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { events.append(event) }
    func discardEvents() { events.removeAll() }
    func takeEvents() -> [NSEvent] {
        defer { discardEvents() }
        return events
    }
}
