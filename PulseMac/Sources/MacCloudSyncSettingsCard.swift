import SwiftUI

struct MacCloudSyncSettingsCard: View {
    @Environment(AppState.self) private var appState
    @State private var choice: Bool?
    @State private var inspection: SnapshotInspectionTarget?
    var body: some View {
        GroupBox("与 iPhone 同步") {
            VStack(alignment: .leading, spacing: 9) {
                Toggle("使用私有 iCloud 同步（重启后生效）", isOn: Binding(
                    get: { appState.cloudSyncRequested },
                    set: { appState.requestPrivateCloudSync($0) }))
                Text("默认关闭。需要同一已授权的 CloudKit 容器和签名权限，不会自动迁移现有文件夹同步，也不会自动合并金融记录冲突。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = appState.cloudSyncConfigurationError {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                if let controller = appState.cloudSync?.controller {
                    Text(controller.statusText).font(.caption)
                    Button("立即核对云端版本") { controller.synchronize() }
                    if let conflict = controller.conflict {
                        if let local = conflict.localPending?.snapshot {
                            Button("查看本机版本明细（只读）") { inspection = SnapshotInspectionTarget(title: "本机待同步版本", snapshot: local) }
                        }
                        Button("查看云端版本明细（只读）") { inspection = SnapshotInspectionTarget(title: "云端版本", snapshot: conflict.remote.snapshot) }
                        Text("双方版本均保留。整份选择前会保存双方备份；无法确认时可以保持不处理。")
                            .font(.caption).foregroundStyle(.orange)
                        HStack {
                            Button("保留本机整份") { choice = true }
                            Button("接受云端整份") { choice = false }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .sheet(item: $inspection) { SnapshotInspectionView(target: $0).frame(minWidth: 480, minHeight: 560) }
        .confirmationDialog("备份双方后，确认选择整份账本？", isPresented: Binding(
            get: { choice != nil }, set: { if !$0 { choice = nil } }), titleVisibility: .visible) {
            Button("确认选择", role: .destructive) {
                if choice == true { appState.cloudSync?.controller.resolveKeepingLocal() }
                else { appState.cloudSync?.controller.resolveAcceptingRemote() }
                choice = nil
            }
            Button("继续核对", role: .cancel) { choice = nil }
        }
    }
}
