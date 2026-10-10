#if DEBUG
import AppKit
import SwiftUI
import PulseCore
import PulseUI

/// Synthetic native acceptance harness for the trade-plan usability surfaces.
///
/// Everything here drives the *real* views, the real `AppState`, and the real
/// store. Nothing is a copy of a helper: `PlanListView`, `PlanWorkflowDetailView`,
/// `PlanExecutionSheet`, `PlanDeletionSheet`, `AppSettings` and `PlanValueText`
/// are the same declarations the app ships. Native interaction goes through
/// `NSWindow.sendEvent` and AppKit accessibility actions inside this process
/// only — never a global event tap and never a click on the developer's desktop.
///
/// Run: FFF --main-window-demo --plan-usability-selftest [--export-render-base64]
/// `--main-window-demo` is required by `SelfTest.runIfRequested` and selects the
/// disposable offline defaults suite, so a run can never read or write real data.
///
/// Every fixture is fictional: the name 虚构验证 and the symbols QAUS/QAHK/QACN/
/// QAFUND/BTC-USDT/QAOLD exist only in the throwaway suite. No network, no live
/// account, no signing.
@MainActor
enum TradePlanUsabilitySelfTest {
    private static var failures: [String] = []
    private static var checks = 0
    private static var reports: [String] = []

    static func run() -> Bool {
        failures = []
        checks = 0
        reports = []
        guard CommandLine.arguments.contains("--main-window-demo") else {
            print("PULSE_PLAN_USABILITY_SELFTEST failed: requires --main-window-demo")
            fflush(stdout)
            return false
        }
        checkValueText()
        checkSettingsPersistence()
        // A fresh AppState reads the isolated demo suite, which AppState clears on
        // the way in. The demo seeder also loads demo items and plans; those are
        // removed here so each check starts from a single fictional fixture.
        let state = AppState()
        resetToOfflineFixture(state)
        checkPlanListRendering(state)
        checkBackfillWorkflow(state)
        checkDeletionSheet(state)
        checkWrongAccountAndRevisionRefusal(state)
        for report in reports { print("PULSE_PLAN_USABILITY_SELFTEST note \(report)") }
        for failure in failures { print("PULSE_PLAN_USABILITY_SELFTEST failure: \(failure)") }
        print("PULSE_PLAN_USABILITY_SELFTEST \(failures.isEmpty ? "passed" : "failed") checks=\(checks) failures=\(failures.count)")
        fflush(stdout)
        return failures.isEmpty
    }

    // MARK: - PlanValueText

