import Foundation
import InkKitRTF

// Switching an unsaved draft between Markdown, plain text and RTF.
extension PadDocument {
    var nextFormat: PadFormat? {
        guard !drafts.enabledFormats.isEmpty else { return nil }
        guard let index = drafts.enabledFormats.firstIndex(of: currentFormat) else { return drafts.enabledFormats.first }
        let next = drafts.enabledFormats[(index + 1) % drafts.enabledFormats.count]
        return next == currentFormat ? nil : next
    }

    func cycleFormat() async {
        guard let nextFormat else { return }
        await changeFormat(to: nextFormat)
    }

    /// Switches an unsaved quick-pad draft to another format. Markdown and plain text keep the exact source;
    /// RTF converts, and a conversion that loses something changes nothing until the person confirms it.
    func changeFormat(to target: PadFormat) async {
        guard isQuickPad, url == nil, !isBusy, !onboarding.isPresented,
              drafts.enabledFormats.contains(target), target != currentFormat else { return }
        operation = .transition
        defer { operation = nil }
        guard await captureLatestEditor(), drafts.enabledFormats.contains(target) else { return }
        let id = documentID
        guard let conversion = await confirmedConversion(of: text, to: target, savingCopy: false, requiresEnabledFormat: true),
              documentID == id, drafts.enabledFormats.contains(target) else {
            show()
            panel?.resumeEditor()
            return
        }
        replaceDraft(format: target, text: conversion.text)
        reloadEditor()
        error = nil
        notice = nil
        updateTitle()
        show()
        panel?.resumeEditor()
    }

    /// Changes a draft's format and text together. An empty text is valid in every format.
    func replaceDraft(format newFormat: PadFormat, text newText: String) {
        scratchFormat = newFormat
        text = newText
    }

    /// Converts text from the current format. Markdown and plain text share their source. Markdown and RTF
    /// convert in the editor; plain text and RTF convert with InkKitRTF.
    private func convert(_ content: String, to target: PadFormat) async throws -> PadConversion {
        let sharedSource: Set<PadFormat> = [.md, .txt]
        if currentFormat == target || (sharedSource.contains(currentFormat) && sharedSource.contains(target)) {
            return PadConversion(text: content, changes: [])
        }
        switch (currentFormat, target) {
        case (.txt, .rtf):
            // RTF can't hold U+0000 or U+FFFC as text, so InkKitRTF replaces them with U+FFFD.
            let replaced = content.unicodeScalars.contains { $0 == "\u{0}" || $0 == "\u{FFFC}" }
            return PadConversion(text: try PadRichText.text(for: RichTextDocument(plainText: content)),
                                 changes: replaced ? PadFormatLoss.changes(for: ["invalid-character"]) : [])
        case (.rtf, .txt):
            return PadConversion(text: try PadRichText.document(from: content).plainText, changes: PadFormatLoss.plainText)
        default:
            guard let editorConversion else { throw PadMarkdownEditorError.unavailable }
            return try await editorConversion(target)
        }
    }

    /// The converted text, or nil when the conversion failed or the person kept the original.
    func confirmedConversion(of content: String, to target: PadFormat, savingCopy: Bool,
                                     requiresEnabledFormat: Bool = false) async -> PadConversion? {
        let id = documentID
        let conversion: PadConversion
        do {
            conversion = try await convert(content, to: target)
        } catch {
            report(error, during: .convert)
            return nil
        }
        guard documentID == id, !requiresEnabledFormat || drafts.enabledFormats.contains(target) else { return nil }
        if conversion.changes.isEmpty { return conversion }
        let alert = PadAlert.conversion(to: target, savingCopy: savingCopy, changes: conversion.changes)
        guard await confirm(alert), documentID == id else { return nil }
        return conversion
    }
}
