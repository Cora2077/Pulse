import SwiftUI
import PulseCore

struct PlanCreationContext: Identifiable {
    let id = UUID()
    let account: BrokerageAccountID
}

/// Mac NewTradePlanSheet: choose/search any supported symbol, then edit in
/// the same sheet. Choosing or cancelling never changes watchlist membership.
struct NewTradePlanPhoneSheet: View {
    let account: BrokerageAccountID
    @Environment(IPhoneAppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var target: PlanEditorTarget?

    var body: some View {
        if let target {
            PlanEditorView(target: target)
        } else {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(PulseLocalization.localizedString("plan.new.account", state.accountName(account)))
                            .font(.caption).foregroundStyle(.secondary)
                        if state.accountID != account {
                            Text("账户已切换，请返回原账户或重新打开新建计划，未写入任何内容。")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        NewPlanSymbolChooser(onSelect: { info in
                            guard state.accountID == account else { return }
                            target = .create(info: info, account: account)
                        }, account: account)
                    }.padding(16)
                }
                .navigationTitle(PulseLocalization.localizedString("plan.newPlan"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                }
            }
        }
    }
}
