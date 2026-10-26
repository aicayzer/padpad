import AppKit
@testable import Pad

/// Stands in for NSAlert: records each alert and answers it at once, so tests never show a modal.
@MainActor
final class AlertRecorder {
    private(set) var alerts: [PadAlert] = []
    private(set) var windows: [NSWindow?] = []
    /// Whether the recorder chooses the alert's action instead of Cancel or OK.
    var confirms = false

    var last: PadAlert? { alerts.last }

    var present: PadAlert.Presenter {
        { [self] alert, window, completion in
            alerts.append(alert)
            windows.append(window)
            completion(confirms)
        }
    }
}

/// The panel message PadPad shows for an error, or nil when it is an alert.
func expectedMessage(_ error: any Error, during context: PadProblem.Context) -> PadMessage? {
    if case .message(let message) = PadProblem(error, during: context) { message } else { nil }
}

/// The alert PadPad shows for an error, or nil when it is a panel message.
func expectedAlert(_ error: any Error, during context: PadProblem.Context) -> PadAlert? {
    if case .alert(let alert) = PadProblem(error, during: context) { alert } else { nil }
}

extension PadError {
    func message(during context: PadProblem.Context = .rename) -> PadMessage? { expectedMessage(self, during: context) }
    func alert(during context: PadProblem.Context = .save) -> PadAlert? { expectedAlert(self, during: context) }
}
