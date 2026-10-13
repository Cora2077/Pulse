#if DEBUG
import AppKit
import SwiftUI
import PulseCore
import PulseUI
import Vision

/// Native acceptance for the bounded stage-1 trade mutation callers.
///
/// It drives the *real* `TradeEntryView` inside an offscreen `NSWindow` using
/// real window events and AppKit accessibility actions in this process only —
/// never a global event tap and never a click on the developer's desktop. The
/// store is the real `WatchlistStore` on the disposable `--main-window-demo`
/// suite, so nothing here can read or write the developer's real data.
///
/// Run: FFF --main-window-demo --trade-mutation-selftest [--export-render-base64]
///
/// Every fixture is fictional: the symbols QAMUT/QARET exist only in the
/// throwaway suite. No network, no live account, no signing.
@MainActor
enum TradeMutationSelfTest {
    private static var failures: [String] = []
    private static var checks = 0
    private static var reports: [String] = []

    private static let symbol = SymbolID(market: .us, code: "QAMUT")
    private static let retainedSymbol = SymbolID(market: .us, code: "QARET")

    // MARK: - Entry point

    static func run() -> Bool {
        failures = []
        checks = 0
        reports = []
        guard CommandLine.arguments.contains("--main-window-demo") else {
            print("PULSE_TRADE_MUTATION_SELFTEST failed: requires --main-window-demo")
            fflush(stdout)
            return false
        }
        let state = AppState()
        resetToOfflineFixture(state)
        let directory = URL(fileURLWithPath: "build/artifacts/trade-mutation", isDirectory: true)

        checkStalePriceDraftIsRefused(state, directory: directory)
        checkStaleDeleteIsRefused(state, directory: directory)
        checkNegativeBuyEditIsRefusedThenRepairs(state, directory: directory)
        checkRetainedHistoryEditAndDelete(state, directory: directory)
        checkWrongAccountGuardAndDoubleSubmit(state, directory: directory)
        checkFrozenExpectedSurvivesParentRebuild(state, directory: directory)

        for report in reports { print("PULSE_TRADE_MUTATION_SELFTEST note \(report)") }
        for failure in failures { print("PULSE_TRADE_MUTATION_SELFTEST failure: \(failure)") }
        print("PULSE_TRADE_MUTATION_SELFTEST \(failures.isEmpty ? "passed" : "failed") checks=\(checks) failures=\(failures.count)")
        fflush(stdout)
        return failures.isEmpty
    }

    // MARK: - Fixture

    /// Clears the seeded demo suite and installs one fictional ledger per check.
    private static func resetToOfflineFixture(_ state: AppState) {
        let store = state.watchlist
        store.enableBrokerageAccounts()
        let groups = [WatchlistGroup(name: "Synthetic")]
        let empty = WatchlistSyncSnapshot(items: [], groups: groups,
            brokerageAccounts: BrokerageAccountID.allCases.filter { $0 != .unassigned }.map {
                BrokerageAccountPortfolio(accountID: $0, groups: [WatchlistGroup(name: "Synthetic")])
            })
        expect(store.applySyncSnapshot(empty), "fixture: the disposable portfolios must reset")
        for info in [SymbolInfo(symbol: symbol, name: "虚构验证", type: .equity),
                     SymbolInfo(symbol: retainedSymbol, name: "虚构验证", type: .equity)] {
            store.withBrokerageAccount(.financing) { store.add(info) }
        }
        state.market.apply(quotes: [
            Quote(symbol: symbol, name: "虚构验证", price: 120, previousClose: 118,
                  currencyCode: "USD", timestamp: .now),
            Quote(symbol: retainedSymbol, name: "虚构验证", price: 40, previousClose: 39,
                  currencyCode: "USD", timestamp: .now),
        ])
        // The daily cache is seeded directly so the closed-day hint never needs
        // the network: the demo providers are disabled, and this keeps the
        // engine out of the check entirely.
        for target in [symbol, retainedSymbol] {
            state.market.cache(
                candles: syntheticDailyCandles(base: target == symbol ? 120 : 40),
                for: CandleCacheKey(symbol: target, period: .day)
            )
        }
        _ = state.selectBrokerageAccount(.financing)
    }

