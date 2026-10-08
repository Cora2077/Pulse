import SwiftUI
import PulseCore

/// The two questions every new buy has to answer before it can be saved:
/// *which ledger does this land in*, and *what money bought it*.
///
/// They are one component because they are one decision. The method is not a
/// free-standing annotation — `margin` only means anything inside the
/// financing account, and the store refuses a margin buy recorded into
/// mengmeng. Keeping the pickers apart is how the two forms drifted in the
/// first place: a screen could offer a combination the write path rejects, and
/// the user only found out on submit.
///
/// So the rules live here, once:
///
/// - The account picker is a destination list: `nil` ("请选择账户") plus
///   `AccountIdentity.destinations`. `unassigned` is a source of legacy
///   records, never somewhere a new buy can go.
/// - The method picker belongs to the one account that has more than one
///   method. Inside the financing account the choice is real — own capital
///   (担保品) or borrowed money (融资买入) — so it is offered there and only
///   there. The mengmeng account buys with its own money by construction, and
///   a menu holding a single option is not a question; asking it would print a
///   funding label on a form whose answer is already known. The account row
///   stays in both cases, because *which ledger* is always a real choice.
/// - Ordinary capital is always available; margin appears only where the
///   account permits it. The menu is built from `buyFundingSources` in core,
///   not from a second copy of the rule here, so a change to what an account
///   accepts cannot leave this picker offering something the store refuses.
/// - A new buy has no empty funding option. `nil` and `.unmarked` are words
///   about history — "nobody has said yet" and "the user cleared this" — and a
///   brand-new record is neither. The user picks own capital or margin.
///
/// `onAccountChange` exists so a caller can react to a switch that invalidates
/// its own state (the PlanExecutionSheet clears its error). It fires only for a
/// change the user actually made, never for the state the form appears with.
/// The correction that drops margin is applied here, before that callback, so
/// no host can forget it.
struct BuyAccountMethodFields: View {
    /// The ledger this buy will be recorded into; `nil` until the user picks.
    @Binding var account: BrokerageAccountID?
    /// The money that bought the shares. A fresh buy is `.own`, never `nil`.
    @Binding var method: PositionFundingSource
    /// The stable identifier the UI tests address the account menu by. It is a
    /// parameter rather than a literal so each host form keeps the name its own
    /// tests already use — the two forms share the *rules*, not the address.
    let accountAccessibilityID: String
    /// The same, for the method menu.
    let methodAccessibilityID: String
    /// Called after a switch that changes the chosen account, so a caller can
    /// drop a stale error message. It never sees the margin correction below,
    /// which is this view's own invariant.
    var onAccountChange: (() -> Void)?
    /// Called after any change to the method selection.
    var onMethodChange: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            accountRow
            if showsMethodRow { methodRow }
        }
        // Appearing is not choosing. A form that opens on mengmeng — the state
        // a caller can pre-select — must land on the same method a switch to
        // mengmeng produces, and it must do so without telling its host that
        // the user changed the account: no error was invalidated, and a host
        // that resets its own draft on that callback would be reacting to a
        // click nobody made.
        //
        // The correction writes only this view's binding. Nothing persisted is
        // rewritten here: an existing record's annotation is the caller's to
        // preserve, and every host above passes its stored value through.
        .onAppear {
            if !(account?.permitsBuy(fundingSource: method) ?? false), method != .own {
                method = .own
            }
        }
    }

    // MARK: - Account

    /// The method question is asked only where it has more than one answer.
    ///
    /// The financing account genuinely chooses: own capital or borrowed money.
    /// Mengmeng buys with its own money by construction, so its form carries no
    /// funding picker and no funding label — the stored `.own` is written by the
    /// caller, not asked for here. Any other account (the placeholder, or the
    /// legacy `unassigned` a caller should not offer) has no method to choose
    /// until the account row above names a real one; the row would render a
    /// disabled menu saying nothing.
    private var showsMethodRow: Bool { account == .financing }

    /// Small, stacked, and neutral: this is identity, not an alert. Nothing
    /// here is tinted by `AccountIdentity.dotColor` — that accent belongs to
    /// the account surfaces, and a buy form that coloured its ledger picker
    /// would make one account look like a warning.
    private var accountRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(poolCopy("所属账户", "Account"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Picker(poolCopy("所属账户", "Account"), selection: $account) {
                Text(poolCopy("请选择账户", "Select account"))
                    .tag(nil as BrokerageAccountID?)
                ForEach(AccountIdentity.destinations) { destination in
                    Text(AccountIdentity.title(destination))
                        .tag(Optional(destination))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityIdentifier(accountAccessibilityID)
            .accessibilityLabel(poolCopy("所属账户", "Account"))
            .onChange(of: account) { _, _ in
                // Margin only exists where the account permits it. A switch to
                // an account that does not — mengmeng, or back to the
                // placeholder — cannot leave a margin method behind, or the
                // form would be holding a combination the store would reject.
                if !(account?.permitsBuy(fundingSource: method) ?? false), method != .own {
                    method = .own
                }
                onAccountChange?()
            }
        }
    }

    // MARK: - Method

    /// Disabled until an account is named. Ordering is deliberate: the method
    /// menu renders below the account menu and reads as its consequence, which
    /// is why the two ship as one component rather than as two free pickers.
    private var methodRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(poolCopy("买入方式", "Buy method"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Picker(poolCopy("买入方式", "Buy method"), selection: $method) {
                ForEach(methodOptions, id: \.self) { source in
                    Text(buyMethodTitle(source))
                        .tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(account == nil)
            .accessibilityIdentifier(methodAccessibilityID)
            .accessibilityLabel(poolCopy("买入方式", "Buy method"))
            .onChange(of: method) { _, _ in onMethodChange?() }
        }
    }

    /// Which methods this account accepts, in core's order.
    ///
    /// With no account chosen the list is still the ordinary buy alone: the
    /// control is disabled, and a disabled menu that reads "普通买入" says
    /// what the choice will be once an account is named. An empty menu would
    /// instead render blank and read as a broken control rather than a
    /// question waiting on the answer above it.
    private var methodOptions: [PositionFundingSource] {
        account?.buyFundingSources ?? [.own]
    }

    /// The words for a buy method. They are deliberately not `fundingSourceTitle`,
    /// which names a *stored* annotation: that vocabulary includes "not
    /// annotated" and "cleared", and neither is a choice this menu offers.
    ///
    /// Own capital reads as 担保品 here rather than as the ledger-side 普通买入:
    /// inside the financing account the two methods are the two kinds of
    /// collateral the broker recognises, and naming this one after the
    /// collateral is what makes it read as the alternative to borrowing. It is
    /// a label only — the stored identifier stays `.own`, and nothing about the
    /// record written from this menu changes.
    ///
    /// Margin keeps its own name. "融资" is its word on both sides of the
    /// ledger, and it is the choice the user is looking for.
    private func buyMethodTitle(_ source: PositionFundingSource) -> String {
        switch source {
        case .own: poolCopy("担保品", "Collateral")
        case .margin: poolCopy("融资买入", "Margin buy")
        case .unmarked: poolCopy("未标注", "Unmarked")
        }
    }
}
