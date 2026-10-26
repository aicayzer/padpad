import AppKit

/// A message for the pill at the bottom left of the editor card.
struct PadMessage: Equatable {
    let text: String
    var hint: String?
}

/// A problem that needs a decision or blocks work, shown as a native alert.
struct PadAlert: Equatable {
    /// The next step the alert offers. Each one runs an existing command.
    enum Action: Equatable {
        case saveAs, openSettings, chooseFile

        var title: String {
            switch self {
            case .saveAs: "Save As…"
            case .openSettings: "Open Settings"
            case .chooseFile: "Choose File…"
            }
        }
    }

    let title: String
    let message: String
    var action: Action?

    /// An alert with a next step offers it as the default button beside Cancel; otherwise it offers OK.
    var buttons: [String] { action.map { [$0.title, "Cancel"] } ?? ["OK"] }

    /// Shows an alert, then reports whether the person chose its action.
    typealias Presenter = @MainActor (PadAlert, NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void

    /// Presents a sheet on `window`, or an app-modal alert when there is no visible window.
    @MainActor static func presentSystem(_ alert: PadAlert, in window: NSWindow?, completion: @escaping @MainActor (Bool) -> Void) {
        let panel = NSAlert()
        panel.messageText = alert.title
        panel.informativeText = alert.message
        for button in alert.buttons { panel.addButton(withTitle: button) }
        let hasAction = alert.action != nil
        NSApp.activate()
        if let window, window.isVisible {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { completion(hasAction && response == .alertFirstButtonReturn) }
            }
        } else {
            // Let the failed operation finish before starting a modal session.
            DispatchQueue.main.async {
                panel.window.level = .modalPanel
                completion(hasAction && panel.runModal() == .alertFirstButtonReturn)
            }
        }
    }
}

/// The single rule for how PadPad reports a failure: a small problem with an obvious fix is a
/// message in the panel; a problem that needs a decision or blocks work is an alert.
enum PadProblem: Equatable {
    case message(PadMessage)
    case alert(PadAlert)

    /// What PadPad was doing. The same error can need a different next step.
    enum Context: Equatable {
        case open, read, save, saveAs, rename, share, print, copy, editor
        /// Reading the latest text from the editor before another action.
        case snapshot
        /// Making a file name from the naming format in Settings.
        case nameFormat
    }

    init(_ error: any Error, during context: Context) {
        // The editor's own errors are momentary: waiting or retrying fixes them.
        if let error = error as? PadMarkdownEditorError {
            self = .message(error.message)
            return
        }
        switch context {
        case .snapshot: self = .message(Self.snapshotFailed); return
        case .editor: self = .message(Self.editorFailed); return
        case .copy: self = .message(Self.copyFailed); return
        default: break
        }
        if let error = error as? PadError {
            self = Self.classify(error, during: context)
        } else if let error = error as? CocoaError, let problem = Self.classify(error.code, during: context) {
            self = problem
        } else {
            self = Self.failed(context)
        }
    }

    private static func classify(_ error: PadError, during context: Context) -> PadProblem {
        let keepsText = context != .open
        switch error {
        case .emptyName: return .message(PadMessage(text: "Enter a file name."))
        case .nameTooLong: return .message(PadMessage(text: "This file name is too long. Try a shorter one."))
        case .invalidName: return .message(PadMessage(text: "This file name isn’t valid. Try another name."))
        case .nameExists: return .message(nameExists)
        case .emptyShare: return .message(PadMessage(text: "Write something before sharing."))
        case .unsupported where context == .open:
            return .alert(PadAlert(title: "PadPad can’t open this type of file",
                                   message: "Choose a Markdown (.md) or plain text (.txt) file.", action: .chooseFile))
        case .unsupported:
            return .alert(PadAlert(title: "PadPad can’t save this type of file",
                                   message: "Save it as a Markdown (.md) or plain text (.txt) file.", action: .saveAs))
        case .encoding:
            return .alert(PadAlert(title: "This file’s text encoding isn’t supported",
                                   message: keepsText ? keepCopy : "PadPad opens files saved as UTF-8 text.",
                                   action: keepsText ? .saveAs : nil))
        case .changed:
            return .alert(PadAlert(title: "This file was changed elsewhere",
                                   message: "To keep your changes, save them as a new file.", action: .saveAs))
        case .missingFolder:
            return .alert(PadAlert(title: "The save folder isn’t available",
                                   message: "Choose another folder in Settings.", action: .openSettings))
        case .renamePermission:
            return .alert(PadAlert(title: "PadPad doesn’t have access to this folder",
                                   message: "To rename the file, save a copy with the new name.", action: .saveAs))
        }
    }

