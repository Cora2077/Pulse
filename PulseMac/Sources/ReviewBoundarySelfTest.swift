#if DEBUG
import AppKit
import SwiftUI
import Vision
import PulseCore

/// Offline native checks of the production conflict card, shared trade badge,
/// and alert controller. Only disposable demo defaults and fictional data.
@MainActor
enum ReviewBoundarySelfTest {
    private static var failures: [String] = []
    private static var checks = 0

    static func run() -> Bool {
        guard CommandLine.arguments.contains("--main-window-demo") else { return false }
        failures = []; checks = 0
        let state = AppState()
        checkAlertProgress(state)
        checkConflictCard()
        checkPlanActions(state)
        for scheme in [ColorScheme.light, .dark] {
            var renders: [Data] = []
            for redUp in [true, false] {
                state.settings.redUp = redUp
                let view = HStack(spacing: 16) {
                    TradeKindBadge(kind: .buy)
                    TradeKindBadge(kind: .sell)
                    TradeKindBadge(kind: .adjustment)
                }.padding(18)
                if let data = host(AnyView(view), width: 380, height: 80, scheme: scheme,
                    name: "trade-badges-\(scheme)-redUp-\(redUp).png") { renders.append(data) }
            }
            expect(renders.count == 2 && renders[0] == renders[1], "Direction badges must be pixel-identical after changing quote colours in \(scheme)")
        }
        for failure in failures { print("PULSE_REVIEW_BOUNDARY_SELFTEST failure: \(failure)") }
        print("PULSE_REVIEW_BOUNDARY_SELFTEST \(failures.isEmpty ? "passed" : "failed") checks=\(checks) failures=\(failures.count)")
        fflush(stdout)
        return failures.isEmpty
    }

    private static func checkAlertProgress(_ state: AppState) {
        let symbol = SymbolID(market: .us, code: "QAALERT")
        let plan = TradePlan(kind: .buy, price: 100, quantity: 100)
        let fill = PositionTransaction(kind: .buy, price: 100, quantity: 100,
            planExecution: .init(planID: plan.id, configuration: .init(plan: plan), sourceAccountID: .financing),
            brokerageAccountID: .mengmeng)
        let snapshot = WatchlistSyncSnapshot(items: [], groups: [.init(name: "Synthetic")], brokerageAccounts: [
            .init(accountID: .financing, items: [.init(symbol: symbol, displayName: "Fictional plan", plans: [plan])], groups: [.init(name: "Synthetic", symbols: [symbol])]),
            .init(accountID: .mengmeng, items: [.init(symbol: symbol, displayName: "Fictional fill", transactions: [fill])], groups: [.init(name: "Synthetic", symbols: [symbol])])])
        expect(state.watchlist.applySyncSnapshot(snapshot), "Alert fixture must install in demo only")
        let quote = Quote(symbol: symbol, price: 99, previousClose: 101, timestamp: .now)
        state.market.apply(quotes: [quote])
        let entry = state.planAlerts.entries(in: .financing).first { $0.plan.id == plan.id }
        expect(entry?.plan.status == .active && entry?.displayState == .filled, "Controller must read real cross-account fills, including stale active status")
        expect(!state.planAlerts.notificationIsDue(plan, account: .financing, quote: quote), "Completed raw-active plan must not alert")
        let id = PlanAlertController.notificationID(account: .financing, planID: plan.id)
        expect(state.planAlerts.target(for: id)?.planID == plan.id, "Notification identity must remain the raw plan ID, not the display row hash")
    }

