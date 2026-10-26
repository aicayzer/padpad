import Observation
import ServiceManagement

@MainActor
@Observable
final class LoginItemSettings {
    private(set) var status = SMAppService.mainApp.status
    private(set) var updating = false
    private(set) var error: String?

    var enabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) async {
        guard !updating else { return }
        updating = true
        defer { updating = false; refresh() }
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Couldn’t change the “Open at login” setting. Try again."
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