    private static func classify(_ code: CocoaError.Code, during context: Context) -> PadProblem? {
        let keepsText = context != .open
        switch code {
        case .fileReadNoSuchFile:
            return .alert(PadAlert(title: "This file is no longer available",
                                   message: keepsText ? keepCopy : "It may have been moved or deleted.",
                                   action: keepsText ? .saveAs : nil))
        case .fileReadNoPermission:
            return .alert(PadAlert(title: "PadPad can’t access this file",
                                   message: keepsText ? keepCopy : "Choose the file again to give PadPad access.",
                                   action: keepsText ? .saveAs : .chooseFile))
        case .fileWriteNoPermission:
            return .alert(PadAlert(title: "PadPad can’t save in this folder",
                                   message: "Save the file in another folder.", action: .saveAs))
        case .fileWriteOutOfSpace:
            return .alert(PadAlert(title: "There isn’t enough space to save",
                                   message: "Free up some storage, then try again."))
        case .fileWriteFileExists:
            return .message(nameExists)
        default:
            return nil
        }
    }

    private static func failed(_ context: Context) -> PadProblem {
        switch context {
        case .open:
            .alert(PadAlert(title: "Couldn’t open this file", message: "Try opening it again."))
        case .read:
            .alert(PadAlert(title: "Couldn’t read this file", message: keepCopy, action: .saveAs))
        case .save, .saveAs, .nameFormat:
            .alert(PadAlert(title: "Couldn’t save your changes",
                            message: "Try again, or save a copy in another folder.", action: .saveAs))
        case .share:
            .alert(PadAlert(title: "Couldn’t share this file", message: "Try sharing it again."))
        case .print:
            .alert(PadAlert(title: "Couldn’t print", message: "Try printing again."))
        case .rename:
            .message(PadMessage(text: "Couldn’t rename this file.", hint: "Try another name or choose “Save As”."))
        case .copy: .message(copyFailed)
        case .snapshot: .message(snapshotFailed)
        case .editor: .message(editorFailed)
        }
    }

    private static let keepCopy = "To keep your text, save it as a new file."
    private static let nameExists = PadMessage(text: "A file with this name already exists.", hint: "Choose another name.")
    private static let snapshotFailed = PadMessage(text: "Couldn’t read your text. Try again.")
    private static let editorFailed = PadMessage(text: "The editor couldn’t complete that action. Your text is still open.")
    private static let copyFailed = PadMessage(text: "Couldn’t copy your text. Try again.")
}

extension PadMarkdownEditorError {
    var message: PadMessage {
        switch self {
        case .composing: PadMessage(text: "Finish typing before saving or closing.")
        case .notReady: PadMessage(text: "The editor is still loading. Try again in a moment.")
        case .documentChanged: PadMessage(text: "Your text changed. Try again.")
        case .invalidResponse: PadMessage(text: "Couldn’t read your text. Try again.")
        case .unavailable: PadMessage(text: "The editor is unavailable. Your text is still open.")
        case .script: PadMessage(text: "The editor couldn’t complete that action. Your text is still open.")
        case .snapshotRejected(let code, _):
            switch code {
            case "composition": PadMessage(text: "Finish typing before saving or closing.")
            case "not-ready": PadMessage(text: "The editor is still loading. Try again in a moment.")
            case "stale-document": PadMessage(text: "Your text changed. Try again.")
            case "operation-pending": PadMessage(text: "The editor is finishing a paste. Try again in a moment.")
            default: PadMessage(text: "Couldn’t preserve your text. Try again.")
            }
        }
    }
}

extension PadMarkdownEditorFeedback {
    /// Editor feedback is always a small problem shown in the panel.
    var message: PadMessage {
        switch (source, code) {
        case (.clipboard, "diagram-unavailable"):
            PadMessage(text: "Some diagrams couldn’t be exported. Their Markdown source is retained.")
        case (.clipboard, "image-unavailable"):
            PadMessage(text: "Some images couldn’t be exported. Their Markdown references are retained.")
        case (.clipboard, _):
            PadMessage(text: "Couldn’t copy that content. Try again.")
        case (.print, _):
            PadMessage(text: "Some content couldn’t be included in the printout.")
        case (.edit, "preservation"):
            PadMessage(text: "Couldn’t apply that edit. Your text is unchanged.")
        case (.edit, "composition"):
            PadMessage(text: "Finish typing, then try that action again.")
        case (.edit, "not-ready"):
            PadMessage(text: "The editor is still loading. Try again in a moment.")
        case (.edit, "operation-pending"):
            PadMessage(text: "The editor is finishing a paste. Try again in a moment.")
        case (.edit, "read-only"):
            PadMessage(text: "This content is read-only.")
        case (.edit, "stale-document"):
            PadMessage(text: "The document changed. Try that action again.")
        case (.edit, "image-unavailable"):
            PadMessage(text: "Couldn’t add that image.")
        case (.edit, "file-unavailable"):
            PadMessage(text: "Couldn’t add that file.")
        default:
            PadMessage(text: "The editor couldn’t complete that action.")
        }
    }
}
