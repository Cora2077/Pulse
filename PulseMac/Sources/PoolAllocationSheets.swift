import SwiftUI
import PulseCore
import PulseUI

/// Splits one real portion and moves the named quantity into an actual holding
/// role.
///
/// The destination starts deliberately empty. A sheet that pre-picked a target
/// would let a stray Return move real shares into a purpose nobody chose, so
/// the placeholder is the only initial state and only an explicit pick enables
/// the confirmation. Unassigned is never on offer: it is a backlog state, not a
/// holding role, and legacy unassigned shares enter this sheet as its *source*,
/// not as its target.
///
/// Internal rather than private so the DEBUG harness can instantiate the actual
/// production form instead of a look-alike.
struct PoolTransferSheet: View {
    private static let placeholderTag: PositionPool? = nil

    let item: WatchItem
    let portion: PositionPortion
    let allocation: PositionAllocation
    let initialDestination: PositionPool?
    let onCancel: () -> Void
    let onSuccess: (PositionAllocation, PositionAllocation) -> Void
    /// Preview withholds this sheet; the flag is the last line of defence.
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    /// Optional by design: `nil` is the placeholder, not a hidden default.
    @State private var destination: PositionPool?
    @State private var amount: String
    @State private var reason = ""
    @State private var errorMessage: String?

    /// `initialAmount` exists for the synthetic native renders, which need the
    /// field pre-filled to exercise the enabled confirmation. Production callers
    /// leave it empty and type the quantity, exactly as before.
    init(item: WatchItem, portion: PositionPortion, allocation: PositionAllocation,
         initialDestination: PositionPool?,
         onCancel: @escaping () -> Void,
         onSuccess: @escaping (PositionAllocation, PositionAllocation) -> Void,
         isWriteBlocked: Bool = false,
         initialAmount: String = "") {
        self.item = item
        self.portion = portion
        self.allocation = allocation
        self.initialDestination = initialDestination
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.isWriteBlocked = isWriteBlocked
        // A destination handed in by a drag is accepted only when it is one this
        // sheet would itself offer. Anything else — unassigned, the current
        // role, a retired purpose, or a stale drop that no longer matches the
        // portion — falls back to the placeholder rather than silently aiming
        // real shares somewhere the user did not choose.
        let offered = Self.destinations(for: portion)
        _destination = State(initialValue: initialDestination.flatMap { offered.contains($0) ? $0 : nil })
        _amount = State(initialValue: initialAmount)
    }

    /// The offered destinations for the portion captured when the sheet opened.
    private static func destinations(for portion: PositionPortion) -> [PositionPool] {
        PositionPoolsView.holdingTransferDestinations(from: portion.pool.effectivePurpose)
    }

