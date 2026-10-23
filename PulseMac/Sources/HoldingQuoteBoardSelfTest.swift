#if DEBUG
import AppKit
import SwiftUI
import PulseCore
import PulseUI

@MainActor
enum HoldingQuoteBoardSelfTest {
    static let now = ISO8601DateFormatter().date(from: "2026-10-23T02:00:00Z")!

    static func fixtures() -> (items: [WatchItem], quotes: [SymbolID: Quote], entries: [TradePlanEntry]) {
        // Public names, invented quotes and positions only. Never read a real account for captures.
        let names: [(String, String, Market)] = [
            ("600519", "贵州茅台", .sh), ("300750", "宁德时代", .sz), ("000858", "五粮液", .sz),
            ("600036", "招商银行", .sh), ("601318", "中国平安", .sh), ("002594", "比亚迪", .sz),
            ("600900", "长江电力", .sh), ("601012", "隆基绿能", .sh), ("002475", "立讯精密", .sz),
            ("600276", "恒瑞医药", .sh), ("000333", "美的集团", .sz), ("300059", "东方财富", .sz),
            ("688981", "中芯国际", .sh), ("510300", "沪深300ETF", .sh), ("512100", "中证1000ETF", .sh)
        ]
        let prices: [Double] = [1412, 176.8, 120.2, 36.55, 52.2, 270.1, 27.3, 18.36, 42.1, 45.88, 62.78, 21.35, 98.6, 4.101, 2.356]
        let changes: [Double] = [0.25, -1.2, 1.82, -0.66, 0, 2.3, -0.36, -3.1, 1.24, -1.8, 0.43, 3.25, -2.6, 0.74, -1.1]
        var items: [WatchItem] = []
        var quotes: [SymbolID: Quote] = [:]
        var entries: [TradePlanEntry] = []
        for (index, spec) in names.enumerated() {
            let symbol = SymbolID(market: spec.2, code: spec.0)
            let plan = TradePlan(kind: .buy, price: index == 1 ? 178 : 1, quantity: 100)
            // Deliberately very different cost: daily % must never become holding return.
            let item = WatchItem(symbol: symbol, displayName: spec.1,
                                 instrumentType: index >= 13 ? .etf : .equity,
                                 lots: [.init(price: prices[index] * 1.5, quantity: 100)],
                                 plans: [1, 4, 13].contains(index) ? [plan] : [])
            items.append(item)
            if !item.plans.isEmpty { entries.append(TradePlanEntry(symbol: symbol, plan: plan)) }
            guard index != 12 else { continue } // A real-looking missing quote stays visible.
            quotes[symbol] = Quote(symbol: symbol, price: prices[index],
                                  previousClose: index == 11 ? 0 : prices[index] / (1 + changes[index] / 100),
                                  sourceName: "模拟行情", sourceDelay: index == 10 ? 900 : 0,
                                  timestamp: now.addingTimeInterval(index == 9 ? -3600 : index == 10 ? -900 : 0),
                                  marketState: index == 8 ? .closed : nil)
        }
        return (items, quotes, entries)
    }

