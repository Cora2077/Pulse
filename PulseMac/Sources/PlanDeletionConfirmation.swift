import SwiftUI
import PulseCore
import PulseUI

/// One pending request to delete a trade plan.
///
/// The struct is a frozen snapshot rather than a live reference. A sheet can sit
/// on screen while another window edits or fills the plan behind it, and a
/// confirmation that re-read the store at confirm time would then describe one
/// record while deleting another. Everything the sheet prints — the instrument,
/// the name, the account it belongs to, the size, and the exact `updatedAt` the
/// user was looking at — is captured here when the request is built, and the
/// delete compares the store against these bytes before it writes.
///
/// `Identifiable` so it can drive `.sheet(item:)`; the id is freshly minted per
/// request, so two requests for the same plan are still two distinct
/// presentations.
struct PlanDeletionRequest: Identifiable, Equatable {
    let id = UUID()
    /// The plan's own id, as stored. It is unique *within one source account's
    /// portfolio*, which is the scope every lookup here is written against: a
    /// same-id plan in another ledger is a different record, and both
    /// `livePlan(in:)` and the store's delete are keyed by account first,
    /// plan id second. Nothing anywhere treats the id as globally unique.
    let planID: UUID
    let symbol: SymbolID
    /// The user-facing name at the moment of the request. Quote metadata can
    /// change it under a live list; the deletion warning should name the row the
    /// user actually clicked. Falls back to the symbol code, never to a blank.
    let displayName: String
    /// The ledger the request was made from, frozen. Never re-read from the
    /// active selection: an account switch behind a modal sheet must refuse the
    /// delete rather than redirect it into another ledger.
    let account: BrokerageAccountID
    /// The stored plan's stamp at request time. Re-checked immediately before
    /// the write, so a plan that changed while the sheet was open is refused.
    let expectedUpdatedAt: Date
    let side: TradePlan.Kind
    /// The size the plan asked for, and what is still open against it. Both were
    /// true of the row the user chose; they are shown, never re-derived.
    let quantity: Double
    let remainingQuantity: Double
    /// The plan's own target price, frozen from `entry.plan.price`.
    ///
    /// Shown beside the size because a symbol and a size do not identify a
    /// plan: two buy plans on the same instrument for the same count at 140 and
    /// at 155 are two different intentions, and a destructive dialog that
    /// printed only the quantity would let the user confirm the wrong one.
    let targetPrice: Double
    /// Whether the editor has edits it has not saved. Nothing about the delete
    /// touches those fields, so the warning is informational: the draft does not
    /// disappear because the plan did.
    let hasUnsavedDraft: Bool

    init(entry: TradePlanEntry, account: BrokerageAccountID, hasUnsavedDraft: Bool = false) {
        self.init(entry: entry, account: account, displayName: entry.symbol.displayCode,
                  hasUnsavedDraft: hasUnsavedDraft)
    }

    /// The same request with the row's own name for the instrument.
    ///
    /// The code alone is enough to identify a plan, but a person deleting one
    /// is looking at a name, and a dialog that answers "which one?" with only a
    /// ticker is asking them to trust a symbol table. Callers that can resolve a
    /// name pass it; the code stays as the fallback rather than an empty string,
    /// because a blank line in a destructive dialog is worse than a terse one.
    init(entry: TradePlanEntry, account: BrokerageAccountID, displayName: String,
         hasUnsavedDraft: Bool = false) {
        self.planID = entry.plan.id
        self.symbol = entry.symbol
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = trimmed.isEmpty || trimmed == entry.symbol.displayCode
            ? entry.symbol.displayCode : trimmed
        self.account = account
        self.expectedUpdatedAt = entry.plan.updatedAt
        self.side = entry.plan.kind
        self.quantity = entry.plan.quantity
        self.remainingQuantity = entry.remainingQuantity
        self.targetPrice = entry.plan.price
        self.hasUnsavedDraft = hasUnsavedDraft
    }