    /// 60 synthetic daily bars ending today, all inside the market's own day.
    private static func syntheticDailyCandles(base: Double) -> [Candle] {
        let day = 86_400.0
        let today = Calendar.current.startOfDay(for: .now)
        return (0..<60).reversed().enumerated().map { offset, _ in
            let time = today.addingTimeInterval(-day * Double(offset))
            let close = base * (1 + Double(offset) * 0.001)
            return Candle(time: time, open: close * 0.995, high: close * 1.01,
                          low: close * 0.99, close: close, volume: 1_000)
        }.sorted { $0.time < $1.time }
    }

    /// Records a buy through the checked route so the fixture itself uses the
    /// go-forward write path under test.
    @discardableResult
    private static func openLong(_ state: AppState, quantity: Double, price: Double,
                                 symbol target: SymbolID, account: BrokerageAccountID = .financing) -> PositionTransaction? {
        do {
            return try state.watchlist.recordTransaction(target, PositionTransaction(
                kind: .buy, price: price, quantity: quantity, date: .now,
                fundingSource: .own, brokerageAccountID: account
            ), account: account)
        } catch {
            report("fixture", "opening buy failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Check 1: a stale price draft is refused and stays on the route

    /// Opens the real edit form, then moves the stored record underneath it (the
    /// same thing the parent's live re-read does on a sync) and presses Save.
    /// The form must stay on its own route, keep the typed value, and show the
    /// store's sentence — its frozen `expected` no longer matches.
    private static func checkStalePriceDraftIsRefused(_ state: AppState, directory: URL) {
        resetToOfflineFixture(state)
        let store = state.watchlist
        guard let opening = openLong(state, quantity: 100, price: 100, symbol: symbol) else {
            expect(false, "stale-price: fixture buy must record"); return
        }
        var route = PopoverRoute.editTrade(symbol, opening.id, .detail(symbol))
        let binding = Binding(get: { route }, set: { route = $0 })

        host(view: AnyView(TradeEntryView(symbol: symbol, editing: opening, returnRoute: .detail(symbol),
                                          route: binding, account: .financing).environment(state)),
             width: 380, height: 520, scheme: .light,
             name: "stale-price-refused.png", directory: directory) { form in
            guard let fields = entryFields(in: form) else {
                expect(false, "stale-price: the real price and quantity fields must exist"); return
            }
            // 110 is the draft the user typed and can still see.
            setField(fields.price, to: "110")
            settle(form)
            let typed = fields.price.stringValue
            expect(typed == "110", "stale-price: the field must hold the typed draft (got \(typed))")

            // The record moves: exactly what a sync, a review edit, or an
            // ownership correction does while the form stays mounted.
            var moved = opening
            moved.price = 120
            do {
                _ = try store.updateTransaction(symbol, moved, expected: opening, account: .financing)
            } catch {
                expect(false, "stale-price: the fixture's store-side move must succeed"); return
            }
            settle(form)

            let before = store.syncSnapshot()
            pressSave(form)
            let after = store.syncSnapshot()

            expect(after == before, "stale-price: a refused save must not write anything")
            expect(routeKey(route) == routeKey(.editTrade(symbol, opening.id, .detail(symbol))),
                   "stale-price: a refusal must stay on the same route (got \(routeKey(route)))")
            expect(fields.price.stringValue == "110",
                   "stale-price: a refusal must leave the input unchanged (got \(fields.price.stringValue))")
            expect(showsRefusal(form, error: .staleRecord),
                   "stale-price: the refusal sentence must be visible inline")
            expect(store.item(for: symbol)?.transactions.first { $0.id == opening.id }?.price == 120,
                   "stale-price: the moved record is the one that survives")
        }
    }

    // MARK: - Check 2: a stale delete is refused

    private static func checkStaleDeleteIsRefused(_ state: AppState, directory: URL) {
        resetToOfflineFixture(state)
        let store = state.watchlist
        guard let opening = openLong(state, quantity: 60, price: 90, symbol: symbol) else {
            expect(false, "stale-delete: fixture buy must record"); return
        }
        var route = PopoverRoute.editTrade(symbol, opening.id, .detail(symbol))
        let binding = Binding(get: { route }, set: { route = $0 })

        host(view: AnyView(TradeEntryView(symbol: symbol, editing: opening, returnRoute: .detail(symbol),
                                          route: binding, account: .financing).environment(state)),
             width: 380, height: 520, scheme: .dark,
             name: "stale-delete-refused-dark.png", directory: directory) { form in
            var moved = opening
            moved.quantity = 55
            do {
                _ = try store.updateTransaction(symbol, moved, expected: opening, account: .financing)
            } catch {
                expect(false, "stale-delete: the fixture's store-side move must succeed"); return
            }
            settle(form)
            let before = store.syncSnapshot()
            pressDelete(form)
            let after = store.syncSnapshot()

            expect(after == before, "stale-delete: a refused delete must not write anything")
            expect(routeKey(route) == routeKey(.editTrade(symbol, opening.id, .detail(symbol))),
                   "stale-delete: a refused delete must stay on the form")
            expect(store.item(for: symbol)?.transactions.contains { $0.id == opening.id } == true,
                   "stale-delete: the record must still exist")
            expect(showsRefusal(form, error: .staleRecord),
                   "stale-delete: the refusal sentence must be visible inline")
        }
    }

    // MARK: - Check 3: a negative replay is refused, then repaired

    /// The regression this whole task exists for: editing a buy from 100 to 50
    /// after a sell of 80 would replay to a negative historical position. The
    /// real form must refuse it with the store's reason and change nothing, and
    /// the same form must then accept a valid correction.
    private static func checkNegativeBuyEditIsRefusedThenRepairs(_ state: AppState, directory: URL) {
        resetToOfflineFixture(state)
        let store = state.watchlist
        guard let opening = openLong(state, quantity: 100, price: 100, symbol: symbol) else {
            expect(false, "negative-edit: fixture buy must record"); return
        }
        do {
            _ = try store.recordTransaction(symbol, PositionTransaction(
                kind: .sell, price: 120, quantity: 80, date: .now, brokerageAccountID: .financing
            ), account: .financing)
        } catch {
            expect(false, "negative-edit: fixture sell must record"); return
        }
        var route = PopoverRoute.editTrade(symbol, opening.id, .detail(symbol))
        let binding = Binding(get: { route }, set: { route = $0 })

        host(view: AnyView(TradeEntryView(symbol: symbol, editing: opening, returnRoute: .detail(symbol),
                                          route: binding, account: .financing).environment(state)),
             width: 380, height: 520, scheme: .light,
             name: "negative-edit-refused.png", directory: directory) { form in
            guard let fields = entryFields(in: form) else {
                expect(false, "negative-edit: fields must exist"); return
            }
            setField(fields.quantity, to: "50")
            settle(form)
            let before = store.syncSnapshot()
            pressSave(form)
            expect(store.syncSnapshot() == before,
                   "negative-edit: the refused 100 -> 50 edit must change nothing")
            expect(routeKey(route) == routeKey(.editTrade(symbol, opening.id, .detail(symbol))),
                   "negative-edit: a refusal must not navigate away")
            let refusal = visibleText(in: form)
            expect(showsRefusal(form, error: .negativePosition),
                   "negative-edit: the store's negative-position reason must be shown inline")
            capture(form, name: "negative-error-light.png", directory: directory)
            expect(!refusal.contains(PulseLocalization.localizedString("trade.invalidFee")),
                   "negative-edit: the refusal must not be a field-validation message")

            // Repair in the same open form: a value that still replays valid.
            setField(fields.quantity, to: "200")
            settle(form)
            pressSave(form)
            expect(store.item(for: symbol)?.transactions.first { $0.id == opening.id }?.quantity == 200,
                   "negative-edit: the repaired 100 -> 200 edit must land")
            expect(routeKey(route) != routeKey(.editTrade(symbol, opening.id, .detail(symbol))),
                   "negative-edit: a successful save must leave the form")
        }
    }

    // MARK: - Check 4: retained history stays editable and stays dormant

    private static func checkRetainedHistoryEditAndDelete(_ state: AppState, directory: URL) {
        resetToOfflineFixture(state)
        let store = state.watchlist
        guard let opening = openLong(state, quantity: 40, price: 40, symbol: retainedSymbol) else {
            expect(false, "retained: fixture buy must record"); return
        }
        let sell: PositionTransaction
        do {
            sell = try store.recordTransaction(retainedSymbol, PositionTransaction(
                kind: .sell, price: 45, quantity: 10, date: .now, brokerageAccountID: .financing
            ), account: .financing)
        } catch {
            expect(false, "retained: fixture sell must record"); return
        }
        store.withBrokerageAccount(.financing) { store.remove(retainedSymbol) }
        let dormant = store.brokeragePortfolio(for: .financing).groups
            .allSatisfy { !$0.symbols.contains(retainedSymbol) }
        expect(dormant, "retained: the fixture must really be dormant")
        expect(store.retainedHistoryItem(for: retainedSymbol) != nil, "retained: the fixture must really be retained")

        var route = PopoverRoute.editTrade(retainedSymbol, sell.id, .detail(retainedSymbol))
        let binding = Binding(get: { route }, set: { route = $0 })

        host(view: AnyView(TradeEntryView(symbol: retainedSymbol, editing: sell, returnRoute: .detail(retainedSymbol),
                                          route: binding, account: .financing).environment(state)),
             width: 380, height: 520, scheme: .dark,
             name: "retained-edit.png", directory: directory) { form in
            guard let fields = entryFields(in: form) else {
                expect(false, "retained: fields must exist"); return
            }
            setField(fields.price, to: "47")
            settle(form)
            pressSave(form)
            let edited = store.retainedHistoryItem(for: retainedSymbol)?.transactions.first { $0.id == sell.id }
            expect(edited?.price == 47, "retained: the dormant record must accept the edit")
            expect(store.item(for: retainedSymbol) == nil,
                   "retained: an edit must not restore the symbol to a group")
            expect(store.brokeragePortfolio(for: .financing).groups
                .allSatisfy { !$0.symbols.contains(retainedSymbol) },
                   "retained: the symbol must stay dormant after an edit")
            expect(store.retainedHistoryItem(for: retainedSymbol)?
                .transactions.contains { $0.id == opening.id } == true,
                   "retained: the sibling buy must survive the edit")
        }

        var deleteRoute = PopoverRoute.editTrade(retainedSymbol, sell.id, .detail(retainedSymbol))
        let deleteBinding = Binding(get: { deleteRoute }, set: { deleteRoute = $0 })
        guard let liveSell = store.retainedHistoryItem(for: retainedSymbol)?.transactions.first(where: { $0.id == sell.id }) else {
            expect(false, "retained: the edited record must be readable"); return
        }
        host(view: AnyView(TradeEntryView(symbol: retainedSymbol, editing: liveSell, returnRoute: .detail(retainedSymbol),
                                          route: deleteBinding, account: .financing).environment(state)),
             width: 380, height: 520, scheme: .light,
             name: "retained-delete.png", directory: directory) { form in
            pressDelete(form)
            let remaining = store.draftItem(for: retainedSymbol, account: .financing)?.transactions ?? []
            expect(!remaining.contains { $0.id == sell.id },
                   "retained: the dormant record must be deleted")
            // The retained sibling remains, so the form must return to the log
            // rather than to the hub — an empty-looking ledger would be wrong.
            expect(remaining.contains { $0.id == opening.id },
                   "retained: the remaining history must include the retained sibling")
            expect(routeKey(deleteRoute) == routeKey(.transactions(retainedSymbol, .detail(retainedSymbol))),
                   "retained: a delete with history left must go to the trade log (got \(routeKey(deleteRoute)))")
        }
    }

    // MARK: - Check 5: wrong account guard and double submit

    private static func checkWrongAccountGuardAndDoubleSubmit(_ state: AppState, directory: URL) {
        resetToOfflineFixture(state)
        let store = state.watchlist
        guard let opening = openLong(state, quantity: 30, price: 50, symbol: symbol) else {
            expect(false, "guard: fixture buy must record"); return
        }
        var route = PopoverRoute.editTrade(symbol, opening.id, .detail(symbol))
        let binding = Binding(get: { route }, set: { route = $0 })

        // The store is pointed at another ledger while the form stays mounted.
        _ = state.selectBrokerageAccount(.mengmeng)
        host(view: AnyView(TradeEntryView(symbol: symbol, editing: opening, returnRoute: .detail(symbol),
                                          route: binding, account: .financing).environment(state)),
             width: 380, height: 520, scheme: .light,
             name: "wrong-account.png", directory: directory) { form in
            guard let fields = entryFields(in: form) else {
                expect(false, "guard: fields must exist"); return
            }
            setField(fields.price, to: "60")
            settle(form)
            let before = store.syncSnapshot()
            pressSave(form)
            expect(store.syncSnapshot() == before,
                   "guard: a draft whose ledger is no longer selected must not write")
            expect(store.draftItem(for: symbol, account: .financing)?.transactions.first { $0.id == opening.id }?.price == 50,
                   "guard: the record is untouched by a refused write")
        }
        _ = state.selectBrokerageAccount(.financing)

        // Double submit: two Returns in one gesture must record one trade.
        var recordRoute = PopoverRoute.trade(symbol, .buy, .detail(symbol))
        let recordBinding = Binding(get: { recordRoute }, set: { recordRoute = $0 })
        let countBefore = store.draftItem(for: symbol, account: .financing)?.transactions.count ?? 0
        host(view: AnyView(TradeEntryView(symbol: symbol, side: .buy, returnRoute: .detail(symbol),
                                          route: recordBinding, account: .financing).environment(state)),
             width: 380, height: 520, scheme: .light,
             name: "double-submit.png", directory: directory) { form in
            guard let fields = entryFields(in: form) else {
                expect(false, "double-submit: fields must exist"); return
            }
            setField(fields.price, to: "77")
            setField(fields.quantity, to: "11")
            settle(form)
            pressReturn(form)
            pressReturn(form)
            pressSave(form)
            settle(form)
            let after = store.draftItem(for: symbol, account: .financing)?.transactions.count ?? 0
            expect(after == countBefore + 1,
                   "double-submit: two Returns must record exactly one trade (was \(countBefore), now \(after))")
        }
    }

    // MARK: - Check 6: the frozen expected survives a live parent rebuild

    /// Mounts the form under a parent that re-reads the live record and rebuilds
    /// the child, then moves the stored record and edits through the *same*
    /// mounted form. Its expected original must stay frozen, so the changed
    /// record is refused instead of the old input silently overwriting it.
    private static func checkFrozenExpectedSurvivesParentRebuild(_ state: AppState, directory: URL) {
        resetToOfflineFixture(state)
        let store = state.watchlist
        guard let opening = openLong(state, quantity: 70, price: 70, symbol: symbol) else {
            expect(false, "frozen: fixture buy must record"); return
        }
        var route = PopoverRoute.editTrade(symbol, opening.id, .detail(symbol))
        let binding = Binding(get: { route }, set: { route = $0 })

        host(view: AnyView(TradeMutationParentFixture(symbol: symbol, transactionID: opening.id,
                                                      route: binding).environment(state)),
             width: 380, height: 520, scheme: .light,
             name: "parent-rebuild-edit.png", directory: directory) { form in
            guard let fields = entryFields(in: form) else {
                expect(false, "frozen: fields must exist"); return
            }
            let shown = fields.price.stringValue
            expect(shown == "70", "frozen: the form must open on the stored price (got \(shown))")

            // A background write the form did not make — a sync landing, a
            // review edit, another window. The parent re-reads and rebuilds.
            var touched = opening
            touched.fee = 3
            do {
                _ = try store.updateTransaction(symbol, touched, expected: opening, account: .financing)
            } catch {
                expect(false, "frozen: the background write must succeed"); return
            }
            settle(form)
            expect(fields.price.stringValue == "70",
                   "frozen: the parent rebuild must not re-seed the visible fields")

            // The user edits a field the background write never touched.
            setField(fields.quantity, to: "85")
            settle(form)
            pressSave(form)

            let stored = store.item(for: symbol)?.transactions.first { $0.id == opening.id }
            expect(stored?.quantity == 70,
                   "frozen: a stale form must not overwrite the live quantity")
            expect(stored?.fee == 3,
                   "frozen: the background write must survive the edit")
            expect(routeKey(route) == routeKey(.editTrade(symbol, opening.id, .detail(symbol))),
                   "frozen: a refused stale save stays on the form")
            expect(showsRefusal(form, error: .staleRecord),
                   "frozen: the parent rebuild must not replace the expected stamp")
        }
    }

    // MARK: - Native driving helpers

    /// The store's own stale-record sentence, in whichever language the harness
    /// is running. Asserted as a fragment so the check does not re-implement the
    /// store's wording.
    private static var storeRefusalFragment: String {
        let expected = TradeMutationError.staleRecord.errorDescription ?? ""
        guard let first = expected.split(separator: " ").first, first.count > 6 else { return expected }
        return String(first)
    }

    /// The real price, quantity, and fee fields of the entry form. Editable
    /// SwiftUI `TextField`s materialize as real `NSTextField`s; the labels above
    /// them do not materialize as views at all, so geometry is the address: the
    /// price and quantity cells share the first input row, price left of
    /// quantity, with the fee cell on the row below.
    private static func entryFields(in form: NSView) -> (price: NSTextField, quantity: NSTextField, fee: NSTextField)? {
        var editable: [(rect: NSRect, field: NSTextField)] = []
        for case let field as NSTextField in allSubviews(form) where field.isEditable {
            editable.append((rect: field.convert(field.bounds, to: form), field: field))
        }
        editable.sort { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) > 2 { return lhs.rect.minY < rhs.rect.minY }
            return lhs.rect.minX < rhs.rect.minX
        }
        guard editable.count >= 3 else { return nil }
        return (price: editable[0].field, quantity: editable[1].field, fee: editable[2].field)
    }

    private static func setField(_ field: NSTextField, to text: String) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// The real Save button at the form's footer, pressed through the window's
    /// own hit testing. A missed point fails loudly: the write assertions that
    /// follow are the proof the press landed.
    private static func pressSave(_ form: NSView) {
        click(form, at: NSPoint(x: form.bounds.width - 40, y: form.bounds.height - 24))
    }

    /// The real Delete button at the footer's leading edge.
    private static func pressDelete(_ form: NSView) {
        click(form, at: NSPoint(x: 40, y: form.bounds.height - 24))
    }

    /// Return, the form's own confirm gesture (`onSubmit` + the default action).
    private static func pressReturn(_ form: NSView) {
        guard let window = form.window,
              let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
              ) else { return }
        window.sendEvent(event)
        settle(form)
    }

    /// Real mouse down/up through the window, in top-left terms of the host.
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
        settle(host)
    }

