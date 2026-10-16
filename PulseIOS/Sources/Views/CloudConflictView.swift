import SwiftUI
import PulseCore
import PulseSync

struct CloudConflictView: View {
    @Environment(IPhoneAppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Bool?
    @State private var inspection: SnapshotInspectionTarget?
    var body: some View {
        NavigationStack {
            List {
                Section("不自动覆盖你的账本") {
                    Text("两端都保留了修改。选择前会额外保存双方完整快照；如果确认时任一版本又变了，将要求重新核对。")
                    Text(state.syncStatus).font(.footnote).foregroundStyle(.secondary)
                }
                if let conflict = state.syncConflict {
                    Section("待核对版本") {
                        LabeledContent("本机成交记录数", value: "\(count(conflict.localPending?.snapshot))")
                        LabeledContent("云端成交记录数", value: "\(count(conflict.remote.snapshot))")
                        if let local = conflict.localPending?.snapshot {
                            Button("查看本机版本明细（只读）") { inspection = SnapshotInspectionTarget(title: "本机待同步版本", snapshot: local) }
                        }
                        Button("查看云端版本明细（只读）") { inspection = SnapshotInspectionTarget(title: "云端版本", snapshot: conflict.remote.snapshot) }
                        Text("记录数仅帮助识别版本，数量相等不代表内容相同。整份选择可能放弃另一端未合并的修改，备份不会被删除。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("使用本机整份版本") { choice = true }
                        Button("使用云端整份版本", role: .destructive) { choice = false }
                    } footer: { Text("无法确认时请先返回，不必立刻选。此版本不做静默金融数据合并。") }
                }
            }
            .sheet(item: $inspection) { SnapshotInspectionView(target: $0) }
            .navigationTitle("核对同步冲突")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } } }
            .confirmationDialog("确认选择整份账本版本？", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }), titleVisibility: .visible) {
                Button("备份双方后确认", role: .destructive) {
                    if choice == true { state.keepLocalSyncVersion() } else { state.acceptRemoteSyncVersion() }
                    choice = nil; dismiss()
                }
                Button("继续核对", role: .cancel) { choice = nil }
            }
        }
    }
    private func count(_ snapshot: WatchlistSyncSnapshot?) -> Int {
        snapshot?.allAccountItems.reduce(0) { $0 + $1.transactions.count } ?? 0
    }
}
