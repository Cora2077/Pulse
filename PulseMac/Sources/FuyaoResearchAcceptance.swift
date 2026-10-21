#if DEBUG
import Foundation
import SwiftUI
import PulseCore

@MainActor
enum FuyaoResearchAcceptance {
    static func contextChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ text: String) { if !condition { failures.append(text) } }
        let suite = "app.pulse.research-context-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FuyaoContextStore(defaults: defaults)
        let symbol = SymbolID(market: .sh, code: "600519")
        let started = Date.now.addingTimeInterval(-120)
        let created = started.addingTimeInterval(10)
        let observed = started.addingTimeInterval(20)
        let old = TradePlan(kind: .buy, price: 10, quantity: 1, createdAt: started.addingTimeInterval(-60))
        var item = WatchItem(symbol: symbol, displayName: "合成股票", plans: [old])
        var snapshot = WatchlistSyncSnapshot(items: [item], groups: [])
        store.initialize(snapshot: snapshot, enabled: true, now: started)
        func capture(_ key: FuyaoContextKey, _ time: Date) -> FuyaoMarketContext { .init(key: key, capturedAt: time) }
        store.observe(snapshot, now: observed, capture: capture)
        expect(store.records.isEmpty, "context must not backfill old plans")
        let new = TradePlan(kind: .buy, price: 11, quantity: 2, createdAt: created)
        item.plans.append(new); snapshot.items = [item]
        store.observe(snapshot, now: observed, capture: capture)
        expect(store.records.count == 1, "new plan must capture once")
        let key = FuyaoContextKey(account: .unassigned, symbol: symbol, kind: .plan, recordID: new.id)
        expect(store.context(for: key)?.capturedAt == observed, "context is keyed by record")
        item.plans[1].price = 99; snapshot.items = [item]
        store.observe(snapshot, now: observed.addingTimeInterval(10), capture: capture)
        expect(store.records.count == 1 && store.context(for: key)?.capturedAt == observed, "edits must not rewrite capture")
        let restored = FuyaoContextStore(defaults: defaults)
        expect(restored.records == store.records, "local context persists across restart")
        let named = BrokerageAccountID.allCases.first { $0 != .unassigned }!
        snapshot.brokerageAccounts = [.init(accountID: named, items: [item])]
        store.observe(snapshot, now: observed.addingTimeInterval(10), capture: capture)
        expect(store.records.contains { $0.key.account == named }, "same UUID in different accounts must stay distinct")
        let fill = PositionTransaction(kind: .buy, price: 1, quantity: 1, date: observed.addingTimeInterval(-86_400), createdAt: created)
        item.transactions = [fill]; snapshot.items = [item]
        store.observe(snapshot, now: observed, capture: capture)
        expect(store.records.allSatisfy { $0.key.kind != .fill }, "backdated fills must not use current market context")
        store.availabilityChanged(snapshot: snapshot, enabled: false, now: observed)
        item.plans.append(.init(kind: .sell, price: 20, quantity: 1, createdAt: observed.addingTimeInterval(5)))
        snapshot.items = [item]
        let count = store.records.count
        store.observe(snapshot, now: observed.addingTimeInterval(10), capture: capture)
        expect(store.records.count == count, "disabled source must not capture")
        store.availabilityChanged(snapshot: snapshot, enabled: true, now: observed.addingTimeInterval(15))
        store.observe(snapshot, now: observed.addingTimeInterval(20), capture: capture)
        expect(store.records.count == count, "re-enable must not fill disabled interval")
        // Real persistence observer must leave sync callbacks independent.
        let ledger = WatchlistStore(defaults: defaults)
        var local = 0, sync = 0
        ledger.onLocalLedgerChange = { _ in local += 1 }
        ledger.onLocalSyncChange = { _ in sync += 1 }
        ledger.add(SymbolInfo(symbol: symbol, name: "合成股票", type: .equity))
        expect(local == 1 && sync == 1, "local ledger observer must coexist with sync")
        return failures
    }

    static func renderAdditional() throws {
        let now = Date(timeIntervalSince1970: 1_792_454_400)
        let board = FuyaoBoard(thscode: "886042.TI", name: "合成板块")
        let stock = SymbolID(market: .sh, code: "600519")
        let fund = SymbolID(market: .sh, code: "510300")
        var detail = FuyaoBoardsController.Detail()
        detail.constituents = .init(value: [.init(thscode: "600519.SH", name: "合成股票 A"), .init(thscode: "000001.SZ", name: "合成股票 B")], dataTime: now, fetchedAt: now)
        detail.quotes[stock] = Quote(symbol: stock, price: 11, previousClose: 10, timestamp: now)
        detail.strength = .init(dataTime: now, fiveDay: 2.56, twentyDay: -1.23, boardFiveDay: 5.12, boardTwentyDay: 8.76)
        try FuyaoResearchSelfTest.render(FuyaoBoardDetailContent(board: board, detail: detail, loading: false, watchSymbols: [stock]), name: "boards-light", width: 800, height: 600, scheme: .light)
        let report = FuyaoFundHoldings(fund: fund, report: .init(reportType: "quarter", reportTypeName: "季报", endDate: Date(timeIntervalSince1970: 1_782_748_800)),
            holdings: [.init(thscode: "600519.SH", name: "合成股票 A", weightPercent: 20), .init(thscode: "000001.SZ", name: "合成股票 B", weightPercent: 10)], fetchedAt: now)
        let allocation = PortfolioAllocation.calculate(positions: [.init(symbol: fund, name: "合成 ETF", quantity: 100, price: 1, currencyCode: "CNY"), .init(symbol: stock, name: "合成股票 A", quantity: 50, price: 1, currencyCode: "CNY")])
        if let result = FuyaoLookThrough.calculate(allocation: allocation, types: [fund: .etf, stock: .equity], reports: [fund: report]).first {
            try FuyaoResearchSelfTest.render(FuyaoLookThroughContent(currency: result), name: "lookthrough-dark", width: 850, height: 600, scheme: .dark)
        }
        let stats = FuyaoMarketStatistics(tradeDate: now, dataTime: now, limitUp: 52, opened: 29, touched: 81, sealRate: 0.642,
            tiers: [.init(boardNumber: 4, count: 1), .init(boardNumber: 3, count: 5), .init(boardNumber: 2, count: 8)])
        var sentiment = FuyaoSentimentController.State()
        sentiment.statistics = .init(value: stats, dataTime: now, fetchedAt: now)
        try FuyaoResearchSelfTest.render(FuyaoSentimentSummary(state: sentiment), name: "sentiment-light", width: 850, height: 260, scheme: .light)
        var financials = FuyaoFinancialsController.State()
        financials.valuation = .init(value: .init(thscode: "600519.SH", peTTM: 20.1, peMRQ: 19, pbMRQ: 3, psTTM: nil, pcfTTM: 12), dataTime: now, fetchedAt: now)
        financials.statements[.income] = .init(value: [.init(fiscalYear: 2026, fiscalPeriod: "Q2", periodEnd: report.report.endDate, disclosedAt: now, currency: "CNY", values: ["revenue": 1_200_000_000, "parentProfit": 150_000_000])], dataTime: report.report.endDate, fetchedAt: now)
        try FuyaoResearchSelfTest.render(FuyaoFinancialsContent(state: financials), name: "financials-light", width: 850, height: 500, scheme: .light)
        let key = FuyaoContextKey(account: .unassigned, symbol: stock, kind: .plan, recordID: UUID())
        let context = FuyaoMarketContext(key: key, capturedAt: now, statistics: .init(value: stats, dataTime: now, fetchedAt: now), boards: [.init(name: board.name, thscode: board.thscode, strength: detail.strength!)])
        try FuyaoResearchSelfTest.render(FuyaoCapturedContextContent(context: context), name: "context-dark", width: 850, height: 400, scheme: .dark)
    }

    static func runLive() async -> Bool {
        // An explicit headless acceptance may receive the already supplied key
        // through an anonymous pipe. Never use argv, files, logs or Keychain UI.
        let supplied: String?
        if CommandLine.arguments.contains("--research-stdin-key") {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            supplied = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { supplied = nil }
        if CommandLine.arguments.contains("--main-window-demo"),
           CommandLine.arguments.contains("--research-provision-stdin-key"), let supplied, !supplied.isEmpty {
            do { try ProviderCredentialStore.save(["apiKey": supplied], providerID: FuyaoProvider.providerID) }
            catch { print("PULSE_RESEARCH_KEYCHAIN save failed"); return false }
            guard ProviderCredentialStore.load(providerID: FuyaoProvider.providerID)?["apiKey"] == supplied else {
                print("PULSE_RESEARCH_KEYCHAIN readback failed"); return false
            }
            print("PULSE_RESEARCH_KEYCHAIN saved and verified without UI")
            return true
        }
        guard CommandLine.arguments.contains("--main-window-demo"),
              let key = supplied ?? ProviderCredentialStore.load(providerID: FuyaoProvider.providerID)?["apiKey"], !key.isEmpty else {
            print("PULSE_RESEARCH_LIVE unavailable: saved credential not accessible; no interactive retry")
            return false
        }
        let provider = FuyaoProvider(apiKey: key)
        if CommandLine.arguments.contains("--research-keychain-only") {
            print("PULSE_RESEARCH_KEYCHAIN ok")
            return true
        }
        if CommandLine.arguments.contains("--research-daily-contract") {
            return await DailyChartAcceptance.run(provider: provider)
        }
        if CommandLine.arguments.contains("--research-fund-contract") {
            do { print(try await provider.debugFundContract(for: SymbolID(market: .sh, code: "510300"))); return true }
            catch { print("PULSE_FUND_CONTRACT failed \(FuyaoResearchController.message(error))"); return false }
        }
        let stock = SymbolID(market: .sh, code: "600519")
        var failures: [String] = []
        func check(_ name: String, _ operation: () async throws -> String) async {
            do { print("PULSE_RESEARCH_LIVE \(name) ok \(try await operation())") }
            catch { failures.append(name); print("PULSE_RESEARCH_LIVE \(name) failed \(FuyaoResearchController.message(error))") }
            fflush(stdout)
        }
        await check("news") { "rows=\(try await provider.stockNews(for: stock).value.count)" }
        await check("anomalies") { "rows=\(try await provider.anomalies(for: stock).value.count)" }
        await check("heat") { "rows=\(try await provider.hotStocks().value.count)" }
        await check("rank") { "rows=\(try await provider.rankTrend(for: stock, start: .now.addingTimeInterval(-14 * 86_400), end: .now).value.count)" }
        var board: FuyaoBoard?
        await check("boards") { let result = try await provider.boardCatalog(industry: true); board = result.value.first; return "rows=\(result.value.count)" }
        if let board {
            await check("constituents") { "rows=\(try await provider.boardConstituents(thscode: board.thscode).value.count)" }
            if let symbol = board.symbol { await check("board-history") { "rows=\(try await provider.candles(for: symbol, period: .day, count: 45).count)" } }
        }
        await check("fund-holdings") {
            let report = try await provider.latestFundHoldings(for: SymbolID(market: .sh, code: "510300"))
            guard !report.holdings.isEmpty else { throw ProviderError.badResponse("empty fund holdings") }
            return "rows=\(report.holdings.count) period=\(ResearchFormat.day(report.report.endDate)) covered=\(report.disclosedWeightPercent.map { String(format: "%.2f", $0) } ?? "unknown")"
        }
        var tradeDate: Date?
        await check("statistics") { let result = try await provider.marketStatistics(); tradeDate = result.value.tradeDate; return "date=\(ResearchFormat.day(result.value.tradeDate))" }
        if let tradeDate { for kind in FuyaoLimitKind.allCases { await check(kind.rawValue) { "rows=\(try await provider.limitPool(kind, tradeDate: tradeDate).value.stocks.count)" } } }
        for kind in FuyaoStatementKind.allCases { await check(kind.rawValue) { "rows=\(try await provider.financialStatement(kind, for: stock).value.count)" } }
        await check("valuation") {
            let result = try await provider.valuation(for: stock)
            guard result.value != nil else { throw ProviderError.badResponse("empty valuation") }
            return "metrics=5"
        }
        print("PULSE_RESEARCH_LIVE \(failures.isEmpty ? "ok" : "failed") failures=\(failures.joined(separator: ","))")
        return failures.isEmpty
    }
}
#endif
