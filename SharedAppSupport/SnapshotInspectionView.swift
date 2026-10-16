import SwiftUI
import PulseCore

struct SnapshotInspectionTarget: Identifiable {
    let id = UUID()
    let title: String
    let snapshot: WatchlistSyncSnapshot
}

/// A frozen, read-only financial version. It never uses the live selection and
/// has no write, merge, clipboard-export or network capability.
struct SnapshotInspectionView: View {
    let target: SnapshotInspectionTarget
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("这是打开明细时冻结的只读版本，不会修改账本。请核对实际账户、成交日期、价量、计划及现金字段，不要只比较记录数量。")
                        .font(.footnote)
                }
                ForEach(Array(target.snapshot.allAccountItems.enumerated()), id: \.offset) { _, item in
                    Section("\(item.resolvedDisplayName) · \(item.symbol.description)") {
                        LabeledContent("持有数量", value: number(item.positionQuantity))
                        ForEach(item.transactions) { transaction in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(transaction.kind == .buy ? "买入" : transaction.kind == .sell ? "卖出" : "校准") \(number(transaction.quantity)) @ \(number(transaction.price)) \(item.symbol.currencyCode)")
                                    .fontWeight(.medium)
                                Text("\(account(transaction.brokerageAccountID)) · \(transaction.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let note = transaction.note { Text(note).font(.footnote) }
                                Text(transaction.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(item.plans) { plan in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(plan.kind == .buy ? "买入计划" : "卖出计划") · \(number(plan.quantity)) @ \(number(plan.price)) \(item.symbol.currencyCode)")
                                Text("状态：\(plan.status.rawValue) · 执行账户：\(account(plan.executionAccountID))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let note = plan.note { Text(note).font(.footnote) }
                            }
                        }
                    }
                }
                Section("完整字段（含账户现金、分仓、复盘和历史）") {
                    DisclosureGroup("展开完整只读快照") {
                        Text(encodedSnapshot).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("上方摘要不省略原始快照；高级分仓、现金、复盘检查点及计划条件以完整字段为准。返回后再决定是否选择整份版本。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(target.title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("返回核对") { dismiss() } } }
        }
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...6))) }
    private func account(_ value: BrokerageAccountID?) -> String {
        switch value {
        case .financing: "融资账户"
        case .mengmeng: "现金账户（mengmeng）"
        case .unassigned, nil: "待归属／未指定"
        }
    }
    private var encodedSnapshot: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(target.snapshot), let result = String(data: data, encoding: .utf8) else {
            return "完整字段无法呈现，请先返回，不要在未核对内容时选择整份覆盖。"
        }
        return result
    }
}