    private var parsedAmount: Double? { Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var canSubmit: Bool {
        guard let destination,
              PositionPoolsView.holdingTransferDestinations(from: portion.pool.effectivePurpose).contains(destination),
              let parsedAmount, parsedAmount.isFinite, parsedAmount > 0,
              parsedAmount <= portion.quantity,
              destination != portion.pool.effectivePurpose else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy("拆分并转移", "Split and move"))
                    .font(.system(size: 18, weight: .semibold))
                Text("\(item.resolvedDisplayName) · \(item.symbol.displayCode) · \(copy("当前", "Current")) \(poolQuantity(portion.quantity))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TextField(copy("转移数量", "Quantity to move"), text: $amount)
                .textFieldStyle(.roundedBorder)
                .onChange(of: amount) { _, _ in errorMessage = nil }
            Picker(copy("目标用途", "Destination"), selection: $destination) {
                Text(copy("请选择目标用途", "Choose destination")).tag(Self.placeholderTag).disabled(true)
                ForEach(Self.destinations(for: portion), id: \.self) { pool in
                    Text(pool.title).tag(Optional(pool))
                }
            }
            TextField(copy("转移原因（选填）", "Reason (optional)"), text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            if let errorMessage { Text(errorMessage).font(.system(size: 10)).foregroundStyle(.red) }
            HStack {
                Button(copy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("确认转移", "Move portion"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(22).frame(width: 410)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func submit() {
        // The sheet is already withheld in preview; this is the last line of
        // defence if a stale presentation ever survives a mode switch.
        guard !isWriteBlocked else { return }
        guard let amount = parsedAmount, canSubmit, let destination else { return }
        // Keep the submit path consistent with the picker; revision validation
        // in the store rejects a portion that changed while this sheet was open.
        guard Self.destinations(for: portion).contains(destination) else { return }
        guard !appState.folderSync.hasPositionConflict(symbol: item.symbol, account: appState.watchlist.activeBrokerageAccountID) else {
            errorMessage = copy("该标的刚出现同步冲突，请先核对两个版本。", "This symbol now has a sync conflict. Review both candidates first.")
            return
        }
        do {
            let updated = try appState.watchlist.transferPositionPortion(
                symbol: item.symbol,
                portionID: portion.id,
                quantity: amount,
                to: destination,
                reason: reason,
                expectedRevision: allocation.revision
            )
            onSuccess(allocation, updated)
        } catch { errorMessage = error.localizedDescription }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}

/// Marks which money one portion card was bought with.
///
/// This is a labelling sheet, not a money form: it changes no price, no
/// quantity, and no cost. Marking part of a card leaves the remainder in the
/// original card — the split is the store's job, and this sheet only says how
/// many shares and what they are. The whole card is the default so the common
/// case is one click, and a partial amount is what creates a second card.
struct FundingSourceSheet: View {
    let item: WatchItem
    let portion: PositionPortion
    let allocation: PositionAllocation
    let onCancel: () -> Void
    let onSuccess: (PositionAllocation, PositionAllocation) -> Void
    /// Preview withholds this sheet; the flag is the last line of defence.
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    /// Starts on the card's current annotation, so reopening the sheet to
    /// correct a mistake is a deliberate change rather than a reset. A `nil`
    /// card seeds `.unmarked` — the picker needs a concrete tag, and saving it
    /// without touching anything is blocked as "same source" by the store.
    ///
    /// The selection is optional so a legacy card's default is its real `nil`
    /// state rather than a fabricated `.unmarked`; choosing `.unmarked` then
    /// reads as the explicit clearing it is.
    @State private var source: PositionFundingSource?
    @State private var draftAccount: BrokerageAccountID?
    @State private var amount: String
    @State private var reason = ""
    @State private var errorMessage: String?

    init(item: WatchItem, portion: PositionPortion, allocation: PositionAllocation,
         onCancel: @escaping () -> Void,
         onSuccess: @escaping (PositionAllocation, PositionAllocation) -> Void,
         isWriteBlocked: Bool = false) {
        self.item = item
        self.portion = portion
        self.allocation = allocation
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.isWriteBlocked = isWriteBlocked
        _source = State(initialValue: portion.fundingSource)
        // The whole card by default: "this entire lot was bought on margin" is
        // the answer most of the time, and a partial amount is the deliberate
        // case that splits the card.
        _amount = State(initialValue: poolQuantityInput(portion.quantity))
    }

    private var parsedAmount: Double? {
        let text = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !text.isEmpty, let value = Double(text) else { return nil }
        return value
    }

    /// The ledger this marking lands in: the one the sheet was opened against.
    ///
    /// The retired per-portion label is deliberately not consulted — it never
    /// decided where shares sit, so letting it choose whether 萌萌's ordinary-buy
    /// restriction applies would let a stale label re-open a funding choice that
    /// account cannot represent. Mengmeng holds no funding annotation and only
    /// ever makes ordinary buys, so this sheet neither offers a choice nor
    /// accepts a submission there.
    private var targetAccount: BrokerageAccountID {
        draftAccount ?? .unassigned
    }

    private var offersFundingChoice: Bool {
        targetAccount != .mengmeng
    }

    /// A partial annotation must be a real, positive number of shares that
    /// fits inside this card. Zero and negatives are refused rather than
    /// silently clamped, and the tolerance mirrors the store's own comparison
    /// so "the whole card" cannot be rejected by a floating-point hair.
    private var canSubmit: Bool {
        guard !isWriteBlocked, offersFundingChoice, let source,
              draftAccount == appState.watchlist.activeBrokerageAccountID else { return false }
        guard let parsedAmount, parsedAmount.isFinite, parsedAmount > 0 else { return false }
        let tolerance = PositionAllocation.quantityTolerance(parsedAmount, portion.quantity)
        guard parsedAmount <= portion.quantity + tolerance else { return false }
        // The store compares against the raw stored value, where `nil` and
        // `.unmarked` are different states. Matching that exactly keeps the app
        // from blocking a change the store would accept — explicitly clearing a
        // legacy card to `.unmarked` is a real edit.
        return portion.fundingSource != source
            && (source != .margin || targetAccount == .financing)
    }

    private var isPartial: Bool {
        guard let parsedAmount, parsedAmount.isFinite else { return false }
        return parsedAmount < portion.quantity - PositionAllocation.quantityTolerance(parsedAmount, portion.quantity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy("标记资金来源", "Mark funding source"))
                    .font(.system(size: 18, weight: .semibold))
                Text("\(item.resolvedDisplayName) · \(item.symbol.displayCode) · \(copy("当前", "Current")) \(poolQuantity(portion.quantity))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Mengmeng buys are ordinary buys: there is no method to choose, so
            // the control is withheld rather than shown with one real option.
            if offersFundingChoice {
                Picker(copy("资金来源", "Funding source"), selection: $source) {
                    Text(fundingSourceTitle(nil, account: targetAccount)).tag(nil as PositionFundingSource?)
                    ForEach(fundingSourcePickerOptions.filter {
                        $0 != .margin || targetAccount == .financing || portion.fundingSource == .margin
                    }, id: \.self) { value in
                        Text(fundingSourceTitle(value, account: targetAccount)).tag(Optional(value))
                    }
                }
                .onChange(of: source) { _, _ in errorMessage = nil }
            }
            HStack {
                Text(copy("标记数量", "Quantity to mark"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(copy("标记数量", "Quantity to mark"), text: $amount)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: amount) { _, _ in errorMessage = nil }
            }
            if isPartial {
                // Say what the split will do before it happens, so a second
                // card appearing is expected rather than surprising.
                Text(copy("将拆出 \(poolQuantity(parsedAmount ?? 0)) 股单独标记，其余保持不变。",
                          "Splits \(poolQuantity(parsedAmount ?? 0)) shares into their own card; the rest is unchanged."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(copy("备注（选填）", "Note (optional)"), text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            Text(copy("标记只记录份额的资金来源，不改动价格、数量、成本或成交记录，也不代表已还款。",
                      "This records which money bought the shares. It changes no price, quantity, cost, or fill, and repays nothing."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage { Text(errorMessage).font(.system(size: 10)).foregroundStyle(.red) }
            HStack {
                Button(copy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("确认标记", "Mark source"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(22).frame(width: 410)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if draftAccount == nil { draftAccount = appState.watchlist.activeBrokerageAccountID } }
    }

    private func submit() {
        guard !isWriteBlocked else { return }
        // A draft opened before a retag, or surviving an account switch, can
        // point at Mengmeng. Refuse it here rather than letting the store turn an
        // account-dependent write into a source-dependent one.
        guard offersFundingChoice else {
            errorMessage = copy("萌萌账号的买入不使用资金来源标注。",
                                "Mengmeng buys are ordinary and carry no funding annotation.")
            return
        }
        guard let parsedAmount, let source, canSubmit else { return }
        // A conflict that landed while the sheet was open makes the revision
        // below stale; refuse here so the message is about the conflict rather
        // than a generic stale-revision error.
        guard !appState.folderSync.hasPositionConflict(symbol: item.symbol, account: draftAccount ?? appState.watchlist.activeBrokerageAccountID) else {
            errorMessage = copy("该标的刚出现同步冲突，请先核对两个版本。", "This symbol now has a sync conflict. Review both candidates first.")
            return
        }
        do {
            let updated = try appState.watchlist.markPositionFundingSource(
                symbol: item.symbol,
                portionID: portion.id,
                quantity: parsedAmount,
                source: source,
                reason: reason,
                expectedRevision: allocation.revision
            )
            onSuccess(allocation, updated)
        } catch { errorMessage = error.localizedDescription }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}

struct PoolReconciliationSheet: View {
    let item: WatchItem
    let allocation: PositionAllocation
    let onCancel: () -> Void
    let onSuccess: () -> Void
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    @State private var values: [UUID: String]
    @State private var reason = ""
    @State private var errorMessage: String?
    /// The ledger this draft was opened against. Quantities describe one
    /// account's holding, so a save must land on that same ledger — switching
    /// accounts mid-edit keeps the draft visible but never redirects the write.
    @State private var frozenAccount: BrokerageAccountID

    init(item: WatchItem, allocation: PositionAllocation, account: BrokerageAccountID,
         onCancel: @escaping () -> Void,
         onSuccess: @escaping () -> Void, isWriteBlocked: Bool = false) {
        self.item = item
        self.allocation = allocation
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.isWriteBlocked = isWriteBlocked
        _frozenAccount = State(initialValue: account)
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: allocation.portions.map { ($0.id, poolQuantityInput($0.quantity)) }))
    }

    private var parsed: [UUID: Double]? {
        var result: [UUID: Double] = [:]
        for portion in allocation.portions {
            let text = (values[portion.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
            let number = text.isEmpty ? 0 : (Double(text) ?? .nan)
            guard number.isFinite, number >= 0 else { return nil }
            result[portion.id] = number
        }
        return result
    }

    private var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The core validates `reasonRequired`, so a blank field is filled with a
    /// fixed audit string rather than blocking the save: the reason is optional
    /// for the user, not for the store.
    private var submittedReason: String {
        trimmedReason.isEmpty
            ? copy("仓位分配核对", "Position allocation reconciled")
            : trimmedReason
    }

    private var enteredTotal: Double {
        guard let parsed else { return .nan }
        return allocation.portions.reduce(0) { $0 + (parsed[$1.id] ?? 0) }
    }
    private var residual: Double {
        guard enteredTotal.isFinite else { return .nan }
        return max(0, item.positionQuantity - enteredTotal)
    }
    private var hasInvalidSources: Bool {
        !allocation.hasMatchingSources(for: item)
    }
    private var hasAccountSwitched: Bool {
        appState.watchlist.activeBrokerageAccountID != frozenAccount
    }
    /// Over the ledger's holding, by more than the store's own tolerance. The
    /// comparison is written as an excess so a sum near `Double.greatestFiniteMagnitude`
    /// cannot overflow on the way to the check.
    private var exceedsHeld: Bool {
        guard parsed != nil else { return false }
        let total = enteredTotal
        guard total.isFinite else { return true }
        let held = item.positionQuantity
        guard held.isFinite else { return true }
        let excess = total - held
        return excess > PositionAllocation.quantityTolerance(total, held)
    }
    /// Why the save is unavailable, in the order the user should read them. The
    /// optional reason is deliberately absent: a blank field is never a block.
    private var validationMessage: String? {
        if parsed == nil || !enteredTotal.isFinite {
            return copy("份额必须是 0 或更大的有效数字。", "Quantities must be finite numbers of 0 or more.")
        }
        if !item.positionQuantity.isFinite || item.positionQuantity <= 0 {
            return copy("当前账本没有可核对的持仓。", "The ledger has no holding to reconcile.")
        }
        if exceedsHeld {
            return copy("合计份额超过当前账本总量 \(poolQuantity(item.positionQuantity))。",
                        "The total exceeds the ledger holding of \(poolQuantity(item.positionQuantity)).")
        }
        if hasAccountSwitched {
            return copy("当前账号已切换。请切回该账号账本后再保存，草稿会保留。",
                        "The selected account changed. Switch back to that ledger to save; your draft is kept.")
        }
        if isWriteBlocked {
            return copy("预演模式下不会写入。", "Preview mode does not write.")
        }
        return nil
    }
    private var canSubmit: Bool {
        guard !isWriteBlocked, !hasAccountSwitched else { return false }
        guard let parsed, enteredTotal.isFinite, item.positionQuantity.isFinite,
              item.positionQuantity > 0 else { return false }
        return !exceedsHeld && parsed.count == allocation.portions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy("核对仓位分配", "Reconcile allocation")).font(.system(size: 18, weight: .semibold))
                Text("\(item.resolvedDisplayName) · \(copy("当前账本总量", "Ledger total")) \(poolQuantity(item.positionQuantity))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if hasInvalidSources {
                Label(
                    copy("买入来源与当前账本不一致。份额仍可逐行编辑；保存会保留你确认的数量、用途、备注与历史，来源将更新为当前账本快照，旧成交价不再作为精确来源展示。", "A buy source no longer matches the ledger. Quantities stay editable per row; saving preserves your confirmed quantities, pools, notes, and history. Sources become a current ledger snapshot, so old trade prices are no longer shown as exact origins."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(allocation.portions.enumerated()), id: \.element.id) { index, portion in
                        VStack(alignment: .leading, spacing: 3) {
                            // The funding annotation is part of what the user
                            // is confirming: reconciliation fixes quantities,
                            // and if it also rebuilds sources the row must say
                            // what it is starting from rather than letting the
                            // composition change invisibly. Mengmeng has no
                            // funding axis, so its rows end at the origin.
                            Text(fundingReconciliationLine(portion))
                                .font(.system(size: 10)).lineLimit(1)
                            HStack {
                                Text(copy("份额", "Quantity"))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                TextField("0", text: valueBinding(portion.id))
                                    .textFieldStyle(.roundedBorder).frame(width: 110)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityLabel(copy("第 \(index + 1) 行份额，当前 \(values[portion.id] ?? "")",
                                                             "Row \(index + 1) quantity, currently \(values[portion.id] ?? "")"))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            Text(copy("数量填 0 可移除这张分配卡，不会删除成交记录。",
                      "Set quantity to 0 to remove this allocation card; trades are kept."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(copy("录入份额", "Entered portions"))
                Spacer()
                Text(enteredTotal.isFinite ? poolQuantity(enteredTotal) : "—").monospacedDigit()
            }
            HStack {
                Text(copy("剩余记入未分配快照", "Residual to unassigned snapshot"))
                Spacer()
                Text(residual.isFinite ? poolQuantity(residual) : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            TextField(copy("核对原因（可选）", "Reason (optional)"), text: $reason)
                .textFieldStyle(.roundedBorder)
                .onChange(of: reason) { _, _ in errorMessage = nil }
            if hasAccountSwitched { AccountDraftNotice(account: frozenAccount) }
            if let message = validationMessage ?? errorMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(validationMessage == nil ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(copy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("保存并核对", "Save reconciliation"), action: submit)
                    .keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }
        .padding(22).frame(width: 500, height: 500)
    }

    /// The card's own account label when it carries one, otherwise the ledger
    /// that encloses it — never a guess at a new owner.
    private func portionAccountLabel(_ portion: PositionPortion) -> String {
        AccountIdentity.title(frozenAccount)
    }

    /// A reconciliation row's description. The funding suffix is dropped for a
    /// Mengmeng row, whose only method is the ordinary buy: printing a source
    /// beside it would invent an axis that account does not have.
    private func fundingReconciliationLine(_ portion: PositionPortion) -> String {
        let head = "\(portion.pool.title) · \(portionAccountLabel(portion)) · \(originLabel(portion))"
        guard (frozenAccount) != .mengmeng else { return head }
        return "\(head) · \(fundingSourceTitle(portion.fundingSource, account: frozenAccount))"
    }

    private func valueBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { values[id] ?? "" }, set: { values[id] = $0; errorMessage = nil })
    }

    private func originLabel(_ portion: PositionPortion) -> String {
        guard portion.origin.kind == .buy else { return copy("持仓快照", "Position snapshot") }
        return portion.origin.date?.formatted(date: .abbreviated, time: .omitted) ?? copy("买入来源", "Buy source")
    }

    private func submit() {
        guard !isWriteBlocked else { return }
        // The ledger guard is re-checked here and not only in `canSubmit`: a
        // switch can land between the last render and the click, and the write
        // must never follow it to a different account.
        guard appState.watchlist.activeBrokerageAccountID == frozenAccount else {
            errorMessage = copy("当前账号已切换。请切回该账号账本后再保存，草稿会保留。",
                                "The selected account changed. Switch back to that ledger to save; your draft is kept.")
            return
        }
        guard canSubmit else { return }
        guard !appState.folderSync.hasPositionConflict(symbol: item.symbol, account: frozenAccount) else {
            errorMessage = copy("该标的刚出现同步冲突，请先核对两个版本。", "This symbol now has a sync conflict. Review both candidates first.")
            return
        }
        do {
            _ = try appState.watchlist.withBrokerageAccount(frozenAccount) {
                try appState.watchlist.reconcilePositionAllocation(
                    symbol: item.symbol,
                    quantities: parsed ?? [:],
                    reason: submittedReason,
                    expectedRevision: allocation.revision
                )
            }
            onSuccess()
        } catch { errorMessage = error.localizedDescription }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}