    private static func checkConflictCard() {
        let symbol = SymbolID(market: .us, code: "QASYNC")
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let original = PositionTransaction(kind: .buy, price: 100, quantity: 100, date: day, createdAt: day)
        var base = WatchlistSyncSnapshot(items: [], groups: [.init(name: "Synthetic")], brokerageAccounts: [
            .init(accountID: .financing, items: [.init(symbol: symbol, displayName: "Fictional conflict", transactions: [original])], groups: [.init(name: "Synthetic", symbols: [symbol])]),
            .init(accountID: .mengmeng, groups: [.init(name: "Synthetic")])])
        base.brokerageAccounts![0].settings = .init(cashBalances: ["USD": .init(amount: 100, updatedAt: day)])
        var local = base, remote = base
        local.brokerageAccounts![0].items[0].transactions[0].price = 110
        remote.brokerageAccounts![0].items[0].transactions[0].price = 120
        local.brokerageAccounts![0].settings!.cashBalances["USD"] = .init(amount: 200, updatedAt: day)
        remote.brokerageAccounts![0].settings!.cashBalances["USD"] = .init(amount: 300, updatedAt: day)
        let independent = PositionTransaction(kind: .buy, price: 50, quantity: 5, date: day, createdAt: day)
        remote.brokerageAccounts![1].items = [.init(symbol: symbol, displayName: "Fictional independent", transactions: [independent])]
        remote.brokerageAccounts![1].groups[0].symbols = [symbol]
        local.brokerageAccounts![0].items[0].positionAllocation = .init(
            basisFingerprint: PositionAllocation.basisFingerprint(for: local.brokerageAccounts![0].items[0]),
            portions: [.init(quantity: 100, pool: .strategic, origin: .init(kind: .snapshot))])
        remote.brokerageAccounts![0].items[0].positionAllocation = .init(
            basisFingerprint: PositionAllocation.basisFingerprint(for: remote.brokerageAccounts![0].items[0]),
            portions: [.init(quantity: 100, pool: .tactical, origin: .init(kind: .snapshot))])
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        let summary = FolderSyncController.conflictSummary(peerID: "fictional-peer", trades: result.conflicts,
            allocations: result.positionAllocationConflicts, brokerage: result.brokerageConflict)
        expect(summary.count == 3 && summary.examples.count == 3, "Card must name trade, cash, and allocation conflicts, not the whole account")
        for scheme in [ColorScheme.light, .dark] {
            var choices: [Bool] = []
            let choose: (Bool) -> Void = { choosingRemote in
                choices.append(choosingRemote)
                do {
                    let resolved = try WatchlistSyncMerge.resolveValidated(result, choosing: choosingRemote ? .remote : .local)
                    expect(resolved.brokerageAccounts![1].items.first?.transactions == [independent], "Real card choice must preserve the other account's independent trade")
                    expect(resolved.brokerageAccounts![0].items.first?.transactions.first?.price == (choosingRemote ? 120 : 110), "Real card choice must select only the disputed trade")
                } catch { expect(false, "Card resolution refused: \(error)") }
            }
            let card = SyncConflictCard(summary: summary, isWorking: false, onChoose: choose)
            _ = host(AnyView(card.padding(12)), width: 380, height: 320, scheme: scheme, name: "sync-conflicts-\(scheme).png") { root in
                let text = recognizedText(root).map(\.text).joined()
                expect(normalized(text).contains(normalized(PulseLocalization.localizedString("sync.conflict.warning"))), "Rendered warning must explain limited scope and preserved independent changes")
                press(PulseLocalization.localizedString("sync.conflict.keepLocal"), in: root)
                press(PulseLocalization.localizedString("sync.conflict.useRemote"), in: root)
                expect(choices == [false, true], "Both real native conflict buttons must execute their own action")
            }
            let allocation = FolderSyncController.PositionAllocationConflictSummary(peerID: summary.id,
                symbol: symbol, accountID: .financing,
                local: local.brokerageAccounts![0].items[0].positionAllocation,
                remote: remote.brokerageAccounts![0].items[0].positionAllocation)
            let sheet = PoolSyncConflictSheet(peerID: summary.id, conflicts: [allocation], summary: summary,
                isWorking: false, onResolve: choose, onCancel: {})
            _ = host(AnyView(sheet), width: 620, height: 480, scheme: scheme, name: "pool-sync-conflicts-\(scheme).png") { root in
                let text = recognizedText(root).map(\.text).joined()
                expect(normalized(text).contains(normalized(PulseLocalization.localizedString("sync.conflict.warning"))),
                    "Allocation sheet must reveal the complete trade/settings selection scope too")
                press(PulseLocalization.localizedString("sync.conflict.keepLocal"), in: root)
                expect(choices == [false, true, false], "Allocation sheet must use the same scoped resolution action")
            }
        }
    }