    /// The stored plan, re-read from the ledger this request named. `nil` when
    /// the plan is gone, and the caller must then refuse rather than fall back
    /// to another account's copy of the same id.
    ///
    /// Both halves of the portfolio are searched: a plan can outlive its
    /// watchlist membership in retained history, and a record that is still
    /// there is still deletable. This is a read — no account is selected to
    /// make it, so asking never changes what the store is pointed at.
    @MainActor
    func livePlan(in store: WatchlistStore) -> TradePlan? {
        let portfolio = store.brokeragePortfolio(for: account)
        return (portfolio.items + portfolio.retainedHistoryItems)
            .first { $0.symbol == symbol }?
            .plans.first { $0.id == planID }
    }
}

/// Presents the confirmation sheet for a pending deletion request.
///
/// A modifier rather than a view so a surface keeps its own layout: the request
/// binding is the only state it adds. `.sheet(item:)` is what makes this a real
/// sheet with a real Cancel — the destructive action is never the thing the
/// click already did, and Escape is wired to the same no-write exit.
struct PlanDeletionConfirmation: ViewModifier {
    @Binding var request: PlanDeletionRequest?
    let onDeleted: (() -> Void)?

    init(request: Binding<PlanDeletionRequest?>, onDeleted: (() -> Void)? = nil) {
        _request = request
        self.onDeleted = onDeleted
    }

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            PlanDeletionSheet(
                request: request,
                onClose: { self.request = nil },
                onDeleted: {
                    self.request = nil
                    onDeleted?()
                }
            )
        }
    }
}

/// What is about to be deleted, and what is not.
///
/// The one thing this sheet must not do is imply that deleting a plan deletes
/// the trade. Fills, holdings and the allocation are separate records that
/// survive it, and the warning says so in as many words. The other half is
/// refusing honestly: the plan is re-read from the account the request named
/// and compared against the frozen `updatedAt` immediately before the write,
/// so a plan that moved, vanished, or lives somewhere else produces a sentence
/// instead of a wrong deletion.
struct PlanDeletionSheet: View {
    @Environment(AppState.self) private var appState
    let request: PlanDeletionRequest
    let onClose: () -> Void
    let onDeleted: () -> Void

    @State private var errorMessage: String?
    @State private var didDelete = false

    /// Whether the store still holds this exact plan, in this exact account, at
    /// this exact revision.
    ///
    /// Read on every render, so the button that says "Delete plan" is only ever
    /// enabled while that is still true, and re-asked by `confirm()` because a
    /// render is not a promise about the moment the write happens.
    ///
    /// The account check leads. `livePlan(in:)` reads the request's own ledger,
    /// so it would happily find a same-id plan there after the user switched
    /// accounts elsewhere — and the sheet would then look current while its
    /// confirm could only ever be refused by the store. Comparing the active
    /// selection first is what makes the switch visible: the button disables
    /// and the changed warning appears at the moment of the switch, instead of
    /// the user discovering it by clicking a button that silently does nothing.
    private var isRequestCurrent: Bool {
        guard appState.watchlist.activeBrokerageAccountID == request.account else { return false }
        guard let live = request.livePlan(in: appState.watchlist) else { return false }
        return live.updatedAt == request.expectedUpdatedAt
    }