    private static func allSubviews(_ root: NSView) -> [NSView] {
        var result: [NSView] = []
        func visit(_ view: NSView) {
            for child in view.subviews { visit(child) }
            result.append(view)
        }
        visit(root)
        return result
    }

    /// Every string the rendered hierarchy currently shows. SwiftUI `Text`
    /// lives in the accessibility tree as well as in the field values, so this
    /// reads the on-screen sentence rather than a value copied into the harness.
    private static func visibleText(in root: NSView) -> String {
        var parts: [String] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ node: any NSAccessibilityProtocol) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let label = node.accessibilityLabel() { parts.append(label) }
            if let value = node.accessibilityValue() as? String { parts.append(value) }
            if let title = node.accessibilityTitle() { parts.append(title) }
            for child in node.accessibilityChildren() ?? [] {
                if let child = child as? any NSAccessibilityProtocol { visit(child) }
            }
        }
        for view in allSubviews(root) {
            if let field = view as? NSTextField { parts.append(field.stringValue) }
            visit(view)
        }
        // Offscreen SwiftUI text is not always exposed in the accessibility
        // tree. Verify the actual rendered pixels too, with local Vision OCR.
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            if let image = bitmap.cgImage {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    parts += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                } catch { report("render-text", "Local OCR failed: \(error)") }
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func showsRefusal(_ form: NSView, error: TradeMutationError) -> Bool {
        func normalized(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        }
        let text = visibleText(in: form)
        let expected = error.errorDescription ?? "MISSING"
        let found = normalized(text).contains(normalized(expected))
        if !found { report("render-text", "Rendered text: \(text)") }
        return found
    }

    private static func settle(_ view: NSView) {
        for _ in 0..<10 {
            view.window?.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Hosts the real view in an offscreen window parked far off-screen, drives
    /// `inspect` against the live host, capturers a native PNG, and tears down.
    private static func host(view: AnyView, width: CGFloat, height: CGFloat, scheme: ColorScheme,
                             name: String, directory: URL, inspect: (NSView) -> Void) {
        let root = view.environment(\.colorScheme, scheme)
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.backgroundColor = scheme == .dark ? .black : .white
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        settle(hosting)
        inspect(hosting)
        settle(hosting)
        capture(hosting, name: name, directory: directory)
        window.orderOut(nil)
    }

    private static func capture(_ view: NSView, name: String, directory: URL) {
        do {
            if !CommandLine.arguments.contains("--export-render-base64") {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
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

    // MARK: - Reporting

    /// A stable textual identity for a route, so the checks can assert the form
    /// did or did not navigate without depending on `PopoverRoute`'s equality.
    private static func routeKey(_ route: PopoverRoute) -> String {
        String(describing: route)
    }

    private static func report(_ scope: String, _ message: String) {
        reports.append("\(scope): \(message)")
    }

    private static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures.append(message) }
    }
}

// MARK: - Parent-rebuild fixture

/// The real parent shape: it re-reads the *live* record on every store change
/// and rebuilds `TradeEntryView` from it, exactly as `PopoverRootView` and
/// `MainInstrumentView` do.
///
/// This is the check the frozen `@State` exists for. Without it the form's
/// fields would keep the old values while `expected` re-seeded from the new
/// record, incorrectly passing the check. The frozen original makes the stale
/// write refuse, preserving the update and the user's unsaved input.
@MainActor
private struct TradeMutationParentFixture: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    let transactionID: UUID
    @Binding var route: PopoverRoute

    var body: some View {
        if let live = appState.watchlist.draftItem(for: symbol, account: .financing)?
            .transactions.first(where: { $0.id == transactionID }) {
            TradeEntryView(
                symbol: symbol,
                editing: live,
                returnRoute: .detail(symbol),
                route: $route,
                account: .financing
            )
        } else {
            Text("missing")
        }
    }
}
#endif