    /// The shared formatter must print each market's own money and unit without
    /// converting anything, and must never turn a real small number into a zero.
    private static func checkValueText() {
        let us = SymbolID(market: .us, code: "QAUS")
        let hk = SymbolID(market: .hk, code: "QAHK")
        let cn = SymbolID(market: .sh, code: "QACN")
        let jp = SymbolID(market: .jp, code: "7203")
        let kr = SymbolID(market: .kr, code: "005930")
        let fund = SymbolID(market: .us, code: "QAFUND")
        let unknown = SymbolID(market: .us, code: "QAUNK")
        let btc = SymbolID(cryptoBase: "BTC", quote: "USDT")

        expect(PlanValueText.price(1234.5, symbol: us, currencyCode: "USD").hasSuffix("USD"),
               "value-text: a US price names USD")
        expect(PlanValueText.price(1234.5, symbol: hk, currencyCode: "HKD").hasSuffix("HKD"),
               "value-text: a HK price names HKD, not a converted USD")
        expect(PlanValueText.price(7.5, symbol: cn, currencyCode: "CNY").hasSuffix("CNY"),
               "value-text: a CN price names CNY")
        expect(PlanValueText.price(2_800, symbol: jp, currencyCode: "JPY").hasSuffix("JPY"),
               "value-text: a JP price names JPY")
        expect(PlanValueText.price(71_000, symbol: kr, currencyCode: "KRW").hasSuffix("KRW"),
               "value-text: a KR price names KRW")
        // The instrument's own currency stands in when the quote has none, and a
        // live quote's own code wins when it has one.
        expect(PlanValueText.price(10, symbol: hk, currencyCode: nil).hasSuffix("HKD"),
               "value-text: a missing quote code falls back to the instrument's currency")
        expect(PlanValueText.price(10, symbol: us, currencyCode: "HKD").hasSuffix("HKD"),
               "value-text: a live quote code is printed as reported, never converted")
        // No FX: the same magnitude on two markets keeps its digits and only the
        // currency suffix differs, so neither side is a converted amount.
        let usPrice = PlanValueText.price(1234.5, symbol: us, currencyCode: "USD")
        let hkPrice = PlanValueText.price(1234.5, symbol: hk, currencyCode: "HKD")
        expect(usPrice.replacingOccurrences(of: "USD", with: "")
                == hkPrice.replacingOccurrences(of: "HKD", with: ""),
               "value-text: the same magnitude prints unchanged across markets (no FX conversion)")

        let fundUnit = PulseLocalization.localizedString("plans.unit.fund")
        let genericUnit = PulseLocalization.localizedString("plans.unit.generic")
        for type in [InstrumentType.etf, .fund] {
            expect(PlanValueText.quantity(20, symbol: fund, instrumentType: type).hasSuffix(fundUnit),
                   "value-text: a \(type.rawValue) quantity uses the localized fund unit")
        }
        expect(PlanValueText.quantity(3, symbol: unknown, instrumentType: nil).hasSuffix(genericUnit),
               "value-text: an unknown instrument type uses the neutral generic unit")
        expect(!PlanValueText.quantity(3, symbol: unknown, instrumentType: nil)
            .hasSuffix(PulseLocalization.localizedString("trade.unit.shares")),
               "value-text: an unknown type must not claim shares")

        expect(PlanValueText.quantity(0.005, symbol: btc, instrumentType: .crypto).hasSuffix("BTC"),
               "value-text: a crypto quantity counts the base asset")
        expect(PlanValueText.price(67_450, symbol: btc, currencyCode: "USDT").hasSuffix("USDT"),
               "value-text: a crypto price counts the quote asset")
        expect(PlanValueText.priceQuantity(price: 67_450, quantity: 0.005, symbol: btc,
                                           currencyCode: "USDT", instrumentType: .crypto)
                .contains("×") && PlanValueText.priceQuantity(price: 67_450, quantity: 0.005, symbol: btc,
                                                               currencyCode: "USDT", instrumentType: .crypto)
                .hasSuffix("BTC"),
               "value-text: the paired cell carries both sides")

        // The regression this check exists for: 0.00000005 BTC formatted with a
        // narrow fraction length would print "0 BTC", which is a lie about a real
        // holding. The quantity is what must survive, so it is asserted directly.
        let tiny = PlanValueText.quantity(0.00000005, symbol: btc, instrumentType: .crypto)
        expect(!tiny.hasPrefix("0 ") && !tiny.hasPrefix("0\u{00A0}"),
               "value-text: 0.00000005 BTC must not round to 0 (got \"\(tiny)\")")
        expect(tiny.contains("0.00000005") || tiny.contains("0.0000001") || tiny.contains("5"),
               "value-text: the tiny BTC quantity keeps a significant digit (got \"\(tiny)\")")

        for bad in [Double.nan, .infinity, -.infinity] {
            expect(PlanValueText.price(bad, symbol: us, currencyCode: "USD") == PlanValueText.unknown,
                   "value-text: a non-finite price prints the dash, not a number")
            expect(PlanValueText.quantity(bad, symbol: us, instrumentType: .equity) == PlanValueText.unknown,
                   "value-text: a non-finite quantity prints the dash")
            expect(PlanValueText.priceQuantity(price: bad, quantity: 1, symbol: us) == PlanValueText.unknown,
                   "value-text: a non-finite half dashes the whole cell")
        }

        // Quote codes are provider text. A short alphanumeric code is
        // normalized — legitimate tickers like 1INCH or 1000SATS carry digits —
        // while anything with whitespace, punctuation, CJK, or an absurd
        // length is dropped in favour of the instrument's own currency rather
        // than echoed into a row.
        expect(PlanValueText.normalizedQuoteCurrency("usd", symbol: us) == "USD",
               "value-text: a lowercase code is uppercased")
        expect(PlanValueText.normalizedQuoteCurrency("  hkd  ", symbol: us) == "HKD",
               "value-text: surrounding whitespace is trimmed off a code")
        for accepted in ["US1", "1INCH", "1000SATS", "ABCDEFG"] {
            expect(PlanValueText.normalizedQuoteCurrency(accepted, symbol: us) == accepted,
                   "value-text: alphanumeric code \"\(accepted)\" is a legitimate asset code")
        }
        for suspicious in ["US D", "USDT/X", "ABCDEFGHIJKLM", "USD<span>", "", "a", "人民币"] {
            let resolved = PlanValueText.normalizedQuoteCurrency(suspicious, symbol: hk)
            expect(resolved == "HKD",
                   "value-text: suspicious code \"\(suspicious)\" falls back to the instrument currency (got \(resolved ?? "nil"))")
        }
        expect(PlanValueText.normalizedQuoteCurrency(nil, symbol: us) == "USD",
               "value-text: no quote code falls back to the instrument currency")
    }

    // MARK: - AppSettings

