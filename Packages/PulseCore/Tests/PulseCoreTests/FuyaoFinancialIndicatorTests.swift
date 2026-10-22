import Foundation
import Testing
@testable import PulseCore

@Suite("Fuyao financial indicators: units and unknown ids")
struct FuyaoFinancialIndicatorTests {
    private let stock = SymbolID(market: .sh, code: "600519")
    private let now = Date(timeIntervalSince1970: 1_792_500_000)
    private func data(_ string: String) -> Data { Data(string.utf8) }

    /// 2026-10-20 的真实返回形状：`growth` 组用 `calculate_` 前缀，`cash-flow`
    /// 组只有 4 项，`earned_interest_multiple` 是 null。
    private var live: Data {
        data(#"""
        {"code":0,"data":{"thscode":"600519.SH","report":"2026-2","abilities":[
          {"ability":"growth","indicators":[
            {"index_id":"calculate_operating_income_yoy_growth_ratio","value":"1.46986900"},
            {"index_id":"calculate_operating_profit_yoy_growth_ratio","value":"-2.16298200"},
            {"index_id":"total_assets_growth_ratio","value":"1.7167"},
            {"index_id":"fixed_asset_invest_expansion_ratio","value":"2.12587300"},
            {"index_id":"calculate_parent_holder_net_profit_yoy_growth_ratio","value":"-1.95159500"}
          ]},
          {"ability":"profitability","indicators":[
            {"index_id":"index_weighted_avg_roe","value":"16.7500"},
            {"index_id":"sale_gross_margin","value":"89.5552"},
            {"index_id":"sale_net_interest_ratio","value":"50.7516"}
          ]},
          {"ability":"solvency","indicators":[
            {"index_id":"current_ratio","value":"5.5895"},
            {"index_id":"cash_ratio","value":"114.73623000"},
            {"index_id":"earned_interest_multiple","value":null}
          ]},
          {"ability":"operation","indicators":[
            {"index_id":"total_assets_turnover_ratio","value":"0.2960"}
          ]},
          {"ability":"cash-flow","indicators":[
            {"index_id":"net_profit_cash_content","value":"158.79538200"},
            {"index_id":"cash_meet_invest_ratio","value":"1.97763799"}
          ]}
        ]}}
        """#)
    }

    @Test("Real payload parses with all five abilities in contract order")
    func parsesLiveShape() throws {
        let set = try FuyaoProvider.parseFinancialIndicators(data: live, thscode: "600519.SH", fetchedAt: now)
        #expect(set.report == "2026-2")
        #expect(set.reportTitle == "2026 中报")
        #expect(set.groups.map(\.ability) == [.growth, .profitability, .solvency, .operation, .cashFlow])
        // 文档没列的 4 个 growth id 全部保留，不因"不在文档里"被丢。
        #expect(set.groups[0].values.count == 5)
        #expect(set.value(of: "calculate_operating_income_yoy_growth_ratio") == 1.469869)
    }

    @Test("Percentage values are already percentages and never multiplied again")
    func percentUnits() throws {
        let set = try FuyaoProvider.parseFinancialIndicators(data: live, thscode: "600519.SH", fetchedAt: now)
        let roe = try #require(set.groups[1].values.first { $0.indexID == "index_weighted_avg_roe" })
        #expect(roe.displayText == "16.75%")
        // 现金比率是百分数（实测 114.736），不是倍数。
        let cash = try #require(set.groups[2].values.first { $0.indexID == "cash_ratio" })
        #expect(cash.definition?.unit == .percent)
        #expect(cash.displayText == "114.74%")
    }

    @Test("Ratios and turnover carry their own units, not percent")
    func ratioUnits() throws {
        let set = try FuyaoProvider.parseFinancialIndicators(data: live, thscode: "600519.SH", fetchedAt: now)
        let current = try #require(set.groups[2].values.first { $0.indexID == "current_ratio" })
        #expect(current.displayText == "5.59")
        let turnover = try #require(set.groups[3].values.first { $0.indexID == "total_assets_turnover_ratio" })
        #expect(turnover.displayText == "0.3次")
    }

    @Test("A null value stays missing: no zero, no placeholder number")
    func nullValue() throws {
        let set = try FuyaoProvider.parseFinancialIndicators(data: live, thscode: "600519.SH", fetchedAt: now)
        let interest = try #require(set.groups[2].values.first { $0.indexID == "earned_interest_multiple" })
        #expect(interest.value == nil)
        #expect(interest.rawValue == nil)
        #expect(interest.displayText == nil)
        // 未通过的可展示列表里仍包含它（有定义），界面显示占位符。
        #expect(interest.definition?.title == "已获利息倍数")
    }

    @Test("An unknown index id is kept raw but never displayed with a guessed unit")
    func unknownId() throws {
        let body = data(#"""
        {"code":0,"data":{"thscode":"600519.SH","report":"2026-2","abilities":[
          {"ability":"growth","indicators":[
            {"index_id":"fixed_asset_invest_expansion_ratio","value":"2.12587300"},
            {"index_id":"some_future_metric","value":"42"}
          ]}
        ]}}
        """#)
        let set = try FuyaoProvider.parseFinancialIndicators(data: body, thscode: "600519.SH", fetchedAt: now)
        let group = try #require(set.groups.first)
        #expect(group.values.count == 2)
        // 未知 id 保留原始串与数值……
        let unknown = try #require(group.values.first { $0.indexID == "some_future_metric" })
        #expect(unknown.rawValue == "42")
        #expect(unknown.value == 42)
        // ……但不进展示列表，因为单位不可知。`fixed_asset_invest_expansion_ratio`
        // 同样不在目录里（上游有、契约未定义单位），所以两者都被隐藏——
        // 这正是"宁可少一行，也不猜单位"的行为。
        #expect(unknown.definition == nil)
        #expect(FuyaoIndicatorCatalog.definition(for: "fixed_asset_invest_expansion_ratio") == nil)
        #expect(group.displayable.isEmpty)
        // 原始数据仍然完整保留，未来补上目录即可显示。
        #expect(group.values.count == 2)
    }

    @Test("The calculate_ prefix and the bare id resolve to the same definition")
    func aliasNormalization() {
        let prefixed = FuyaoIndicatorCatalog.definition(for: "calculate_sale_gross_margin")
        let bare = FuyaoIndicatorCatalog.definition(for: "sale_gross_margin")
        #expect(prefixed?.title == bare?.title)
        // 归一只对带前缀的写法兜底：两个真别名指向同一条目。
        #expect(FuyaoIndicatorCatalog.definition(for: "calculate_operating_income_yoy_growth_ratio")?.title
                == FuyaoIndicatorCatalog.definition(for: "operating_income_yoy_growth_ratio")?.title)
    }

    @Test("Report period is validated locally before any request")
    func reportValidation() {
        for ok in ["2026-1", "2026-2", "2026-3", "2026-4", "1999-4"] {
            #expect(FuyaoIndicatorCatalog.isValidReport(ok), "\(ok) should be valid")
        }
        for bad in ["2026-0", "2026-5", "2026", "20261", "abcd-1", "2026-01", "2026-1-1"] {
            #expect(!FuyaoIndicatorCatalog.isValidReport(bad), "\(bad) should be rejected")
        }
    }

    @Test("Statement period labels map onto yyyy-N without guessing")
    func periodMapping() {
        #expect(FuyaoIndicatorCatalog.report(fiscalYear: 2026, fiscalPeriod: "Q1") == "2026-1")
        #expect(FuyaoIndicatorCatalog.report(fiscalYear: 2026, fiscalPeriod: "Q4") == "2026-4")
        #expect(FuyaoIndicatorCatalog.report(fiscalYear: 2026, fiscalPeriod: "H1") == "2026-2")
        #expect(FuyaoIndicatorCatalog.report(fiscalYear: 2026, fiscalPeriod: "q3") == "2026-3")
        // 认不出的写法返回 nil，由调用方跳过，而不是猜一个期次。
        #expect(FuyaoIndicatorCatalog.report(fiscalYear: 2026, fiscalPeriod: "TTM") == nil)
        #expect(FuyaoIndicatorCatalog.report(fiscalYear: 2026, fiscalPeriod: "Q9") == nil)
    }

    @Test("A response echoing another symbol is rejected")
    func rejectsForeignSymbol() {
        let body = data(#"{"code":0,"data":{"thscode":"000001.SZ","report":"2026-2","abilities":[]}}"#)
        #expect(throws: ProviderError.self) {
            try FuyaoProvider.parseFinancialIndicators(data: body, thscode: "600519.SH", fetchedAt: now)
        }
    }

    @Test("Business errors surface as provider errors")
    func businessError() {
        let body = data(#"{"code":5002,"message":"timeout"}"#)
        #expect(throws: ProviderError.self) {
            try FuyaoProvider.parseFinancialIndicators(data: body, thscode: "600519.SH", fetchedAt: now)
        }
    }

    @Test("Displayable indicators keep catalog order, not upstream order")
    func stableOrder() throws {
        let body = data(#"""
        {"code":0,"data":{"thscode":"600519.SH","report":"2026-2","abilities":[
          {"ability":"profitability","indicators":[
            {"index_id":"sale_net_interest_ratio","value":"50.75"},
            {"index_id":"index_weighted_avg_roe","value":"16.75"},
            {"index_id":"sale_gross_margin","value":"89.56"}
          ]}
        ]}}
        """#)
        let set = try FuyaoProvider.parseFinancialIndicators(data: body, thscode: "600519.SH", fetchedAt: now)
        // 目录顺序：ROE → 扣非 ROE → 毛利率 → 净利率 → 总资产收益率。
        #expect(set.groups[0].displayable.map(\.indexID)
                == ["index_weighted_avg_roe", "sale_gross_margin", "sale_net_interest_ratio"])
    }

    @Test("Duplicate ids keep the first occurrence")
    func duplicateIds() throws {
        let body = data(#"""
        {"code":0,"data":{"thscode":"600519.SH","report":"2026-2","abilities":[
          {"ability":"profitability","indicators":[
            {"index_id":"sale_gross_margin","value":"89.56"},
            {"index_id":"sale_gross_margin","value":"99.99"}
          ]}
        ]}}
        """#)
        let set = try FuyaoProvider.parseFinancialIndicators(data: body, thscode: "600519.SH", fetchedAt: now)
        #expect(set.groups[0].displayable.count == 1)
        #expect(set.groups[0].displayable.first?.value == 89.56)
    }
}
