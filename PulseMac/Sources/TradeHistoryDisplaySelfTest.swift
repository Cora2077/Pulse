#if DEBUG
import AppKit
import SwiftUI
import PulseCore

/// Native render acceptance with disposable, offline cross-account fills.
@MainActor
enum TradeHistoryDisplaySelfTest {
    static func run() -> Bool {
        guard CommandLine.arguments.contains("--main-window-demo"),
              CommandLine.arguments.contains("--trade-history-demo") else { return false }
        let state = AppState()
        let symbol = MainWindowDemo.infos[0].symbol
        let store = state.watchlist
        let initialIDs = store.tradeHistory(for: symbol).map(\.id)
        guard initialIDs.count == 2,
              store.tradeHistory(for: symbol).contains(where: {
                  $0.accountID == .financing && $0.transaction.price == 214
              }) else { return false }
        do {
            var sourceSell = try require(store.item(for: symbol)?.plans.first { $0.kind == .sell })
            sourceSell.price = 226
            guard store.setTradePlan(sourceSell, for: symbol) else { return false }
            let added = try store.withBrokerageAccount(.financing) {
                store.setTradePlan(TradePlan(id: sourceSell.id, kind: .sell, price: 225, quantity: 3), for: symbol)
            }
            guard added else { return false }
            for owner in BrokerageAccountID.allCases {
                _ = state.selectBrokerageAccount(owner)
                let baseline = store.syncSnapshot()
                guard store.tradeHistory(for: symbol).map(\.id) == initialIDs,
                      BrokerageBoardReader.displayPlans(store: store, symbol: symbol)
                        .contains(where: { $0.displayState == .filled && $0.averageFillPrice == 214 }) else {
                    return false
                }
                let plans = BrokerageBoardReader.displayPlans(store: store, symbol: symbol)
                let waiting = plans.filter { $0.displayState == .waiting }
                guard waiting.count == 2, Set(waiting.map { $0.chartPlan.id }).count == 2,
                      Set(waiting.map { $0.chartPlan.price }) == [225, 226],
                      waiting.allSatisfy({ $0.chartPlan.quantity == $0.remainingQuantity }),
                      plans.first(where: { $0.displayState == .filled })?.chartPlan.status == .done else {
                    return false
                }
                try render(MainInstrumentView(symbol: symbol, initialShowsPlans: true, initialPeriod: .day)
                    .environment(state), width: 1100, height: 760, name: "plans-\(owner.rawValue)")
                try render(MainInstrumentView(symbol: symbol, initialShowsTransactions: true, initialPeriod: .day)
                    .environment(state), width: 1100, height: 760, name: "main-\(owner.rawValue)")
                try render(DetailView(symbol: symbol, route: .constant(.detail(symbol)), initialPeriod: .day)
                    .environment(state), width: 340, height: 680, name: "detail-\(owner.rawValue)")
                try render(TransactionListView(symbol: symbol, returnRoute: .detail(symbol),
                    route: .constant(.transactions(symbol, .detail(symbol)))).environment(state),
                    width: 340, height: 260, name: "transactions-\(owner.rawValue)")
                try render(PositionHubView(symbol: symbol, returnRoute: .detail(symbol),
                    route: .constant(.position(symbol, .detail(symbol)))).environment(state),
                    width: 340, height: 480, name: "position-\(owner.rawValue)")
                guard store.syncSnapshot() == baseline, store.activeBrokerageAccountID == owner else {
                    return false
                }
            }
            _ = state.selectBrokerageAccount(.unassigned)
            try render(MainInstrumentView(symbol: symbol, initialShowsPlans: true, initialPeriod: .day)
                .environment(state), width: 1100, height: 760, name: "plans-dark", scheme: .dark)
            try render(BrokerageAccountClassificationSheet(onAssigned: { _ in }, initialDestination: .financing).environment(state),
                       width: 520, height: 460, name: "classification-light")
            try render(BrokerageAccountClassificationSheet(onAssigned: { _ in }, initialDestination: .financing).environment(state),
                       width: 520, height: 460, name: "classification-dark", scheme: .dark)
            try render(TradeJournalView(onSelect: { _ in }).environment(state),
                       width: 1100, height: 760, name: "journal")
            print("PULSE_TRADE_HISTORY_SELFTEST passed accounts=3 trades=2 waiting-plans=2 source-identities=2 renders=19")
            return true
        } catch {
            print("PULSE_TRADE_HISTORY_SELFTEST failed: \(error)")
            return false
        }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, scheme: ColorScheme = .light) throws {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height).environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if CommandLine.arguments.contains("--export-render-base64") {
            print("PULSE_RENDER_BASE64 \(name).png \(data.base64EncodedString())")
            return
        }
        let directory = URL(fileURLWithPath: "build/artifacts/trade-history", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
#endif
