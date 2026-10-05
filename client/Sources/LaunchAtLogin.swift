import ServiceManagement
import SwiftUI

/// "Open at Login" via `SMAppService.mainApp` — the app registers itself as a login item, which
/// shows up (and can be turned off) under System Settings › General › Login Items.
///
/// Applies immediately rather than on Settings' Save: it's a system registration, not a stored
/// preference, and the status is re-read from the service so the toggle can never disagree with
/// what macOS actually has.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var errorText: String?

    var body: some View {
        Toggle(isOn: Binding(get: { status == .enabled }, set: set)) {
            Text(t("Open at login"))
        }
        if status == .requiresApproval {
            HStack {
                Text(t("macOS needs your approval in Login Items."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(t("Open Login Items…")) { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let errorText {
            Text(errorText)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorText = nil
        } catch {
            Logger.log("App", "Login item \(enabled ? "register" : "unregister") failed: \(error)")
            errorText = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
