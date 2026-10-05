import SwiftUI

struct PlanAlertSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isChanging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("交易计划到价提醒", isOn: Binding(
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
            Toggle("板块暴露超限提醒", isOn: Binding(
                get: { appState.planAlerts.sectorEnabled },
                set: { enabled in
                    isChanging = true
                    Task { await appState.planAlerts.setSectorEnabled(enabled); isChanging = false }
                }
            )).disabled(isChanging)
            Text(appState.planAlerts.status).font(.caption).foregroundStyle(.secondary)
            Text("应用运行时监测全部证券账号；通知会注明账号，点击打开对应计划。每个计划提醒一次，编辑或暂缓后可再次提醒。延迟行情会按其时间判断。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("板块上限按证券账号在今日工作台设置；同一账号的板块、上限每天提醒一次。仅在该币种全部持仓报价有效时发送。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = appState.planAlerts.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}
