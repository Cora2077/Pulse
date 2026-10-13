import SwiftUI
import PulseCore

/// Allocation candidates and the *complete* peer conflict selection scope share
/// one sheet. A choice must never hide the trades or settings it also affects.
struct PoolSyncConflictSheet: View {
    let peerID: String
    let conflicts: [FolderSyncController.PositionAllocationConflictSummary]
    let summary: FolderSyncController.ConflictSummary?
    let isWorking: Bool
    var errorMessage: String? = nil
    let onResolve: (Bool) -> Void
    var onResolved: (() -> Void)? = nil
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy("仓位分账同步冲突", "Position allocation sync conflict"))
                    .font(.system(size: 18, weight: .semibold))
                Text(copy("设备 \(peerID.prefix(8)) · \(conflicts.count) 项关联分账", "Device \(peerID.prefix(8)) · \(conflicts.count) linked allocations"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 7) {
                            Text("\(AccountIdentity.title(conflict.accountID)) · \(conflict.symbol.displayCode)")
                                .font(.system(size: 11, weight: .semibold))
                            HStack(alignment: .top, spacing: 12) {
                                candidate(copy("此设备", "This device"), conflict.local)
                                candidate(copy("对端设备", "Other device"), conflict.remote)
                            }
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if let summary {
                        SyncConflictCard(summary: summary, isWorking: isWorking, onChoose: onResolve)
                    } else {
                        Text(copy("冲突已变化，请关闭后重新核对。", "The conflicts changed. Close and review again."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Button(copy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(20).frame(width: 620, height: 480)
        .onChange(of: hasResolved) { _, resolved in
            // A refused or refreshed choice keeps the sheet and reason visible.
            // Observe the cleared scope too: a fast async write may finish
            // between frames without rendering its intermediate busy state.
            if resolved { onResolved?() }
        }
    }

    private var hasResolved: Bool { !isWorking && summary == nil && errorMessage == nil }

    private func candidate(_ title: String, _ allocation: PositionAllocation?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(PoolType.labelMedium).foregroundStyle(.secondary)
            if let allocation {
                ForEach(PositionPool.activeCases, id: \.self) { pool in
                    let quantity = allocation.portions.filter { $0.pool.effectivePurpose == pool }.reduce(0) { $0 + $1.quantity }
                    if quantity > 0 {
                        Text("\(pool.title) \(PlanValueText.formattedQuantity(quantity))")
                            .font(PoolType.label.monospacedDigit())
                    }
                }
            } else {
                Text(copy("无分配", "No allocation")).font(PoolType.label).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}
