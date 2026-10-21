import Foundation
import Testing
@testable import PulseCore

@Suite("Fuyao research financial semantics")
struct FuyaoResearchDataTests {
    private let fundA = SymbolID(market: .sh, code: "510300")
    private let fundB = SymbolID(market: .sh, code: "588200")
    private let stock = SymbolID(market: .sh, code: "600519")
    private let now = Date(timeIntervalSince1970: 1_792_500_000)
    private var report: FuyaoFundReport { .init(reportType: "quarter", endDate: Date(timeIntervalSince1970: 1_782_748_800)) }
    private func data(_ string: String) -> Data { Data(string.utf8) }

    @Test("Fund weights preserve percent units, unknowns and report boundaries")
    func fundParsing() throws {
        let body = #"""
        {"code":0,"data":{"item":[
          {"thscode":"600519.SH","name":"A","asset_type":"stock","hold_ratio":4.67,"report_type":"quarter","end_date_ms":1782748800000},
          {"thscode":"600519.SH","name":"duplicate","asset_type":"stock","hold_ratio":80},
          {"thscode":"000001.SZ","asset_type":"stock","hold_ratio":null},
          {"thscode":"000002.SZ","asset_type":"stock","hold_ratio":-1},
          {"thscode":"000003.SZ","asset_type":"stock","hold_ratio":90,"report_type":"annual"},
          {"thscode":"000004.SZ","asset_type":"stock","hold_ratio":90,"end_date_ms":1780000000000},
          {"thscode":"bond.X","asset_type":"bond","hold_ratio":80}
        ]}}
        """#
        let result = try FuyaoProvider.parseFundHoldings(data: data(body), fund: fundA, report: report, fetchedAt: now)
        #expect(result.holdings.count == 3)
        #expect(result.holdings.first?.weightPercent == 4.67)
        #expect(result.disclosedWeightPercent == 4.67)
        #expect(result.holdings[1].weightPercent == nil)
        #expect(result.holdings.allSatisfy { $0.reportEnd == report.endDate })
    }
    @Test("Deployed fund rows may use bare tickers and the catalog display report type")
    func deployedFundShape() throws {
        let named = FuyaoFundReport(reportType: "quarter", reportTypeName: "季度", endDate: report.endDate)
        let body = data(#"{"code":0,"data":{"item":[{"thscode":"600519","name":"A","asset_type":"stock","hold_ratio":2.52,"report_type":"季度","end_date_ms":1782748800000}]}}"#)
        let parsed = try FuyaoProvider.parseFundHoldings(data: body, fund: fundA, report: named, fetchedAt: now)
        #expect(parsed.holdings.first?.thscode == "600519")
        #expect(parsed.disclosedWeightPercent == 2.52)
        let meta = data(#"{"code":0,"data":{"item":[{"thscode":"600519.SH","name":"A","asset_type":"a-share"},{"thscode":"600519.SZ","name":"Index","asset_type":"a-share-index"}]}}"#)
        #expect(try FuyaoProvider.parseFundStockCode(data: meta, ticker: "600519", name: "A") == "600519.SH")
        #expect(try FuyaoProvider.parseFundStockCode(data: meta, ticker: "000001", name: "A") == nil)
        #expect(try FuyaoProvider.parseFundStockCode(data: meta, ticker: "600519", name: "海外同代码公司") == nil)
        let allocation = PortfolioAllocation.calculate(positions: [.init(symbol: fundA, name: "ETF", quantity: 100, price: 1, currencyCode: "CNY")])
        let estimate = FuyaoLookThrough.calculate(allocation: allocation, types: [fundA: .etf], reports: [fundA: parsed])
        #expect(estimate.first?.unresolvedAmount == 100)
        #expect(estimate.first?.exposures.isEmpty == true)
    }

    @Test("Latest report chooses a complete report type and never a future period")
    func fundReportChoice() {
        let annual = FuyaoFundReport(reportType: "annual", endDate: report.endDate)
        let future = FuyaoFundReport(reportType: "quarter", endDate: now.addingTimeInterval(86_400))
        #expect(FuyaoProvider.latestFundReport([report, annual, future], asOf: now) == annual)
        #expect(FuyaoProvider.latestFundReport([future], asOf: now) == nil)
    }
    @Test("Look-through merges direct and multiple ETF exposure without normalizing missing weights")
    func lookThrough() throws {
        let allocation = PortfolioAllocation.calculate(positions: [
            .init(symbol: fundA, name: "ETF A", quantity: 100, price: 1, currencyCode: "CNY"),
            .init(symbol: fundB, name: "ETF B", quantity: 200, price: 1, currencyCode: "CNY"),
            .init(symbol: stock, name: "Direct A", quantity: 50, price: 1, currencyCode: "CNY")
        ])
        let first = FuyaoFundHoldings(fund: fundA, report: report, holdings: [
            .init(thscode: "600519.SH", name: "A", weightPercent: 20), .init(thscode: "000001.SZ", name: "B", weightPercent: 10)
        ], fetchedAt: now)
        let second = FuyaoFundHoldings(fund: fundB, report: report, holdings: [.init(thscode: "600519.SH", name: "A", weightPercent: 40)], fetchedAt: now)
        let result = try #require(FuyaoLookThrough.calculate(allocation: allocation, types: [fundA: .etf, fundB: .etf, stock: .equity], reports: [fundA: first, fundB: second]).first)
        let a = try #require(result.exposures.first { $0.thscode == "600519.SH" })
        #expect(a.amount == 150)
        #expect(a.components.count == 3)
        #expect(a.overlaps)
        #expect(abs(a.percent - 150.0 / 350 * 100) < 1e-9)
        #expect(result.unresolvedAmount == 190)
        #expect(result.exposures.reduce(0) { $0 + $1.amount } + result.unresolvedAmount == result.totalLongExposure)
    }
    @Test("Invalid fund weight sums stay unresolved, shorts and currencies stay separate")
    func invalidWeightsAndCurrencies() throws {
        let hk = SymbolID(market: .hk, code: "00700")
        let allocation = PortfolioAllocation.calculate(positions: [
            .init(symbol: fundA, name: "ETF", quantity: 100, price: 1, currencyCode: "CNY"),
            .init(symbol: stock, name: "short", quantity: -10, price: 1, currencyCode: "CNY"),
            .init(symbol: hk, name: "HK", quantity: 20, price: 1, currencyCode: "HKD")
        ])
        let bad = FuyaoFundHoldings(fund: fundA, report: report, holdings: [
            .init(thscode: "600519.SH", name: "A", weightPercent: 60), .init(thscode: "000001.SZ", name: "B", weightPercent: 50)
        ], fetchedAt: now)
        #expect(bad.disclosedWeightPercent == nil)
        let result = FuyaoLookThrough.calculate(allocation: allocation, types: [fundA: .etf, stock: .equity, hk: .equity], reports: [fundA: bad])
        let cny = try #require(result.first { $0.code == "CNY" })
        #expect(cny.totalLongExposure == 100)
        #expect(cny.unresolvedAmount == 100)
        #expect(cny.excludedShortExposure == 10)
        #expect(cny.exposures.isEmpty)
        #expect(result.first { $0.code == "HKD" }?.totalLongExposure == 20)
    }
    @Test("Statistics keep fraction units, nulls and actual business date")
    func statistics() throws {
        let parsed = try FuyaoProvider.parseMarketStatistics(data: data(#"{"code":0,"data":{"trade_date":"2026-10-20","seal_rate":0.642,"limit_up_stock_count":52,"open_stock_count":null,"exact_boards":[{"board_num":4,"stock_count":1}]}}"#), fetchedAt: now)
        #expect(parsed.value.sealRate == 0.642)
        #expect(parsed.value.opened == nil)
        #expect(parsed.dataTime == nil)
        #expect(parsed.value.tiers.first?.boardNumber == 4)
        #expect(parsed.value.tradeDate == FuyaoProvider.beijingDay(of: "2026-10-20"))
    }
    @Test("Stock pools isolate pagination and preserve percentage units")
    func pool() throws {
        let json = #"{"code":0,"data":{"pagination":{"total":300,"pages":2,"page":1},"item":[{"thscode":"600519.SH","name":"A","price_change_ratio_pct":10.0,"continue_day_cnt":2},{"thscode":"600519.SH","name":"duplicate"}]}}"#
        let parsed = try FuyaoProvider.parseLimitPool(data: data(json), kind: .up, tradeDate: now, page: 1, fetchedAt: now)
        #expect(parsed.value.stocks.count == 1)
        #expect(parsed.value.stocks.first?.changePercent == 10)
        #expect(parsed.value.hasMore)
        #expect(throws: ProviderError.self) { _ = try FuyaoProvider.parseLimitPool(data: data(json), kind: .up, tradeDate: now, page: 2, fetchedAt: now) }
    }
    @Test("Statements filter future disclosures and unrelated identities; cumulative periods stay intact")
    func statements() throws {
        let json = #"""
        {"code":0,"data":{"item":[
          {"thscode":"600519.SH","fiscal_year":2026,"fiscal_period":"Q2","period_end_ms":1782748800000,"report_date_ms":1786723200000,"currency":"CNY","operating_income":120,"parent_holder_net_profit":12},
          {"thscode":"600519.SH","fiscal_year":2025,"fiscal_period":"Q2","period_end_ms":1751212800000,"currency":"CNY","operating_income":100,"parent_holder_net_profit":-5},
          {"thscode":"600519.SH","fiscal_year":2026,"fiscal_period":"Q3","period_end_ms":1790000000000,"report_date_ms":1890000000000,"operating_income":999},
          {"thscode":"000001.SZ","fiscal_year":2026,"fiscal_period":"Q2","period_end_ms":1782748800000,"operating_income":999}
        ]}}
        """#
        let rows = try FuyaoProvider.parseFinancialStatement(data: data(json), thscode: "600519.SH", asOf: now).value
        #expect(rows.count == 2)
        #expect(rows[0].values["revenue"] == 120)
        #expect(abs((rows[0].yearOverYear("revenue", in: rows) ?? .nan) - 20) < 1e-9)
        #expect(rows[0].yearOverYear("parentProfit", in: rows) == nil)
        #expect(rows[1].disclosedAt == nil)
    }
    @Test("Valuations match full identity and missing metrics remain unknown")
    func valuation() throws {
        let json = #"{"code":0,"data":{"item":[{"thscode":"000001.SZ","pe_ttm":100},{"thscode":"600519.SH","pe_ttm":-2,"pb_mrq":null}]}}"#
        let result = try FuyaoProvider.parseValuation(data: data(json), thscode: "600519.SH", fetchedAt: now)
        #expect(result.value?.peTTM == -2)
        #expect(result.value?.pbMRQ == nil)
        #expect(result.dataTime == nil)
    }
    @Test("Business permission errors are not empty successful research")
    func businessErrors() {
        let denied = data(#"{"code":2004,"message":"client-only"}"#)
        #expect(throws: ProviderError.self) { _ = try FuyaoProvider.parseMarketStatistics(data: denied, fetchedAt: now) }
        #expect(throws: ProviderError.self) { _ = try FuyaoProvider.parseFundReports(data: denied, fetchedAt: now) }
        #expect(throws: ProviderError.self) { _ = try FuyaoProvider.parseFinancialStatement(data: denied, thscode: "600519.SH", asOf: now) }
    }
}
