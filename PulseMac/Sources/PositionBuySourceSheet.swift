import SwiftUI
import PulseCore
import PulseUI

/// Connects an existing card to an already recorded buy in its own ledger.
struct PositionBuySourceSheet: View {
    let item: WatchItem
    let portion: PositionPortion
    let allocation: PositionAllocation
    let account: BrokerageAccountID
    let onCancel: () -> Void
    let onSuccess: () -> Void
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    @State private var selectedID: UUID?
    @State private var errorMessage: String?
    @State private var draftAccount: BrokerageAccountID

    init(item: WatchItem, portion: PositionPortion, allocation: PositionAllocation,
         account: BrokerageAccountID, onCancel: @escaping () -> Void,
         onSuccess: @escaping () -> Void, isWriteBlocked: Bool = false) {
        self.item = item
        self.portion = portion
        self.allocation = allocation
        self.account = account
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.isWriteBlocked = isWriteBlocked
        _selectedID = State(initialValue: allocation.resolvedBuyOrigins(for: item)[portion.id]?.transactionID)
        _draftAccount = State(initialValue: account)
    }

    private var sources: [PositionTransaction] {
        allocation.availableBuySources(for: portion.id, item: item)
    }
    private var accountChanged: Bool { draftAccount != appState.watchlist.activeBrokerageAccountID }
    private var canSave: Bool {
        !isWriteBlocked && !accountChanged && selectedID != nil
            && sources.contains { $0.id == selectedID }
            && !(portion.origin.kind == .buy && portion.origin.transactionID == selectedID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(copy("关联买入成交", "Link recorded buy"))
                    .font(.system(size: 18, weight: .semibold))
                Text("\(item.resolvedDisplayName) · \(item.symbol.displayCode) · \(quantity(portion.quantity)) \(copy("股", "shares"))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(copy("选择这张仓位卡对应的已录入买入，卡片将显示该笔的日期与成交价。",
                      "Choose the recorded buy for this card to show its date and trade price."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if sources.isEmpty {
                Text(copy("当前账本没有可关联的买入成交。已关联到其他卡片的份额不能重复使用。",
                          "No eligible buy is available in this ledger. Shares linked to other cards cannot be used twice."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(sources) { source in
                            Button {
                                selectedID = source.id
                                errorMessage = nil
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedID == source.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selectedID == source.id ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(source.date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.system(size: 12, weight: .medium))
                                        Text("\(copy("成交价", "Trade price")) \(PriceFormatter.price(source.price, market: item.symbol.market)) · \(quantity(source.quantity)) \(copy("股", "shares"))")
                                            .font(.system(size: 12).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedID == source.id ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(source.date.formatted(date: .numeric, time: .omitted)) · \(copy("成交价", "Trade price")) \(PriceFormatter.price(source.price, market: item.symbol.market)) · \(quantity(source.quantity)) \(copy("股", "shares"))")
                            .accessibilityAddTraits(selectedID == source.id ? .isSelected : [])
                        }
                    }
                }
                .frame(height: min(CGFloat(sources.count) * 69, 240))
            }
            if accountChanged { AccountDraftNotice(account: draftAccount) }
            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(copy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("确认关联", "Link buy"), action: submit)
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(22).frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func submit() {
        guard canSave, let selectedID else { return }
        guard !appState.folderSync.positionAllocationConflicts.contains(where: { $0.symbol == item.symbol }) else {
            errorMessage = copy("该标的存在同步冲突，请先核对。", "Resolve the sync conflict for this instrument first.")
            return
        }
        do {
            _ = try appState.watchlist.linkPositionPortionToBuy(symbol: item.symbol, portionID: portion.id,
                transactionID: selectedID, expectedRevision: allocation.revision)
            onSuccess()
        } catch {
            errorMessage = copy("关联未保存，仓位或成交可能已变化。请重新打开后选择。",
                                "The link was not saved. The position or trade may have changed; reopen and choose again.")
        }
    }

    private func quantity(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }
    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}
