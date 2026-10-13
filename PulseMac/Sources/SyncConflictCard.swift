import SwiftUI
import PulseCore

/// The production conflict card names the limited selection scope. Its actions
/// never imply replacing an entire device or account.
struct SyncConflictCard: View {
    let summary: FolderSyncController.ConflictSummary
    let isWorking: Bool
    let onChoose: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(PulseLocalization.localizedString("sync.conflict.detail", summary.count, String(summary.id.prefix(8))))
                .font(.caption).foregroundStyle(.orange)
            ForEach(summary.examples, id: \.self) { example in
                Text(example).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(PulseLocalization.localizedString("sync.conflict.warning"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder private var buttons: some View {
        Button(PulseLocalization.localizedString("sync.conflict.keepLocal")) { onChoose(false) }
            .accessibilityIdentifier("sync.conflict.local").disabled(isWorking)
        Button(PulseLocalization.localizedString("sync.conflict.useRemote")) { onChoose(true) }
            .accessibilityIdentifier("sync.conflict.remote")
            .buttonStyle(.borderedProminent).disabled(isWorking)
    }
}

extension FolderSyncController {
    static func conflictSummary(peerID: String, trades: [WatchlistSyncMerge.TransactionConflict],
                                allocations: [WatchlistSyncMerge.PositionAllocationConflict],
                                brokerage: WatchlistSyncMerge.BrokerageConflict?) -> ConflictSummary {
        let chinese = PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
        let settings = (brokerage?.settingKeys ?? []).map { key in
            let field: String
            switch key.field {
            case .cash: field = chinese ? "现金" : "Cash"
            case .poolLimit: field = chinese ? "仓位预算" : "Pool budget"
            case .scenario: field = chinese ? "预算情景" : "Budget scenario"
            case .sector: field = chinese ? "板块上限" : "Sector limit"
            }
            return "\(AccountIdentity.title(key.accountID)) · \(field) · \(key.key)"
        }
        let dependencies = (brokerage?.dependencyGroups ?? []).map { group in
            group.map { "\(AccountIdentity.title($0.accountID)) \($0.symbol.displayCode)" }.joined(separator: " ↔ ")
                + (chinese ? " · 关联记录整体选择" : " · linked records chosen together")
        }
        let examples = dependencies + settings + trades.map {
            "\(AccountIdentity.title($0.accountID)) · \($0.symbol.displayCode) · \($0.transactionID.uuidString.prefix(8))"
        } + allocations.map {
            "\(AccountIdentity.title($0.accountID)) · \($0.symbol.displayCode) · " + (chinese ? "仓位分账" : "Position allocation")
        }
        return .init(id: peerID, count: trades.count + allocations.count + settings.count + dependencies.count, examples: examples)
    }
}