    private var accountTitle: String { AccountIdentity.title(request.account) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                targetSummary
                preservationWarning
                if request.hasUnsavedDraft {
                    notice("plans.delete.pendingDraft", systemImage: "pencil.circle", tint: .orange)
                }
                if !isRequestCurrent, errorMessage == nil {
                    noticeText(PulseLocalization.localizedString("plans.delete.changed"),
                               systemImage: "exclamationmark.triangle", tint: .orange)
                }
                if let errorMessage {
                    noticeText(errorMessage, systemImage: "exclamationmark.triangle", tint: .red)
                }
            }
            .padding(14)
            Divider()
            footer
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        // Escape is the Cancel button, and Cancel writes nothing. Deliberately
        // no `.defaultAction` anywhere on this sheet: Return must not delete a
        // plan, so the destructive button requires a deliberate click.
        .onExitCommand { onClose() }
        .accessibilityLabel(PulseLocalization.localizedString("plans.delete.title"))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            Text(PulseLocalization.localizedString("plans.delete.title"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Which plan, in which ledger, at which price and size. The symbol code is
    /// the identity that survives a renamed instrument, so it leads; the name
    /// follows only when it says something the code does not, and the target
    /// price follows the name because two plans on one symbol can differ by
    /// price alone.
    private var targetSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(request.symbol.displayCode)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                // A provider that reports the code as the name would print the
                // ticker twice; the duplicate says nothing and costs a line.
                if request.displayName != request.symbol.displayCode {
                    Text(request.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(PulseLocalization.localizedString(request.side == .buy ? "plan.kind.buy" : "plan.kind.sell"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PlanSideStyle.color(for: request.side))
            }
            HStack(spacing: 8) {
                Label(accountTitle, systemImage: "tray")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(PulseLocalization.localizedString(
                    "plans.delete.targetPrice",
                    PlanValueText.price(request.targetPrice, symbol: request.symbol,
                                        currencyCode: quoteCurrencyCode)))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(PlanValueText.quantity(request.quantity, symbol: request.symbol,
                                            instrumentType: resolvedInstrumentType))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            if request.remainingQuantity > 0, request.remainingQuantity != request.quantity {
                Text(PulseLocalization.localizedString(
                    "plans.delete.remaining",
                    PlanValueText.quantity(request.remainingQuantity, symbol: request.symbol,
                                           instrumentType: resolvedInstrumentType)))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The instrument type the row itself would use, so the size prints in the
    /// same unit as the list that opened this sheet.
    private var resolvedInstrumentType: InstrumentType? {
        appState.sharedWatchlist.item(for: request.symbol)?.resolvedInstrumentType
    }

    /// The money the sheet's own row would print, so the price here and the
    /// price the user just clicked on are the same string.
    private var quoteCurrencyCode: String? {
        appState.market.quote(for: request.symbol)?.currencyCode
    }

    /// What the delete does and does not touch. Stated as a fact about the data,
    /// not as a warning about the action.
    private var preservationWarning: some View {
        notice("plans.delete.help", systemImage: "checkmark.shield", tint: .secondary)
    }

    private func notice(_ key: String, systemImage: String, tint: Color) -> some View {
        noticeText(PulseLocalization.localizedString(key), systemImage: systemImage, tint: tint)
    }

    private func noticeText(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(tint == .red ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(PulseLocalization.localizedString("action.cancel")) { onClose() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .disabled(didDelete)
                .accessibilityIdentifier("plan.delete.cancel")
            Button {
                confirm()
            } label: {
                Text(PulseLocalization.localizedString("plans.delete.confirm"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canConfirm ? Color.white : Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(canConfirm ? Color.red.opacity(0.88) : Color.secondary.opacity(0.18))
            )
            .disabled(!canConfirm)
            .opacity(canConfirm ? 1 : 0.5)
            .accessibilityIdentifier("plan.delete.confirm")
        }
        .padding(12)
    }

    private var canConfirm: Bool { isRequestCurrent && !didDelete }

    /// Deletes, but only the plan the request froze.
    ///
    /// The account is re-read rather than resumed: the store's delete addresses
    /// the *active* ledger, and a sheet that outlived an account switch would
    /// otherwise remove a same-id plan from a ledger the user never opened.
    /// Nothing is written unless the ledger matches, the plan is still there,
    /// its revision is the one on screen, and the store reports that it removed
    /// something — the last check catches a store that answered `false` for a
    /// plan it never had.
    private func confirm() {
        guard !didDelete else { return }
        guard appState.watchlist.activeBrokerageAccountID == request.account else {
            errorMessage = PulseLocalization.localizedString("plans.delete.changed")
            return
        }
        guard isRequestCurrent else {
            errorMessage = PulseLocalization.localizedString("plans.delete.changed")
            return
        }
        guard appState.watchlist.deleteTradePlan(request.planID, for: request.symbol) else {
            errorMessage = PulseLocalization.localizedString("plans.delete.changed")
            return
        }
        didDelete = true
        onDeleted()
    }
}