    static func run() -> Bool {
        var failures: [String] = []
        var checks = 0
        func expect(_ value: Bool, _ message: String) { checks += 1; if !value { failures.append(message) } }
        let data = fixtures()
        func make(items: [WatchItem]? = nil, quotes: [SymbolID: Quote]? = nil, holdings: Bool = true, time: Date = now,
                  entries: [TradePlanEntry]? = nil) -> HoldingQuoteBoard {
            let input = quotes ?? data.quotes
            return HoldingQuoteBoard(items: items ?? data.items, entries: entries ?? data.entries,
                                     holdingsOnly: holdings, now: time, quote: { input[$0] })
        }
        let board = make()
        expect(board.rows.count == 15, "keep all 15 holdings including missing quote")
        expect(board.rows.map(\.symbol) == data.items.map(\.symbol), "preserve account item order")
        expect(board.rows[12].quote == nil && board.rows[12].changePercent == nil, "missing is not zero")
        expect(board.rows[11].quote != nil && board.rows[11].changePercent == nil, "no previous close keeps price but no daily change")
        expect(abs((board.rows[1].changePercent ?? 0) - -1.2) < 0.001, "daily change is independent of cost")
        expect(board.rows[4].changePercent == 0, "a real unchanged quote stays zero")
        expect(board.rows[9].referenceState == .stale, "old quote marked stale")
        expect(board.rows[8].referenceState == .reference, "closed quote reference only")
        expect(board.rows[10].referenceState == .delayed, "declared delay stays visible")
        expect(board.rows[1].planSignal == .reached(1), "fresh matched plan has marker")
        expect(board.reachedSymbolCount == 1, "count reached symbols not all active plans")
        var oldQuotes = data.quotes
        let target = data.items[1].symbol
        oldQuotes[target]?.timestamp = now.addingTimeInterval(-3600)
        expect(make(quotes: oldQuotes).rows[1].planSignal == .waiting(1), "stale quote cannot reach target")
        oldQuotes[target]?.timestamp = now.addingTimeInterval(120)
        expect(make(quotes: oldQuotes).rows[1].planSignal == .waiting(1), "future quote cannot reach target")
        oldQuotes[target]?.price = .nan
        expect(make(quotes: oldQuotes).rows[1].quote == nil, "invalid price missing")
        oldQuotes[target] = data.quotes[data.items[0].symbol]
        expect(make(quotes: oldQuotes).rows[1].quote == nil, "foreign symbol quote rejected")
        let afterClose = now.addingTimeInterval(7 * 3600)
        expect(make(time: afterClose).reachedSymbolCount == 0, "closed market cannot produce live signal")
        var liveQuotes = data.quotes
        liveQuotes[target]?.price = 200
        expect(make(quotes: liveQuotes).rows.map(\.symbol) == board.rows.map(\.symbol), "price updates never reorder")
        var noHoldings = data.items
        noHoldings[0].lots = []
        expect(make(items: noHoldings).rows.count == 14, "holdings filter excludes no position")
        expect(make(items: noHoldings, holdings: false).rows.count == 15, "watchlist shows no-position stock")
        expect(make(items: data.items + [data.items[0]]).rows.count == 15, "deduplicate without changing order")
        expect(make(items: []).rows.isEmpty, "empty account stays empty")
        let foreignPlan = TradePlanEntry(symbol: data.items[0].symbol, plan: TradePlan(kind: .buy, price: 10000, quantity: 100))
        expect(make(items: [data.items[1]], entries: [foreignPlan]).rows.first?.planSignal == HoldingQuoteBoard.PlanSignal.none,
               "unrelated symbols never acquire a plan marker")
        let settled = TradePlanEntry(symbol: target, plan: TradePlan(kind: .buy, price: 10000, quantity: 100, status: .done))
        expect(make(items: [data.items[1]], entries: [settled]).reachedSymbolCount == 0, "settled plans cannot signal")
        let invalid = TradePlanEntry(symbol: target, plan: TradePlan(kind: .buy, price: -.infinity, quantity: 100))
        expect(make(items: [data.items[1]], entries: [invalid]).rows.first?.planSignal == HoldingQuoteBoard.PlanSignal.none,
               "invalid plan omitted")
        expect(make(items: [data.items[1]], entries: []).rows.first?.planSignal == HoldingQuoteBoard.PlanSignal.none,
               "different account without plans stays unmarked")
        let suite = "pulse.holding-quotes.accounts.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = WatchlistStore(defaults: defaults)
            store.enableBrokerageAccounts()
            for account in [BrokerageAccountID.financing, .mengmeng] {
                store.withBrokerageAccount(account) {
                    store.add(SymbolInfo(symbol: target, name: "账户隔离样本", type: .equity))
                    store.addTransaction(target, .init(kind: .buy, price: 100, quantity: 100, date: now.addingTimeInterval(-86400)))
                    _ = store.setTradePlan(.init(kind: .buy, price: account == .financing ? 178 : 1,
                                                quantity: 100, executionAccountID: account), for: target)
                }
            }
            func accountBoard(_ account: BrokerageAccountID) -> HoldingQuoteBoard {
                store.withBrokerageAccount(account) {
                    HoldingQuoteBoard(items: store.allItems, entries: store.tradePlanEntries,
                                      holdingsOnly: true, now: now, quote: { data.quotes[$0] })
                }
            }
            let before = store.syncSnapshot()
            expect(accountBoard(.financing).rows.first?.planSignal == .reached(1), "finance reads its own plan")
            expect(accountBoard(.mengmeng).rows.first?.planSignal == .waiting(1), "other account keeps its own threshold")
            expect(accountBoard(.unassigned).rows.isEmpty, "empty account cannot inherit another holding")
            expect(store.syncSnapshot() == before && store.activeBrokerageAccountID == .unassigned,
                   "reading quotes preserves account selection and ledger")
        } else { failures.append("isolated account defaults unavailable") }
        do {
            try render(board)
        } catch { failures.append("render: \(error.localizedDescription)") }
        print("PULSE_HOLDING_QUOTES_SELFTEST \(failures.isEmpty ? "ok" : "failed") checks=\(checks) failures=\(failures.joined(separator: "; "))")
        return failures.isEmpty
    }

    private static func render(_ board: HoldingQuoteBoard) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holding-quotes-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, width, height, scheme) in [
            ("quotes-15-light", 920.0, 640.0, ColorScheme.light),
            ("quotes-15-dark", 920.0, 640.0, ColorScheme.dark),
            ("quotes-narrow-dark", 390.0, 640.0, ColorScheme.dark)
        ] {
            let root = VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("持仓行情").font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Text("15只 · 模拟账户").font(.caption).foregroundStyle(.secondary)
                }
                HoldingQuoteBoardView(board: board)
                Spacer(minLength: 0)
                Text("合成数据 · 非实时行情").font(.caption2).foregroundStyle(.tertiary)
            }.padding(20)
            try capture(root, name: name, directory: directory, width: width, height: height, scheme: scheme)
        }
        // Render the actual production page in an isolated account; no live APIs.
        let data = fixtures()
        let state = AppState()
        for item in data.items {
            state.watchlist.add(SymbolInfo(symbol: item.symbol, name: item.displayName, type: item.instrumentType ?? .equity))
            state.watchlist.addTransaction(item.symbol, PositionTransaction(kind: .buy, price: 100, quantity: 100,
                                                                           date: now.addingTimeInterval(-86400)))
            for plan in item.plans { _ = state.watchlist.setTradePlan(plan, for: item.symbol) }
        }
        state.market.apply(quotes: Array(data.quotes.values))
        let beforeRender = state.watchlist.syncSnapshot()
        for scheme in [ColorScheme.light, .dark] {
            let workbench = TradingWorkbenchView(onSelect: { _ in }, onShowPlans: {}, onShowJournal: {},
                onShowEvents: {}, initial: .init(scope: .chinaA, presentation: .quotes, now: now)).environment(state)
            try capture(workbench, name: "workbench-quotes-\(scheme == .dark ? "dark" : "light")",
                        directory: directory, width: 920, height: 720, scheme: scheme)
        }
        let tasks = TradingWorkbenchView(onSelect: { _ in }, onShowPlans: {}, onShowJournal: {},
            onShowEvents: {}, initial: .init(scope: .chinaA, presentation: .tasks, now: now)).environment(state)
        try capture(tasks, name: "workbench-tasks-light", directory: directory, width: 920, height: 720, scheme: .light)
        guard state.watchlist.syncSnapshot() == beforeRender else {
            throw NSError(domain: "HoldingQuoteBoardSelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "render changed the account or plans"])
        }
        print("PULSE_HOLDING_QUOTES_READONLY ok")
    }

    private static func capture<V: View>(_ view: V, name: String, directory: URL,
                                          width: CGFloat, height: CGFloat, scheme: ColorScheme) throws {
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let host = NSHostingView(rootView: view.frame(width: width, height: height)
            .environment(\.colorScheme, scheme).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = rect
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let path = directory.appendingPathComponent(name + ".png")
        try png.write(to: path)
        print("PULSE_HOLDING_QUOTES_RENDER \(path.path)")
    }
}
#endif