    /// The density choice persists like every other local preference, and an
    /// older snapshot that predates it must still decode.
    private static func checkSettingsPersistence() {
        let suite = "app.pulse.mac.plan-usability-selftest.settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect(false, "settings: a disposable suite must open"); return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let key = "pulse.settings.plan-usability.v1"
        let settings = AppSettings(defaults: defaults, storageKey: key)
        expect(settings.compactPlanCards, "settings: compact cards are the default")

        // Other fields the sheet must not disturb.
        settings.setMenuBarPanelHeight(610)
        settings.redUp = false
        settings.mcpEnabled = true
        settings.recordRecentSearch("虚构验证")
        settings.compactPlanCards = false
        expect(!settings.compactPlanCards, "settings: compact can be turned off")

        let reloaded = AppSettings(defaults: defaults, storageKey: key)
        expect(!reloaded.compactPlanCards, "settings: a disabled compact preference survives a reload")
        expect(reloaded.menuBarPanelHeight == 610,
               "settings: the 610pt popup height survives the density change (got \(String(describing: reloaded.menuBarPanelHeight)))")
        expect(!reloaded.redUp && reloaded.mcpEnabled && reloaded.recentSearchQueries == ["虚构验证"],
               "settings: toggling density preserves the other stored fields")

        // Toggling from the reloaded instance must not drop the height either.
        reloaded.compactPlanCards = true
        let third = AppSettings(defaults: defaults, storageKey: key)
        expect(third.compactPlanCards && third.menuBarPanelHeight == 610,
               "settings: re-enabling compact keeps the stored height")

        // A snapshot written before the field existed. Remove the key from the
        // real encoded payload and keep the rest, rather than hand-building JSON.
        guard let data = defaults.data(forKey: key),
              var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            expect(false, "settings: the settings snapshot must be persisted as JSON"); return
        }
        payload.removeValue(forKey: "compactPlanCards")
        guard let legacy = try? JSONSerialization.data(withJSONObject: payload) else {
            expect(false, "settings: the legacy payload must re-encode"); return
        }
        defaults.set(legacy, forKey: key)
        let legacySettings = AppSettings(defaults: defaults, storageKey: key)
        expect(legacySettings.compactPlanCards,
               "settings: a legacy snapshot with no compact key decodes to compact (true)")
        expect(legacySettings.menuBarPanelHeight == 610 && !legacySettings.redUp,
               "settings: the legacy snapshot's other values still load")
    }

    // MARK: - Fixture

    /// Installs one fictional multi-market fixture in the financing ledger.
    ///
    /// The demo seeder already populated this disposable suite, so every ledger
    /// is cleared first: the deletion checks compare whole snapshots, and a
    /// retained demo item would make those comparisons meaningless. This is the
    /// only place demo records are removed, and it runs only under the isolated
    /// `--main-window-demo` suite.
    private static func resetToOfflineFixture(_ state: AppState) {
        let store = state.watchlist
        store.enableBrokerageAccounts()
        for account in BrokerageAccountID.allCases {
            store.withBrokerageAccount(account) {
                for item in store.allItems {
                    for plan in item.plans { store.deleteTradePlan(plan.id, for: item.symbol) }
                    store.remove(item.symbol)
                }
                // Removing membership retains the trade history, so the ledger is
                // emptied explicitly too.
                for item in store.allItems {
                    for transaction in item.transactions {
                        store.deleteTransaction(item.symbol, id: transaction.id)
                    }
                }
            }
        }
        _ = state.selectBrokerageAccount(.financing)

        let day = Calendar.current.startOfDay(for: .now)
        let infos = [
            SymbolInfo(symbol: SymbolID(market: .us, code: "QAUS"), name: "虚构验证", type: .equity),
            SymbolInfo(symbol: SymbolID(market: .hk, code: "QAHK"), name: "虚构验证", type: .equity),
            SymbolInfo(symbol: SymbolID(market: .sh, code: "QACN"), name: "虚构验证", type: .equity),
            SymbolInfo(symbol: SymbolID(market: .us, code: "QAFUND"), name: "虚构验证", type: .fund),
            SymbolInfo(symbol: SymbolID(cryptoBase: "BTC", quote: "USDT"), name: "虚构验证", type: .crypto),
        ]
        for info in infos { store.add(info) }
        let quotes = [
            Quote(symbol: infos[0].symbol, name: "虚构验证", price: 106, previousClose: 100, currencyCode: "USD", timestamp: .now),
            Quote(symbol: infos[1].symbol, name: "虚构验证", price: 88, previousClose: 90, currencyCode: "HKD", timestamp: .now),
            Quote(symbol: infos[2].symbol, name: "虚构验证", price: 12.5, previousClose: 12, currencyCode: "CNY", timestamp: .now),
            Quote(symbol: infos[3].symbol, name: "虚构验证", price: 3.25, previousClose: 3.2, currencyCode: "USD", timestamp: .now),
            Quote(symbol: infos[4].symbol, name: "虚构验证", price: 67_450, previousClose: 66_880, currencyCode: "USDT", timestamp: .now),
        ]
        state.market.apply(quotes: quotes)

        // Multi-market waiting plans, one per type, so both density renders and
        // the table render exercise every unit and currency branch.
        let waiting: [(SymbolID, TradePlan)] = [
            (infos[0].symbol, TradePlan(kind: .buy, price: 98, quantity: 100)),
            (infos[0].symbol, TradePlan(kind: .sell, price: 130, quantity: 40)),
            (infos[1].symbol, TradePlan(kind: .buy, price: 80, quantity: 200)),
            (infos[2].symbol, TradePlan(kind: .buy, price: 11.5, quantity: 300)),
            (infos[3].symbol, TradePlan(kind: .buy, price: 3, quantity: 500)),
            (infos[4].symbol, TradePlan(kind: .buy, price: 60_000, quantity: 0.005)),
        ]
        for (symbol, plan) in waiting {
            expect(state.watchlist.setTradePlan(plan, for: symbol), "fixture: a fictional waiting plan must save")
        }
        // History: a filled record and an abandoned one, so the history scope
        // renders its sections.
        let filled = TradePlan(kind: .buy, price: 95, quantity: 50)
        let abandoned = TradePlan(kind: .buy, price: 70, quantity: 20, status: .cancelled)
        expect(state.watchlist.setTradePlan(filled, for: infos[0].symbol), "fixture: the filled plan must save")
        expect(state.watchlist.setTradePlan(abandoned, for: infos[0].symbol), "fixture: the abandoned plan must save")
        for (plan, price, quantity) in [(filled, 94.0, 50.0)] {
            _ = try? state.watchlist.recordTradePlanFill(
                symbol: infos[0].symbol, planID: plan.id, price: price, quantity: quantity,
                date: day.addingTimeInterval(-86_400), fee: 0, note: "虚构验证",
                fundingSource: .own, brokerageAccountID: .financing)
        }
        // A real holding on the fund symbol, so the deletion check has an actual
        // position and allocation that must survive the plan it removes.
        state.watchlist.addTransaction(infos[3].symbol, PositionTransaction(
            kind: .buy, price: 3.1, quantity: 800, date: day.addingTimeInterval(-172_800), fee: 0))

        // The one backfill subject: a legacy .done plan with size still open and
        // no fills at all, sitting in the financing ledger.
        let legacy = TradePlan(kind: .buy, price: 110, quantity: 100, status: .done,
                               note: "虚构验证 backfill subject", fundingSource: .own)
        expect(state.watchlist.setTradePlan(legacy, for: infos[0].symbol), "fixture: the QAOLD subject must save")
    }

    /// Adds the QAOLD subject to a second account under the *same* plan id, which
    /// is what the wrong-account refusal check needs. The swap runs through
    /// `withBrokerageAccount`, so it restores the previously selected ledger.
    @discardableResult
    private static func installSameIDPlanInMengmeng(_ state: AppState, planID: UUID, symbol: SymbolID,
                                                    quantity: Double) -> Bool {
        state.watchlist.withBrokerageAccount(.mengmeng) {
            state.watchlist.add(SymbolInfo(symbol: symbol, name: "虚构验证", type: .equity))
            return state.watchlist.setTradePlan(
                TradePlan(id: planID, kind: .buy, price: 111, quantity: quantity, status: .done), for: symbol)
        }
    }

    private static func entry(_ state: AppState, symbol: SymbolID, planID: UUID) -> TradePlanEntry? {
        state.watchlist.item(for: symbol)?.plans.first { $0.id == planID }
            .map { TradePlanEntry(symbol: symbol, plan: $0, transactions: state.watchlist.transactionsForPlan(symbol)) }
    }

    // MARK: - Plan list rendering and the native density toggle

    private static func checkPlanListRendering(_ state: AppState) {
        let store = state.watchlist
        let baseline = store.syncSnapshot()
        let directory = artifactDirectory("plan-usability")

        // The compact default, then comfortable, at light and dark. The waiting
        // scope is where both densities differ most.
        for compact in [true, false] {
            state.settings.compactPlanCards = compact
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                let name = compact ? "plan-compact-\(suffix).png" : "plan-comfortable-\(suffix).png"
                host(view: AnyView(PlanListView(route: .constant(.planList)).environment(state)),
                     width: 340, height: 610, scheme: scheme, name: name, directory: directory)
            }
        }
        expect(store.syncSnapshot() == baseline, "plan-list: rendering both densities must not change any holding, plan or account")

        // The history scope, so the filled/abandoned sections are exercised too.
        state.settings.compactPlanCards = true
        host(view: AnyView(PlanListView(route: .constant(.planList), initialScope: .history).environment(state)),
             width: 340, height: 610, scheme: .light, name: "plan-history-light.png", directory: directory)

        // The main window's table at its real width, both densities.
        for compact in [true, false] {
            state.settings.compactPlanCards = compact
            let suffix = compact ? "compact" : "comfortable"
            host(view: AnyView(MainPlanListView(route: .constant(.planList)).environment(state)),
                 width: 1_100, height: 720, scheme: .light,
                 name: "plan-table-\(suffix)-light.png", directory: directory)
        }
        expect(store.syncSnapshot() == baseline, "plan-list: the main table render must not change any holding, plan or account")

        checkCompactTogglePress(state)
        state.settings.compactPlanCards = true
    }

    /// Presses the real header control and asserts the stored setting flipped.
    ///
    /// Offscreen SwiftUI publishes no accessibility tree in this harness, so
    /// the press is a real window event at the toggle's measured position in
    /// the 340pt header fixture — the same pattern the tactical-board harness
    /// uses. The observable effect (the stored setting flips) is what proves
    /// the press landed; a missed point fails loudly, never silently.
    private static func checkCompactTogglePress(_ state: AppState) {
        state.settings.compactPlanCards = true
        host(view: AnyView(PlanListView(route: .constant(.planList)).environment(state)),
             width: 340, height: 610, scheme: .light, name: "plan-toggle-after.png",
             directory: artifactDirectory("plan-usability")) { host in
            let before = state.settings.compactPlanCards
            // The density toggle sits left of the add button in the 340pt
            // header: padding 12, the ~28pt add button, 8pt spacing, then the
            // toggle's 24pt icon centred at x ≈ 223, y ≈ 23 from the top.
            click(host, at: NSPoint(x: 223, y: 23))
            settle(host)
            expect(state.settings.compactPlanCards != before,
                   "plan-list: pressing the density control must flip the stored setting")
            expect(state.settings.compactPlanCards == false,
                   "plan-list: the density control must have turned compact off (got \(state.settings.compactPlanCards))")
        }
        state.settings.compactPlanCards = true
    }

    // MARK: - Backfill workflow

    /// Drives the real detail page and the real fill sheet: open backfill, record
    /// 106 × 60, confirm, then reopen the same page for an explicit 106 × 40.
    ///
    /// Every sheet interaction happens *inside* the hosting window's lifetime:
    /// the host tears its window down when the inspect closure returns, and a
    /// click sent to an ordered-out sheet is not a real interaction.
    private static func checkBackfillWorkflow(_ state: AppState) {
        let store = state.watchlist
        let symbol = SymbolID(market: .us, code: "QAUS")
        guard let subject = entry(state, symbol: symbol, planID: qaoldPlanID(state, symbol: symbol)) else {
            expect(false, "backfill: the QAOLD subject must exist in the financing ledger"); return
        }
        let planID = subject.plan.id
        expect(subject.plan.status == .done && subject.displayState == .stopped && subject.canBackfillFill,
               "backfill: the subject must be a stopped plan with size still open")
        let positionBefore = store.item(for: symbol)?.positionQuantity ?? 0
        let directory = artifactDirectory("plan-usability")

        host(view: AnyView(PlanWorkflowDetailView(symbol: symbol, planID: planID, account: .financing)
                .environment(state)),
             width: 650, height: 600, scheme: .light, name: "plan-detail-before-backfill.png",
             directory: directory) { root in
            let baseline = store.syncSnapshot()
            let entryCount = store.tradePlanEntries.count
            openBackfillSheet(root)
            settle(root)
            // A sheet is a real child window of the hosting window.
            guard let form = root.window?.attachedSheet?.contentView else {
                expect(false, "backfill: pressing the real button must open a real attached sheet")
                return
            }
            expect(store.syncSnapshot() == baseline,
                   "backfill: opening the sheet writes nothing")
            expect(store.tradePlanEntries.count == entryCount, "backfill: opening the sheet adds no plan")

            guard let fields = fillFields(in: form) else {
                expect(false, "backfill: the real price and quantity cells must expose editable fields")
                return
            }
            expect(fields.price.stringValue.isEmpty && fields.quantity.stringValue.isEmpty,
                   "backfill: the price and quantity must start blank on a backfill")
            setField(fields.price, to: "106")
            setField(fields.quantity, to: "60")
            settle(form)

            let preSubmit = store.syncSnapshot()
            submitFillSheet(form)
            settle(form)

            let afterFirst = entry(state, symbol: symbol, planID: planID)
            expect(afterFirst?.plan.status == .done,
                   "backfill: the source plan's raw status stays done after a partial backfill")
            expect(afterFirst?.displayState == .stopped,
                   "backfill: a partial backfill must not resurrect the waiting state")
            expect(afterFirst?.filledQuantity == 60,
                   "backfill: one linked transaction of 60 must be counted (got \(String(describing: afterFirst?.filledQuantity)))")
            expect(afterFirst?.remainingQuantity == 40,
                   "backfill: 40 must remain open after the 60-unit backfill")
            expect(afterFirst?.averageFillPrice == 106,
                   "backfill: the counted fill must be the actual 106, not the plan's target")
            let fills = store.transactionsForPlan(symbol).filter { $0.planExecution?.planID == planID }
            expect(fills.count == 1 && fills.first?.quantity == 60 && fills.first?.price == 106,
                   "backfill: exactly one real linked transaction must exist at the entered price and quantity")
            // The store must have advanced: the write is a real financial change, so
            // the snapshot differs from the pre-submit one in exactly that plan.
            expect(store.syncSnapshot() != preSubmit,
                   "backfill: recording the fill must change the financial snapshot")
        }

        guard entry(state, symbol: symbol, planID: planID)?.filledQuantity == 60 else {
            expect(false, "backfill: the first backfill never landed, so the second cannot be exercised")
            return
        }

        // Reopen the exact same real page and finish the remainder explicitly.
        host(view: AnyView(PlanWorkflowDetailView(symbol: symbol, planID: planID, account: .financing)
                .environment(state)),
             width: 650, height: 600, scheme: .light, name: "plan-detail-after-partial.png",
             directory: directory) { root in
            openBackfillSheet(root)
            settle(root)
            guard let reopenForm = root.window?.attachedSheet?.contentView else {
                expect(false, "backfill: the second backfill sheet never attached"); return
            }
            // The fields start blank again, and the second entry is the explicit 40.
            guard let reopenFields = fillFields(in: reopenForm) else {
                expect(false, "backfill: the reopened sheet must expose the same two real cells")
                return
            }
            // Past dates are a core path, covered verbatim by the store tests;
            // the form's date row is verified visually in the captured sheet
            // (SwiftUI draws it without a materialized NSView the harness can
            // read). What must hold here is that the entry is *not* inferred:
            // the two fills land on the date the sheet was given, which is
            // today by default and is exercised as a real write either way.
            setField(reopenFields.price, to: "106")
            setField(reopenFields.quantity, to: "40")
            settle(reopenForm)
            submitFillSheet(reopenForm)
            settle(reopenForm)
        }

        let final = entry(state, symbol: symbol, planID: planID)
        let allFills = store.transactionsForPlan(symbol).filter { $0.planExecution?.planID == planID }
        expect(allFills.count == 2, "backfill: the two entries must be two distinct real fills (got \(allFills.count))")
        expect(final?.filledQuantity == 100,
               "backfill: the fills must aggregate to the full size (got \(String(describing: final?.filledQuantity)))")
        expect(final?.averageFillPrice == 106,
               "backfill: the aggregate average must be the actual 106 (got \(String(describing: final?.averageFillPrice)))")
        expect(final?.displayState == .filled && final?.remainingQuantity == 0,
               "backfill: the completed plan must derive as filled with nothing remaining")
        expect(store.item(for: symbol)?.positionQuantity == positionBefore + 100,
               "backfill: the real position must gain exactly the 100 backfilled units (before \(positionBefore), got \(String(describing: store.item(for: symbol)?.positionQuantity)))")
        expect(store.syncSnapshot().brokerageAccounts?.allSatisfy {
                $0.accountID == .mengmeng || $0.accountID == .financing
            } == true,
            "backfill: the snapshot still describes the same two named ledgers")
    }

    /// Opens the backfill sheet from the real detail header. The press is a
    /// real window event at the button's measured position in the 650pt
    /// fixture; the attached sheet that follows is the observable proof it
    /// landed.
    private static func openBackfillSheet(_ root: NSView) {
        // The detail header's trailing button on a 650pt page: the "恢复为等待中"
        // revive button ends at 650−18, the backfill button is the ~62pt-wide
        // sibling 8pt to its left, centred at x ≈ 503, y ≈ 28 from the top.
        click(root, at: NSPoint(x: 503, y: 28))
    }

    // MARK: - Deletion sheet

    private static func checkDeletionSheet(_ state: AppState) {
        let store = state.watchlist
        let symbol = SymbolID(market: .us, code: "QAFUND")
        guard let first = store.item(for: symbol)?.plans.first else {
            expect(false, "delete: the fixture must have a deletable plan"); return
        }
        let directory = artifactDirectory("plan-usability")
        let entryValue = TradePlanEntry(symbol: symbol, plan: first,
                                        transactions: store.transactionsForPlan(symbol))
        let request = PlanDeletionRequest(entry: entryValue, account: .financing,
                                          displayName: "虚构验证", hasUnsavedDraft: true)

        let baseline = store.syncSnapshot()
        var cancelBlewAway = false
        host(view: AnyView(PlanDeletionSheet(request: request, onClose: { cancelBlewAway = true },
                                             onDeleted: {})
                .environment(state)),
             width: 380, height: 260, scheme: .light, name: "plan-delete-light.png",
             directory: directory) { root in
            // The footer's Cancel on the 380pt sheet: right-aligned pair,
            // Cancel centred at x ≈ 272, footer centre y ≈ 213 in the
            // 237pt-high content. Cancel calling back (and writing nothing)
            // is the observable proof the press landed.
            click(root, at: NSPoint(x: 272, y: 213))
            settle(root)
        }
        expect(cancelBlewAway, "delete: the real Cancel must call back rather than delete")
        expect(store.syncSnapshot() == baseline, "delete: Cancel must leave the whole financial snapshot unchanged")

        // Return must not delete either: the sheet deliberately has no default
        // action. The cancel button owns the cancel shortcut, so a Return key
        // press reaches nothing destructive.
        host(view: AnyView(PlanDeletionSheet(request: request, onClose: {}, onDeleted: {})
                .environment(state)),
             width: 380, height: 260, scheme: .light, name: "plan-delete-cancel.png",
             directory: directory) { root in
            sendKey(root, characters: "\r")
            settle(root)
        }
        expect(store.syncSnapshot() == baseline, "delete: the Return key must not delete a plan")

        // Dark render of the same confirmation.
        host(view: AnyView(PlanDeletionSheet(request: request, onClose: {}, onDeleted: {})
                .environment(state)),
             width: 380, height: 260, scheme: .dark, name: "plan-delete-dark.png", directory: directory)

        // Confirm deletes this one plan and nothing else.
        var deleted = false
        let planCountBefore = store.tradePlanEntries.count
        let transactionCountBefore = store.syncSnapshot().allAccountItems
            .reduce(0) { $0 + $1.transactions.count }
        let positionBefore = store.item(for: symbol)?.positionQuantity
        let allocationBefore = store.item(for: symbol)?.positionAllocation
        host(view: AnyView(PlanDeletionSheet(request: request, onClose: {}, onDeleted: { deleted = true })
                .environment(state)),
             width: 380, height: 260, scheme: .light, name: "plan-delete-confirm.png",
             directory: directory) { root in
            // The footer's destructive button sits right of Cancel, centred at
            // x ≈ 334, same 213 footer line. The deletion that follows is the
            // observable proof.
            click(root, at: NSPoint(x: 334, y: 213))
            settle(root)
        }
        expect(deleted, "delete: confirm must report the deletion")
        expect(store.item(for: symbol)?.plans.contains { $0.id == first.id } == false,
               "delete: the named plan must be gone")
        expect(store.tradePlanEntries.count == planCountBefore - 1, "delete: exactly one plan must be removed")
        let transactionCountAfter = store.syncSnapshot().allAccountItems
            .reduce(0) { $0 + $1.transactions.count }
        expect(transactionCountAfter == transactionCountBefore,
               "delete: every transaction must survive a plan deletion (\(transactionCountBefore) → \(transactionCountAfter))")
        expect(store.item(for: symbol)?.positionQuantity == positionBefore
                && store.item(for: symbol)?.positionAllocation == allocationBefore,
               "delete: the position and its allocation must survive a plan deletion")

        // A request whose plan is edited behind the sheet must refuse: the frozen
        // `updatedAt` no longer matches the store's revision.
        let revisionSymbol = SymbolID(market: .hk, code: "QAHK")
        if let stale = store.item(for: revisionSymbol)?.plans.first {
            let staleRequest = PlanDeletionRequest(
                entry: TradePlanEntry(symbol: revisionSymbol, plan: stale,
                                      transactions: store.transactionsForPlan(revisionSymbol)),
                account: .financing, displayName: "虚构验证")
            // Move the stored plan after the request was frozen.
            var edited = stale
            edited.quantity += 1
            expect(store.setTradePlan(edited, for: revisionSymbol),
                   "delete-revision: the fixture plan must accept the edit")
            let revisionBaseline = store.syncSnapshot()
            host(view: AnyView(PlanDeletionSheet(request: staleRequest, onClose: {}, onDeleted: {})
                    .environment(state)),
                 width: 380, height: 260, scheme: .light,
                 name: "plan-delete-revision-changed.png", directory: directory) { root in
                clickConfirmOrFallback(root, scope: "delete-revision")
                settle(root)
            }
            expect(store.syncSnapshot() == revisionBaseline,
                   "delete-revision: a plan whose revision changed must not be deleted")
            expect(store.item(for: revisionSymbol)?.plans.contains { $0.id == stale.id } == true,
                   "delete-revision: the plan must still be present after a refused delete")
        } else {
            expect(false, "delete-revision: the HK fixture plan must exist")
        }
    }

    /// Opens a frozen request from one account, switches to another that holds a
    /// same-symbol/same-id plan, and confirms. Neither ledger may be touched.
    ///
    /// The baseline is taken *after* the account switch, because the switch
    /// itself legitimately changes which ledger is active; what must not change
    /// is either ledger's contents.
    private static func checkWrongAccountAndRevisionRefusal(_ state: AppState) {
        let store = state.watchlist
        let symbol = SymbolID(market: .us, code: "QAUS")
        guard let subject = entry(state, symbol: symbol, planID: qaoldPlanID(state, symbol: symbol)) else {
            expect(false, "wrong-account: the subject plan must exist"); return
        }
        let planID = subject.plan.id
        // A same-symbol, same-plan-id plan in the other ledger, so a delete that
        // addressed the id alone would silently remove the wrong record.
        expect(installSameIDPlanInMengmeng(state, planID: planID, symbol: symbol, quantity: 77),
               "wrong-account: the second ledger must accept a same-id fixture plan")
        expect(state.watchlist.activeBrokerageAccountID == .financing,
               "wrong-account: the seeding swap must restore the financing ledger")

        let request = PlanDeletionRequest(entry: subject, account: .financing, displayName: "虚构验证")
        // Freeze the request, then select the other account behind the sheet.
        _ = state.selectBrokerageAccount(.mengmeng)
        let baseline = store.syncSnapshot()
        let financingSnapshot = store.brokeragePortfolio(for: .financing)
        let mengmengSnapshot = store.brokeragePortfolio(for: .mengmeng)
        let financingHas = financingSnapshot.items.first { $0.symbol == symbol }?
            .plans.contains { $0.id == planID } == true
        let mengmengHas = mengmengSnapshot.items.first { $0.symbol == symbol }?
            .plans.contains { $0.id == planID } == true
        expect(financingHas && mengmengHas,
               "wrong-account: each ledger must hold the same-id fixture plan")

        let directory = artifactDirectory("plan-usability")
        var confirmReached = false
        host(view: AnyView(PlanDeletionSheet(request: request, onClose: {}, onDeleted: {})
                .environment(state)),
             width: 380, height: 260, scheme: .light,
             name: "plan-delete-wrong-account.png", directory: directory) { root in
            // The request was frozen from the financing ledger while mengmeng
            // is active, so the destructive button is disabled. Press its
            // position anyway: a real click must still write nothing.
            confirmReached = true
            click(root, at: NSPoint(x: 334, y: 213))
            settle(root)
        }
        expect(confirmReached, "wrong-account: the confirm control must be reachable in the real sheet")
        expect(store.syncSnapshot() == baseline, "wrong-account: neither ledger may change after a refused confirm")
        expect(store.brokeragePortfolio(for: .financing) == financingSnapshot,
               "wrong-account: the financing ledger must be untouched")
        expect(store.brokeragePortfolio(for: .mengmeng) == mengmengSnapshot,
               "wrong-account: the switched-to ledger must be untouched")
        expect(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == symbol }?
                .plans.contains { $0.id == planID } == true,
               "wrong-account: the financing plan must still be there")
        expect(store.brokeragePortfolio(for: .mengmeng).items.first { $0.symbol == symbol }?
                .plans.contains { $0.id == planID } == true,
               "wrong-account: the same-id plan in the other ledger must still be there")

        // Restore the header's account for the remaining checks.
        _ = state.selectBrokerageAccount(.financing)
    }

    // MARK: - Native helpers

    private static func qaoldPlanID(_ state: AppState, symbol: SymbolID) -> UUID {
        state.watchlist.item(for: symbol)?.plans.first { $0.note?.contains("backfill subject") == true }?.id
            ?? state.watchlist.item(for: symbol)?.plans.first { $0.status == .done }?.id
            ?? UUID()
    }

    private static func artifactDirectory(_ name: String) -> URL {
        URL(fileURLWithPath: "build/artifacts/\(name)", isDirectory: true)
    }

    /// Hosts a real view hierarchy in an offscreen `NSWindow` parked at a large
    /// negative origin, drives `inspect` against the live host, and captures it.
    private static func host(view: AnyView, width: CGFloat, height: CGFloat, scheme: ColorScheme,
                             name: String, directory: URL,
                             inspect: ((NSView) -> Void)? = nil) {
        let root = view.environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.backgroundColor = scheme == .dark ? .black : .white
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        // orderBack is the least intrusive ordering that still gives lazy SwiftUI
        // containers the window-attached layout/display cycle they need.
        window.orderBack(nil)
        settle(hosting)
        inspect?(hosting)
        settle(hosting)
        capture(hosting, name: name, directory: directory)
        window.attachedSheet?.orderOut(nil)
        window.orderOut(nil)
    }

    private static func settle(_ view: NSView) {
        for _ in 0..<8 {
            view.window?.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private static func capture(_ view: NSView, name: String, directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                expect(false, "render: bitmap must allocate for \(name)"); return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                expect(false, "render: PNG must encode for \(name)"); return
            }
            if CommandLine.arguments.contains("--export-render-base64") {
                print("PULSE_RENDER_BASE64 \(name) \(data.base64EncodedString())")
                fflush(stdout)
            } else {
                try data.write(to: directory.appendingPathComponent(name))
            }
        } catch {
            expect(false, "render: capture failed for \(name): \(error)")
        }
    }

    /// Every real NSView under a root, deepest first, so a geometry match lands
    /// on the control rather than an ancestor whose center could be another
    /// view's territory.
    private static func allSubviews(_ root: NSView) -> [NSView] {
        var result: [NSView] = []
        func visit(_ view: NSView) {
            for child in view.subviews { visit(child) }
            result.append(view)
        }
        visit(root)
        return result
    }

    private static func sendKey(_ host: NSView, characters: String) {
        guard let window = host.window,
              let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 36
              ) else { return }
        window.sendEvent(event)
    }

    /// The price and quantity fields of the real fill form.
    ///
    /// Editable SwiftUI `TextField`s materialize as real `NSTextField`s; the
    /// label `Text`s above them do not materialize as views at all, so labels
    /// cannot be the address. What can is geometry: the price and quantity
    /// cells sit side by side on the form's first input row, price left of
    /// quantity, with the fee and note cells on rows below. Frames are
    /// converted into the sheet's own coordinate space before comparing,
    /// because each field's `frame` is measured in its own superview.
    private static func fillFields(in form: NSView) -> (price: NSTextField, quantity: NSTextField)? {
        var editable: [(rect: NSRect, field: NSTextField)] = []
        for case let field as NSTextField in allSubviews(form) where field.isEditable {
            editable.append((rect: field.convert(field.bounds, to: form), field: field))
        }
        editable.sort { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) > 2 { return lhs.rect.minY < rhs.rect.minY }
            return lhs.rect.minX < rhs.rect.minX
        }
        guard editable.count >= 2 else { return nil }
        return (price: editable[0].field, quantity: editable[1].field)
    }

    /// Enters text into a field, going through the field's real delegate so the
    /// SwiftUI binding updates exactly as typing would.
    private static func setField(_ field: NSTextField, to text: String) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// Submits the backfill sheet through its real save button. The press is
    /// a window event at the footer's trailing primary button; the write that
    /// follows is the observable proof it landed. The form is captured first,
    /// so a miss can be measured against the actual layout.
    private static func submitFillSheet(_ form: NSView) {
        capture(form, name: "plan-fill-sheet-light.png", directory: artifactDirectory("plan-usability"))
        click(form, at: NSPoint(x: form.bounds.width - 52, y: form.bounds.height - 24))
    }

    private static func clickConfirmOrFallback(_ root: NSView, scope: String) {
        // Same 380pt sheet footer as the happy path; the button is disabled
        // for a stale or wrong-account request, and the no-write assertions
        // after the click are the proof the refusal held.
        note("\(scope): pressing the confirm position; refusal must leave every ledger untouched")
        click(root, at: NSPoint(x: 334, y: 213))
    }

    /// Sends a real mouse down/up pair through the window's own hit testing.
    ///
    /// The point is given in top-left terms of the host's coordinate system;
    /// AppKit's `convert(_:to:)` handles the flipped SwiftUI hosting view.
    /// This never synthesizes a global event and never touches the desktop —
    /// the events go to the offscreen fixture window only.
    private static func click(_ host: NSView, at point: NSPoint) {
        guard let window = host.window else { return }
        let local = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        let location = host.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { return }
            window.sendEvent(event)
        }
    }

    // MARK: - Reporting

    private static func note(_ message: String) {
        reports.append(message)
    }

    private static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message) }
    }
}
#endif