    private static func checkPlanActions(_ state: AppState) {
        let symbol = SymbolID(market: .us, code: "QAPLAN")
        for scheme in [ColorScheme.light, .dark] {
            let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
            let snapshot = WatchlistSyncSnapshot(items: [], groups: [.init(name: "Synthetic")], brokerageAccounts: [
                .init(accountID: .financing, items: [.init(symbol: symbol, displayName: "Fictional source", plans: [plan])],
                    groups: [.init(name: "Synthetic", symbols: [symbol])]),
                .init(accountID: .mengmeng, items: [.init(symbol: symbol, displayName: "Fictional namesake", plans: [plan])],
                    groups: [.init(name: "Synthetic", symbols: [symbol])])])
            expect(state.watchlist.applySyncSnapshot(snapshot), "Plan action fixture must reset")
            _ = state.selectBrokerageAccount(.unassigned)
            state.market.apply(quotes: [Quote(symbol: symbol, price: 99, previousClose: 101, timestamp: .now)])
            let entry = TradePlanEntry(symbol: symbol, plan: plan, accountID: .financing)
            var presented: [TradePlanAction] = []
            var errors: [String] = []
            let menu = PlanActionMenu(entry: entry, onPresent: { presented.append($0) }, onError: { errors.append($0) })
            _ = host(AnyView(VStack(alignment: .leading, spacing: 12) { menu }.padding(18).environment(state)),
                width: 380, height: 300, scheme: scheme, name: "plan-actions-\(scheme).png") { root in
                let text = normalized(recognizedText(root).map(\.text).joined())
                for action in TradePlanAction.available(for: entry) {
                    expect(text.contains(normalized(PulseLocalization.localizedString(action.titleKey))),
                           "Foreign-account plan must expose \(action.rawValue) in shared native menu contents")
                }
                press(PulseLocalization.localizedString("plans.action.recordFill"), in: root)
                expect(presented == [.recordFill] && errors.isEmpty, "Foreign record-fill action must reach presentation")
                expect(state.watchlist.activeBrokerageAccountID == .financing, "Modal freezes its explicit source account")
            }
            var closed = false
            _ = host(AnyView(PlanExecutionSheet(entry: entry, account: .financing, onClose: { closed = true }).environment(state)),
                width: 520, height: 560, scheme: scheme, name: "cross-account-plan-fill-\(scheme).png") { root in
                press(PulseLocalization.localizedString("plan.execution.record"), in: root)
                expect(closed, "Foreign plan's actual fill form must save and dismiss")
            }
            let fills = state.watchlist.transactionsForPlan(symbol, account: .financing, planID: plan.id)
            expect(fills.count == 1 && fills.first?.quantity == 10, "Exactly one fill must be recorded under the named source")
            expect(state.watchlist.brokeragePortfolio(for: .mengmeng).items.first?.transactions.isEmpty == true,
                   "Same-ID plan in another account must not receive the fill")
            // A menu held open across a fill must refuse its stale destructive
            // decision instead of cancelling the newly completed plan.
            do {
                try PlanActionRouting.perform(.abandon, entry: entry, in: state) { _ in }
                expect(false, "Stale plan action must refuse")
            } catch { expect(true, "Stale plan action refused") }
            var route = PopoverRoute.planList
            let binding = Binding(get: { route }, set: { route = $0 })
            _ = state.selectBrokerageAccount(.unassigned)
            _ = host(AnyView(PlanListView(route: binding, initialScope: .waiting).environment(state)),
                width: 380, height: 520, scheme: scheme, name: "cross-account-plan-list-\(scheme).png")
            _ = host(AnyView(MainPlanListView(route: binding).environment(state)),
                width: 960, height: 520, scheme: scheme, name: "cross-account-plan-table-\(scheme).png")
            state.settings.compactPlanCards = false
            _ = host(AnyView(PopoverRootView(initialRoute: .planList).environment(state)),
                width: 380, height: 610, scheme: scheme, name: "plan-root-keeps-sheet-\(scheme).png") { root in
                // Only Mengmeng's namesake is still waiting. The real root must
                // not unmount the list when its record button selects that source.
                press(PulseLocalization.localizedString("plans.action.recordFill"), in: root)
                settle(root)
                expect(state.watchlist.activeBrokerageAccountID == .mengmeng,
                    "Root plan page must route to the foreign plan's source")
                guard let sheet = root.window?.attachedSheet?.contentView else {
                    expect(false, "Account selection must keep the real root's fill sheet mounted"); return
                }
                expect(true, "Real root fill sheet remains attached")
                press(PulseLocalization.localizedString("action.cancel"), in: sheet)
                settle(root)
                expect(root.window?.attachedSheet == nil, "Root fill sheet must cancel without a write")
            }
            _ = state.selectBrokerageAccount(.financing)
            if let item = state.watchlist.item(for: symbol), let allocation = item.positionAllocation,
               let portion = allocation.portions.first {
                let before = state.watchlist.syncSnapshot()
                let marker = FundingSourceSheet(item: item, portion: portion, allocation: allocation,
                    onCancel: {}, onSuccess: { _, _ in expect(false, "Rendering cannot submit funding changes") })
                _ = host(AnyView(marker.environment(state)), width: 410, height: 360,
                    scheme: scheme, name: "extracted-funding-form-\(scheme).png")
                expect(state.watchlist.syncSnapshot() == before, "Extracted funding form must preserve ledger data while rendering")
            } else { expect(false, "Funding form requires the real recorded buy's allocation") }
        }
    }

