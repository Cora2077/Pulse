import SwiftUI
import PulseCore

struct PlanAlertSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isChanging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(PulseLocalization.localizedString("alerts.settings.planToggle"), isOn: Binding(
                get: { appState.planAlerts.enabled },
                set: { enabled in
                    isChanging = true
                    Task {
                        await appState.planAlerts.setEnabled(enabled)
                        isChanging = false
                    }
                }
            ))
            .disabled(isChanging)
            Toggle(PulseLocalization.localizedString("alerts.settings.sectorToggle"), isOn: Binding(
                get: { appState.planAlerts.sectorEnabled },
                set: { enabled in
                    isChanging = true
                    Task { await appState.planAlerts.setSectorEnabled(enabled); isChanging = false }
                }
            )).disabled(isChanging)
            Text(appState.planAlerts.status).font(.caption).foregroundStyle(.secondary)
            Text(PulseLocalization.localizedString("alerts.settings.planHelp"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(PulseLocalization.localizedString("alerts.settings.sectorHelp"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = appState.planAlerts.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}
