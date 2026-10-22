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

    /// 除权小节与计划提示的原生渲染（合成数据，不联网）。宽窄两种都过一遍，
    /// 因为计划提示在窄卡片里只保留一行，布局不能溢出。
    static func renderCorporateActions() throws {
        let symbol = SymbolID(market: .sh, code: "600519")
        let action = FuyaoCorporateAction(
            thscode: "600519.SH",
            exDate: Date(timeIntervalSince1970: 1_766_073_600),
            cashPerShare: 23.957,
            bonusPerShare: 0.1
        )
        let plan = TradePlan(kind: .buy, price: 1200, quantity: 100, status: .active,
                             createdAt: Date(timeIntervalSince1970: 1_766_000_000))
        let notice = FuyaoPlanPriceBasisNotice(planID: plan.id, symbol: symbol, action: action)
        @ViewBuilder func content() -> some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("除权除息").font(.system(size: 12, weight: .medium))
                FuyaoCorporateActionRow(action: action)
                FuyaoCorporateActionRow(action: FuyaoCorporateAction(
                    thscode: "600519.SH",
                    exDate: Date(timeIntervalSince1970: 1_437_062_400),
                    cashPerShare: 4.374,
                    bonusPerShare: 0
                ))
                Divider()
                FuyaoPlanPriceBasisNoticeView(notice: notice)
                FuyaoPlanPriceBasisNoticeView(notice: notice, compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        try FuyaoResearchSelfTest.render(content(), name: "corporate-actions-light", width: 460, height: 300, scheme: .light)
        try FuyaoResearchSelfTest.render(content(), name: "corporate-actions-narrow-dark", width: 320, height: 340, scheme: .dark)
    }

    /// 龙虎榜与监控的原生渲染。用真实组件与合成数据，覆盖区间分段与缺代码行。
    static func renderCapitalFlow() throws {
        let day = FuyaoDragonTigerDay(
            boardType: .all,
            tradeDate: Date(timeIntervalSince1970: 1_792_368_000),
            dataTime: Date(timeIntervalSince1970: 1_792_478_400),
            stockRows: [
                .init(thscode: "600519.SH", ticker: "600519", name: "合成股票甲", rangeDays: 1,
                      changeFraction: 0.0999, netValue: 178_625_312.23, netRate: 0.119,
                      orgNetValue: 25_593_703.75, orgBuyCount: 4, orgSellCount: 5,
                      limitReason: "合成题材 A"),
                .init(thscode: "000001.SZ", ticker: "000001", name: "合成股票乙", rangeDays: 1,
                      changeFraction: -0.0312, netValue: -45_246_913.56, netRate: -0.0113,
                      orgNetValue: -5_518_444.4),
                .init(thscode: "600519.SH", ticker: "600519", name: "合成股票甲", rangeDays: 3,
                      changeFraction: 0.0512, netValue: -88_000_000),
                .init(thscode: nil, ticker: "301139", name: "合成退市", rangeDays: 1,
                      changeFraction: 0.026, netValue: 559_311.15)
            ],
            hotMoneyRows: [.init(name: "合成游资", buying: 1_200_000, rows: [
                .init(thscode: "600519.SH", ticker: "600519", name: "合成股票甲", rangeDays: 1, netValue: 800_000)
            ])],
            recordCount: 4, stockCount: 3, fetchedAt: .now
        )
        try FuyaoResearchSelfTest.render(
            FuyaoCapitalFlowContent(day: day, loading: false, watchSymbols: [SymbolID(market: .sh, code: "600519")]),
            name: "capital-flow-light", width: 800, height: 460, scheme: .light)
        try FuyaoResearchSelfTest.render(
            FuyaoCapitalFlowContent(day: day, loading: false, watchSymbols: [SymbolID(market: .sh, code: "600519")]),
            name: "capital-flow-dark", width: 800, height: 460, scheme: .dark)

        // 工作台首屏：两张研究卡并排的真实排版。情绪卡用合成统计，
        // 资金卡用同一份合成榜单——这是"并排会不会留一大块空白"的唯一证据。
        var sentiment = FuyaoSentimentController.State()
        sentiment.statistics = .init(value: FuyaoMarketStatistics(
            tradeDate: day.tradeDate, dataTime: day.dataTime, limitUp: 52, opened: 29, touched: 81,
            sealRate: 0.642, tiers: [.init(boardNumber: 3, count: 5), .init(boardNumber: 2, count: 8)]),
            dataTime: day.dataTime, fetchedAt: .now)
        var flowState = FuyaoDragonTigerController.State()
        flowState.day = day
        flowState.fetchedAt = day.fetchedAt
        let top = day.topInstitutionalNet(count: 5, range: .day)
        @ViewBuilder func cards() -> some View {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    FuyaoSentimentSummary(state: sentiment)
                        .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    FuyaoCapitalFlowSummary(state: flowState, topInstitutional: top,
                                            watchHitCount: 1, monitored: [], loading: false)
                        .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 14) {
                    FuyaoSentimentSummary(state: sentiment)
                        .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    FuyaoCapitalFlowSummary(state: flowState, topInstitutional: top,
                                            watchHitCount: 1, monitored: [], loading: false)
                        .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        try FuyaoResearchSelfTest.render(cards(), name: "workbench-cards-light", width: 900, height: 260, scheme: .light)
        try FuyaoResearchSelfTest.render(cards(), name: "workbench-cards-narrow", width: 420, height: 420, scheme: .light)
    }

    /// 关键财务指标小节：单位混排（% / 倍 / 次）、跨期变化、以及上游有而
    /// 目录未定义的 id 必须隐藏。用真实返回的 id 构造，避免渲染图里出现
    /// 应用不会显示的形状。
    static func renderIndicators() throws {
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        func set(_ report: String, _ values: [(String, Double?)]) -> FuyaoIndicatorSet {
            var groups: [FuyaoIndicatorAbility: [FuyaoIndicatorValue]] = [:]
            for (id, value) in values {
                let ability: FuyaoIndicatorAbility = switch id {
                case _ where id.contains("growth"): .growth
                case "index_weighted_avg_roe", "index_deduct_weighted_avg_roe",
                     "sale_gross_margin", "sale_net_interest_ratio", "total_assets_net_ratio": .profitability
                case "assets_debt_ratio", "current_ratio", "quick_ratio", "cash_ratio",
                     "earned_interest_multiple": .solvency
                case _ where id.contains("turnover") || id.contains("debt_equity"): .operation
                default: .cashFlow
                }
                groups[ability, default: []].append(
                    .init(indexID: id, rawValue: value.map { String($0) }, value: value))
            }
            return FuyaoIndicatorSet(
                thscode: "600519.SH", report: report,
                groups: FuyaoIndicatorAbility.allCases.compactMap { ability in
                    groups[ability].map { FuyaoIndicatorGroup(ability: ability, values: $0) }
                },
                fetchedAt: now)
        }
        let latest = set("2026-2", [
            ("calculate_operating_income_yoy_growth_ratio", 1.469869),
            ("calculate_parent_holder_net_profit_yoy_growth_ratio", -1.951595),
            ("index_weighted_avg_roe", 16.75),
            ("sale_gross_margin", 89.5552),
            ("sale_net_interest_ratio", 50.7516),
            ("assets_debt_ratio", 15.1931),
            ("current_ratio", 5.5895),
            ("cash_ratio", 114.73623),
            ("earned_interest_multiple", nil),
            ("total_assets_turnover_ratio", 0.296),
            ("net_profit_cash_content", 158.795382),
            ("fixed_asset_invest_expansion_ratio", 2.125873)
        ])
        let previous = set("2025-2", [
            ("calculate_operating_income_yoy_growth_ratio", 12.8),
            ("index_weighted_avg_roe", 18.4),
            ("sale_gross_margin", 91.2),
            ("assets_debt_ratio", 14.1),
            ("current_ratio", 4.82),
            ("cash_ratio", 98.4),
            ("total_assets_turnover_ratio", 0.34)
        ])
        try FuyaoResearchSelfTest.render(
            FuyaoIndicatorSection(indicators: [latest, previous]),
            name: "indicators-light", width: 460, height: 620, scheme: .light)
        try FuyaoResearchSelfTest.render(
            FuyaoIndicatorSection(indicators: [latest, previous]),
            name: "indicators-narrow-dark", width: 320, height: 700, scheme: .dark)
    }

    /// 基金业绩小节：单位混排、回撤负号、排名缺失、部分端点失败。
    static func renderFundPerformance() throws {
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        func period(_ window: FuyaoPerformanceWindow, ret: Double?, peer: Double?,
                    rank: Int?, total: Int?, dd: Double?) -> FuyaoPerformancePeriod {
            .init(window: window, returnPercent: ret, peerAveragePercent: peer,
                  rank: rank, rankTotal: total, drawdownPercent: dd)
        }
        let performance = FuyaoFundPerformance(
            thscode: "510300.SH",
            periods: [
                period(.week, ret: -1.12, peer: -1.05, rank: 320, total: 480, dd: -1.2),
                period(.month, ret: -3.33, peer: -2.1, rank: 300, total: 480, dd: -3.6),
                period(.tmonth, ret: 0.03, peer: nil, rank: nil, total: nil, dd: -6.8),
                period(.year, ret: 19.66, peer: 12.4, rank: 12, total: 480, dd: -12.5),
                period(.tyear, ret: 28.69, peer: nil, rank: nil, total: nil, dd: -21.7),
                period(.nowyear, ret: nil, peer: nil, rank: nil, total: nil, dd: -7.3)
            ],
            navs: [],
            fetchedAt: now,
            // 内部一致的部分失败：只有净值端点失败，所以净值行缺失、其余照常。
            errors: ["净值": "请求受限"]
        )
        var state = FuyaoFundPerformanceController.State()
        state.performance = performance
        try FuyaoResearchSelfTest.render(
            FuyaoFundPerformanceContent(state: state),
            name: "fund-performance-light", width: 460, height: 430, scheme: .light)
        try FuyaoResearchSelfTest.render(
            FuyaoFundPerformanceContent(state: state),
            name: "fund-performance-narrow-dark", width: 330, height: 470, scheme: .dark)
    }

    /// 交易日历校准卡：已校准 / 未校准 / 有差异 / 过期四种状态。
    static func renderTradingDays() throws {
        func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay { .init(year: y, month: m, day: d) }
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        // 一天的小样本即可验证四种状态的排版：一致、有差异、未校准、过期。
        let agreeing = VerifiedTradingDays(
            coverage: day(2026, 10, 14)...day(2026, 10, 14),
            days: [day(2026, 10, 14)], fetchedAt: now)
        let differing = VerifiedTradingDays(
            coverage: day(2026, 10, 13)...day(2026, 10, 17),
            days: [day(2026, 10, 14), day(2026, 10, 15), day(2026, 10, 17)],
            fetchedAt: now)
        @ViewBuilder func cards() -> some View {
            VStack(alignment: .leading, spacing: 12) {
                TradingDayCalibrationCard(calibration: .notCalibrated)
                TradingDayCalibrationCard(calibration: .calibrated(agreeing),
                                          discrepancy: agreeing.discrepancies(with: .sh))
                TradingDayCalibrationCard(calibration: .calibrated(differing),
                                          discrepancy: differing.discrepancies(with: .sh))
                TradingDayCalibrationCard(calibration: .stale(differing, error: "请求受限"),
                                          discrepancy: differing.discrepancies(with: .sh))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        try FuyaoResearchSelfTest.render(cards(), name: "trading-days-light", width: 420, height: 430, scheme: .light)
        try FuyaoResearchSelfTest.render(cards(), name: "trading-days-dark", width: 420, height: 430, scheme: .dark)
    }

    /// 打新日历：两码分离、待定值、京市无身份、部分失败。
    static func renderIPO() throws {
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        func entry(_ ticker: String, _ name: String, market: FuyaoIPOMarket, stage: FuyaoIPOStage,
                   sub: String?, subDate: Date?, listDate: Date?, price: Double?) -> FuyaoIPOEntry {
            let suffix = market == .bj ? ".BJ" : ".SZ"
            return FuyaoIPOEntry(thscode: ticker + suffix, ticker: ticker, name: name,
                                 subscriptionCode: sub, subscriptionDate: subDate,
                                 listingDate: listDate, issuePrice: price,
                                 market: market, stage: stage)
        }
        let calendar = FuyaoIPOCalendar(lists: [
            FuyaoIPOList(market: .shSz, stage: .subscribable, entries: [
                entry("301999", "合成科技", market: .shSz, stage: .subscribable,
                      sub: "301999", subDate: now, listDate: nil, price: 20.3),
                entry("688999", "合成半导体", market: .shSz, stage: .subscribable,
                      sub: "787999", subDate: now.addingTimeInterval(86_400), listDate: nil, price: nil)
            ], fetchedAt: now),
            FuyaoIPOList(market: .bj, stage: .subscribable, entries: [
                entry("920285", "合成北交", market: .bj, stage: .subscribable,
                      sub: "920285", subDate: now, listDate: nil, price: 12.5)
            ], fetchedAt: now),
            FuyaoIPOList(market: .shSz, stage: .awaitingListing, entries: [
                entry("301998", "合成待上市", market: .shSz, stage: .awaitingListing,
                      sub: "301998", subDate: now.addingTimeInterval(-3 * 86_400),
                      listDate: now.addingTimeInterval(2 * 86_400), price: 9.8)
            ], fetchedAt: now),
            FuyaoIPOList(market: .bj, stage: .upcoming, entries: [], fetchedAt: now, error: "请求受限")
        ], fetchedAt: now)
        try FuyaoResearchSelfTest.render(
            FuyaoIPOListContent(calendar: calendar),
            name: "ipo-light", width: 460, height: 300, scheme: .light)
        try FuyaoResearchSelfTest.render(
            FuyaoIPOListContent(calendar: calendar),
            name: "ipo-narrow-dark", width: 330, height: 360, scheme: .dark)
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
        // 限流与真实失败必须分开统计：这一轮会把 20 多个真实请求挤在一起，
        // 触发动态限流是预期内的，把它计成"契约失败"会让结论不可信。
        var throttled: [String] = []
        func check(_ name: String, _ operation: () async throws -> String) async {
            do {
                print("PULSE_RESEARCH_LIVE \(name) ok \(try await operation())")
            } catch {
                if case ProviderError.rateLimited = error {
                    throttled.append(name)
                    print("PULSE_RESEARCH_LIVE \(name) throttled")
                } else {
                    failures.append(name)
                    print("PULSE_RESEARCH_LIVE \(name) failed \(FuyaoResearchController.message(error))")
                }
            }
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
        await check("ipo-calendar") {
            let calendar = try await provider.ipoCalendar()
            let byStage = FuyaoIPOStage.allCases.map { "\($0.rawValue)=\(calendar.entries(stage: $0).count)" }
            return "\(byStage.joined(separator: " ")) errors=\(calendar.errors.count)"
        }
        await check("trading-days") {
            let days = try await provider.verifiedTradingDays()
            guard days.days.count > 200 else {
                throw ProviderError.badResponse("implausibly few trading days: \(days.days.count)")
            }
            let difference = days.discrepancies(with: .sh)
            let upper = days.coverage.upperBound
            return "days=\(days.days.count) range=\(days.coverage.lowerBound.year)-\(upper.year) localOnly=\(difference.localOnly.count) upstreamOnly=\(difference.upstreamOnly.count)"
        }
        await check("fund-performance") {
            let set = try await provider.fundPerformance(for: SymbolID(market: .sh, code: "510300"))
            let withReturn = set.periods.filter { $0.returnPercent != nil }.count
            let withDrawdown = set.periods.filter { $0.drawdownPercent != nil }.count
            guard set.hasData else { throw ProviderError.badResponse("no fund performance data") }
            return "periods=\(set.periods.count) returns=\(withReturn) drawdowns=\(withDrawdown) nav=\(set.mostRecentNav != nil) errors=\(set.errors.keys.sorted())"
        }
        await check("financial-indicators") {
            let set = try await provider.financialIndicators(for: stock, report: "2026-2")
            let shown = set.nonEmptyGroups.reduce(0) { $0 + $1.displayable.count }
            let hidden = set.groups.reduce(0) { $0 + $1.values.count } - shown
            guard !set.groups.isEmpty else { throw ProviderError.badResponse("no indicator groups") }
            return "report=\(set.report) groups=\(set.groups.count) shown=\(shown) hidden=\(hidden)"
        }
        await check("dragon-tiger") {
            let day = try await provider.dragonTiger(board: .all)
            return "records=\(day.recordCount ?? -1) stocks=\(day.stockCount ?? -1) rows=\(day.stockRows.count) date=\(ResearchFormat.day(day.tradeDate)) ranges=\(day.rowsByRange.keys.map(\.rawValue).sorted())"
        }
        await check("dragon-tiger-hot-money") {
            let day = try await provider.dragonTiger(board: .hotMoney)
            return "hot_money_names=\(day.hotMoneyRows.count) stock_rows=\(day.stockRows.count)"
        }
        await check("abnormal-monitors") {
            let page = try await provider.abnormalMonitors()
            return "records=\(page.records.count) ongoing=\(page.ongoing.count)"
        }
        await check("corporate-actions") {
            let series = try await provider.corporateActions(for: stock)
            // 茅台常年分红，返回空列表通常意味着口径或端点有问题，而不是"真的没分红"。
            guard !series.actions.isEmpty else { throw ProviderError.badResponse("no corporate actions returned") }
            let latest = series.actions[0]
            guard latest.isMeaningful else { throw ProviderError.badResponse("meaningless action") }
            return "rows=\(series.actions.count) latest=\(ResearchFormat.day(latest.exDate)) cash=\(latest.cashPerShare ?? 0) bonus=\(latest.bonusPerShare ?? 0)"
        }
        await check("valuation") {
            let result = try await provider.valuation(for: stock)
            guard result.value != nil else { throw ProviderError.badResponse("empty valuation") }
            return "metrics=5"
        }
        print("PULSE_RESEARCH_LIVE \(failures.isEmpty ? "ok" : "failed") failures=\(failures.joined(separator: ",")) throttled=\(throttled.joined(separator: ","))")
        // 只有真实失败才让这一轮判负；限流单独报告，供人判断是否需要重跑。
        return failures.isEmpty
    }
}
#endif
