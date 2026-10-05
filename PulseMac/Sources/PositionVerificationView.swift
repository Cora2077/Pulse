import AppKit
import SwiftUI
import PulseCore

struct VerificationBadge: View {
    let badge: PositionVerificationBadge
    /// Tighter metrics for a card's metadata line. The label still renders.
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: style.symbol)
                .font(.system(size: compact ? 9 : 10, weight: .medium))
            Text(style.title)
                .font(.system(size: compact ? 9 : 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(style.tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(style.tint.opacity(0.28), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.title)
        .help(style.help)
    }

    private var style: VerificationBadgeStyle { .init(badge: badge) }

    static func resolve(
        conditions: [TradePlanCondition]?,
        now: Date = .now,
        currentEvents: [InstrumentEvent]
    ) -> PositionVerificationBadge? {
        PositionVerificationBadge.derived(from: conditions, at: now, currentEvents: currentEvents)
    }
}

/// The colour, glyph, and words for one verification state.
///
/// Purple is the verification accent and nothing else on a card uses it, so the
/// badge cannot be mistaken for a purpose or a funding tag. The two alarm
/// states borrow the board's existing warning colours so "something is wrong"
/// reads the same everywhere; the settled state borrows green for the same
/// reason. None of these is a money-purpose tint.
struct VerificationBadgeStyle {
    let tint: Color
    let symbol: String
    let title: String
    let help: String

    init(badge: PositionVerificationBadge) {
        switch badge {
        case .pending:
            tint = .purple
            symbol = "hourglass"
            title = verificationCopy("待验证", "Pending")
            help = verificationCopy("持有判断尚未验证。", "The conditions have not been verified yet.")
        case .confirmed:
            tint = .green
            symbol = "checkmark.circle"
            title = verificationCopy("已验证", "Verified")
            help = verificationCopy("持有判断已全部验证且仍然成立。", "Every condition is verified and still stands.")
        case .needsReview:
            tint = .orange
            symbol = "arrow.clockwise"
            title = verificationCopy("需复查", "Review")
            help = verificationCopy("持有判断已到期或其依据发生变化，需要复查。",
                                    "A condition came due or the event behind it moved. Review it.")
        case .invalidated:
            tint = .red
            symbol = "exclamationmark.circle"
            title = verificationCopy("已失效", "Invalidated")
            help = verificationCopy("持有判断已被判定失效。", "The reasoning was marked invalid.")
        }
    }
}

struct PositionVerificationSheet: View {
    let item: WatchItem
    let portion: PositionPortion
    let allocation: PositionAllocation
    let onCancel: () -> Void
    let onSuccess: (PositionAllocation, PositionAllocation) -> Void
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    @State private var draft: [TradePlanCondition]
    @State private var didClear = false
    @State private var errorMessage: String?
    /// The account this portion was opened in. A portion id and a revision
    /// belong to one ledger; an account switch replaces the ledger behind the
    /// same store object, so neither authorizes a write afterwards.
    @State private var draftAccount: BrokerageAccountID

    init(item: WatchItem, portion: PositionPortion, allocation: PositionAllocation,
         account: BrokerageAccountID,
         onCancel: @escaping () -> Void,
         onSuccess: @escaping (PositionAllocation, PositionAllocation) -> Void,
         isWriteBlocked: Bool = false) {
        self.item = item
        self.portion = portion
        self.allocation = allocation
        self._draftAccount = State(initialValue: account)
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.isWriteBlocked = isWriteBlocked
        _draft = State(initialValue: portion.conditions ?? [])
    }

    private var accountMatchesDraft: Bool {
        appState.watchlist.activeBrokerageAccountID == draftAccount
    }

    private var liveEvents: [InstrumentEvent] {
        appState.tradingEvents.entries(for: appState.watchlist.allItems)
            .filter { $0.symbol == item.symbol }.map(\.event)
    }

    private var conditionsToSave: [TradePlanCondition]? {
        if portion.conditions == nil, draft.isEmpty, !didClear { return nil }
        return draft.map { condition in
            var value = condition
            value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            value.note = value.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.note?.isEmpty == true { value.note = nil }
            return value
        }
    }

    private var canSubmit: Bool {
        accountMatchesDraft && !isWriteBlocked
            && conditionsToSave != portion.conditions && draft.count <= WatchlistStore.maximumPortionConditionCount
            && draft.allSatisfy {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).count <= 240 && ($0.note?.count ?? 0) <= 4_000
                    && ($0.reviewDate?.timeIntervalSince1970.isFinite ?? true)
            }
            && !appState.folderSync.positionAllocationConflicts.contains { $0.symbol == item.symbol }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verificationCopy("编辑验证", "Edit verification"))
                    .font(.system(size: 17, weight: .semibold))
                Text("\(item.resolvedDisplayName) · \(item.symbol.displayCode) · \(portion.pool.effectivePurpose.title) · \(portion.quantity.formatted(.number.precision(.fractionLength(0...12))))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                // The ledger this verification is written into, named from the
                // value frozen at presentation. It turns orange once the store
                // has moved to another account, matching the refusal below.
                HStack(spacing: 5) {
                    Circle().fill(AccountIdentity.dotColor(draftAccount)).frame(width: 5, height: 5)
                    Text(verificationCopy("记入账号：\(AccountIdentity.title(draftAccount))",
                                          "Recording into: \(AccountIdentity.title(draftAccount))"))
                        .font(.system(size: 10))
                        .foregroundStyle(accountMatchesDraft
                            ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if draft.isEmpty {
                        Text(verificationCopy("还没有持有判断，添加一条想核对的条件。", "Add a condition you want to verify."))
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                    ForEach($draft) { conditionEditor($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verificationCopy("用途回答为什么持有；验证记录判断是否成立。复查日期到达或关联事件变化后，会提醒你重新核对。", "Purpose explains why you hold; verification tracks whether your reasoning stands. Review dates and event changes create reminders."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(verificationCopy("添加判断", "Add condition")) {
                    draft.append(TradePlanCondition(title: "", kind: .manual))
                }.disabled(draft.count >= WatchlistStore.maximumPortionConditionCount)
                if !draft.isEmpty {
                    Button(verificationCopy("清空", "Clear")) { draft = []; didClear = true }
                }
                Spacer()
                Button(verificationCopy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(verificationCopy("保存", "Save"), action: submit)
                    .keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }
        .padding(20).frame(width: 480, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: draft) { _, _ in errorMessage = nil }
    }

    private func conditionEditor(_ condition: Binding<TradePlanCondition>) -> some View {
        let value = condition.wrappedValue
        let eventID = Binding<UUID?>(
            get: { condition.wrappedValue.eventReference?.id },
            set: { id in
                guard id != condition.wrappedValue.eventReference?.id else { return }
                condition.wrappedValue.eventReference = liveEvents.first { $0.id == id }
                // A new reference is a new basis to verify, not an implicit confirmation.
                if condition.wrappedValue.state == .confirmed { condition.wrappedValue.state = .pending }
            })
        let note = Binding<String>(get: { condition.wrappedValue.note ?? "" },
            set: { condition.wrappedValue.note = $0 })
        let hasReviewDate = Binding<Bool>(get: { condition.wrappedValue.reviewDate != nil },
            set: { condition.wrappedValue.reviewDate = $0 ? .now : nil })
        let reviewDate = Binding<Date>(get: { condition.wrappedValue.reviewDate ?? .now },
            set: { condition.wrappedValue.reviewDate = $0 })

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                TextField(verificationCopy("判断标题", "Condition title"), text: condition.title)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: condition.state) {
                    ForEach(TradePlanCondition.State.allCases, id: \.self) { state in
                        Text(stateTitle(state)).tag(state)
                    }
                }.labelsHidden().frame(width: 104)
                Button {
                    draft.removeAll { $0.id == value.id }
                    if draft.isEmpty { didClear = true }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(verificationCopy("删除判断", "Delete condition"))
                    .accessibilityLabel(verificationCopy("删除判断", "Delete condition"))
            }
            TextField(verificationCopy("判断依据 / 失效条件（选填）", "Basis / invalidation (optional)"),
                      text: note, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            HStack(spacing: 8) {
                Toggle(verificationCopy("复查日期", "Review date"), isOn: hasReviewDate).toggleStyle(.checkbox)
                if value.reviewDate != nil {
                    DatePicker("", selection: reviewDate, displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.compact)
                }
                Spacer(minLength: 0)
            }
            Picker(verificationCopy("关联事件", "Linked event"), selection: eventID) {
                Text(verificationCopy("无", "None")).tag(nil as UUID?)
                if let reference = value.eventReference, !liveEvents.contains(where: { $0.id == reference.id }) {
                    Text(verificationCopy("已移除：", "Removed: ") + reference.title).tag(Optional(reference.id))
                }
                ForEach(liveEvents) { event in
                    Text(eventTitle(event)).tag(Optional(event.id))
                }
            }.controlSize(.small)
            if let warning = linkWarning(value) {
                HStack(spacing: 6) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let current = liveEvents.first(where: { $0.id == value.eventReference?.id }) {
                        Button(verificationCopy("更新为当前事件", "Update to current")) {
                            condition.wrappedValue.eventReference = current
                        }.font(.system(size: 10))
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func linkWarning(_ condition: TradePlanCondition) -> String? {
        guard let reference = condition.eventReference else { return nil }
        guard let current = liveEvents.first(where: { $0.id == reference.id }) else {
            return verificationCopy("关联事件已移除，原记录仍保留。", "The event was removed; the original snapshot is kept.")
        }
        if reference.kind != current.kind || reference.title != current.title
            || reference.date != current.date || reference.endDate != current.endDate {
            return verificationCopy("关联事件已变化，请核对新的依据。", "The linked event changed. Review the new basis.")
        }
        return nil
    }

    private func submit() {
        guard canSubmit else { return }
        // The allocation this editor was opened from belongs to the ledger that
        // was selected then. Writing it now would apply one account's portion
        // revision to another account's position.
        guard accountMatchesDraft else {
            errorMessage = verificationCopy(
                "当前账号已切换，验证不会写入其他账号。请关闭后重新打开。",
                "The account changed. This verification will not be written into another account; close and reopen."
            )
            return
        }
        // Editing other metadata must keep stale evidence. Newly confirming a
        // changed reference requires explicit refresh or unlinking first.
        if draft.contains(where: { condition in
            condition.state == .confirmed && linkWarning(condition) != nil
                && portion.conditions?.first(where: { $0.id == condition.id })?.state != .confirmed
        }) {
            errorMessage = verificationCopy("请先核对并更新关联事件，再将判断设为已验证。", "Review and update the linked event before confirming.")
            return
        }
        do {
            let updated = try appState.watchlist.setPositionConditions(symbol: item.symbol,
                portionID: portion.id, conditions: conditionsToSave, expectedRevision: allocation.revision)
            onSuccess(allocation, updated)
        } catch { errorMessage = error.localizedDescription }
    }

    private func stateTitle(_ state: TradePlanCondition.State) -> String {
        switch state {
        case .pending: verificationCopy("待验证", "Pending")
        case .confirmed: verificationCopy("已验证", "Verified")
        case .needsReview: verificationCopy("需复查", "Review")
        case .invalidated: verificationCopy("已失效", "Invalidated")
        }
    }

    private func eventTitle(_ event: InstrumentEvent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: PulseLocalization.currentLanguageIdentifier)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateStyle = .medium
        return "\(formatter.string(from: event.date)) · \(event.title)"
    }
}

private func verificationCopy(_ chinese: String, _ english: String) -> String {
    PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
}