    private static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static func press(_ title: String, in root: NSView) {
        var visited: Set<ObjectIdentifier> = []
        func tryPress(_ node: any NSAccessibilityProtocol) -> Bool {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return false }
            let label = node.accessibilityLabel() ?? node.accessibilityTitle() ?? ""
            if normalized(label) == normalized(title), node.accessibilityPerformPress() { return true }
            for child in node.accessibilityChildren() ?? [] {
                if let child = child as? any NSAccessibilityProtocol, tryPress(child) { return true }
            }
            return false
        }
        if tryPress(root) { settle(root); return }
        // Offscreen SwiftUI may omit AX elements. Target the real rendered label
        // via local OCR, then deliver events only to this fixture's own window.
        guard let match = recognizedText(root).filter({ normalized($0.text) == normalized(title) })
            .min(by: { $0.rect.minY < $1.rect.minY }),
              let window = root.window else { expect(false, "Native button not found: \(title)"); return }
        let point = NSPoint(x: match.rect.midX * root.bounds.width, y: match.rect.midY * root.bounds.height)
        let local = NSPoint(x: point.x, y: root.isFlipped ? root.bounds.height - point.y : point.y)
        let location = root.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { window.sendEvent(event) }
        }
        settle(root)
    }

    private static func recognizedText(_ view: NSView) -> [(text: String, rect: CGRect)] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        do { try VNImageRequestHandler(cgImage: image).perform([request]) }
        catch { expect(false, "Local OCR failed: \(error)"); return [] }
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }

    private static func host(_ view: AnyView, width: CGFloat, height: CGFloat, scheme: ColorScheme,
                             name: String, inspect: ((NSView) -> Void)? = nil) -> Data? {
        let root = view.environment(\.colorScheme, scheme).frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderBack(nil)
        defer { window.orderOut(nil) }
        settle(hosting); inspect?(hosting); settle(hosting)
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { expect(false, "Native render allocation failed"); return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { expect(false, "Native PNG failed"); return nil }
        if CommandLine.arguments.contains("--export-render-base64") { print("PULSE_RENDER_BASE64 \(name) \(data.base64EncodedString())") }
        return data
    }

    private static func settle(_ view: NSView) {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    private static func expect(_ value: Bool, _ message: String) {
        checks += 1; if !value { failures.append(message) }
    }
}
#endif
