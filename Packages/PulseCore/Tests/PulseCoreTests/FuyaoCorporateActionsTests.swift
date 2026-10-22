import Foundation
import Testing
@testable import PulseCore

@Suite("Fuyao corporate actions and plan price basis")
struct FuyaoCorporateActionsTests {
    private let stock = SymbolID(market: .sh, code: "600519")
    private let now = Date(timeIntervalSince1970: 1_792_500_000)
    private func data(_ string: String) -> Data { Data(string.utf8) }
    private func beijingDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = FuyaoCorporateAction.exDateCalendar.timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - 解析

    @Test("Parsed actions are deduplicated per day, ordered newest first, and keep raw amounts")
    func parsing() throws {
        let body = data(#"""
        {"code":0,"data":{"thscode":"600519.SH","item":[
          {"ticker":"600519","ex_date_ms":1766073600000,"dividend_per_share":23.957,"per_share_bonus":0},
          {"ticker":"600519","ex_date_ms":1437062400000,"dividend_per_share":4.374,"per_share_bonus":0.1},
          {"ticker":"600519","ex_date_ms":1766073600000,"dividend_per_share":23.957,"per_share_bonus":0}
        ]}}
        """#)
        let series = try FuyaoProvider.parseCorporateActions(data: body, thscode: "600519.SH", fetchedAt: now)
        #expect(series.actions.count == 2)
        #expect(series.actions[0].exDate > series.actions[1].exDate)
        #expect(series.actions[0].cashPerShare == 23.957)
        #expect(series.actions[0].hasCash)
        #expect(series.actions[0].hasBonus == false)
        #expect(series.actions[1].bonusPerShare == 0.1)
        #expect(series.actions[1].hasBonus)
    }

    @Test("Events with no cash and no bonus are dropped; unusable dates are not stamped")
    func parsingDropsNoise() throws {
        let body = data(#"""
        {"code":0,"data":{"thscode":"600519.SH","item":[
          {"ticker":"600519","ex_date_ms":1766073600000,"dividend_per_share":0,"per_share_bonus":0},
          {"ticker":"600519","ex_date_ms":0,"dividend_per_share":5,"per_share_bonus":0},
          {"ticker":"600519","ex_date_ms":null,"dividend_per_share":5,"per_share_bonus":0},
          {"ticker":"600519","ex_date_ms":1766073600123,"dividend_per_share":5,"per_share_bonus":0},
          {"ticker":"600519","ex_date_ms":1780000000000,"dividend_per_share":-1,"per_share_bonus":null}
        ]}}
        """#)
        let series = try FuyaoProvider.parseCorporateActions(data: body, thscode: "600519.SH", fetchedAt: now)
        // 全零事件、零/缺失时间戳、非零点的时间戳（口径不明）都被丢弃；
        // 负分红按缺失处理，剩下的一条仍然有效（因 bonus 为 null 而无效）。
        #expect(series.actions.isEmpty)
        #expect(series.fetchedAt == now)
        #expect(series.dataTime == nil)
    }

    @Test("A response echoing another symbol is rejected instead of being applied")
    func rejectsForeignSymbol() {
        let body = data(#"{"code":0,"data":{"thscode":"000001.SZ","item":[{"ticker":"000001","ex_date_ms":1766073600000,"dividend_per_share":1}]}}"#)
        #expect(throws: ProviderError.self) {
            try FuyaoProvider.parseCorporateActions(data: body, thscode: "600519.SH", fetchedAt: now)
        }
    }

    @Test("Business errors surface as provider errors, not empty series")
    func businessErrorSurfaces() {
        let body = data(#"{"code":2004,"message":"client only"}"#)
        #expect(throws: ProviderError.self) {
            try FuyaoProvider.parseCorporateActions(data: body, thscode: "600519.SH", fetchedAt: now)
        }
    }

    // MARK: - 序列查询

    @Test("Series lookups respect day identity, not instant distance")
    func seriesLookups() {
        let older = FuyaoCorporateAction(thscode: "600519.SH", exDate: beijingDay(2015, 7, 17),
                                         cashPerShare: 4.374, bonusPerShare: 0.1)
        let newer = FuyaoCorporateAction(thscode: "600519.SH", exDate: beijingDay(2025, 12, 19),
                                         cashPerShare: 23.957, bonusPerShare: nil)
        let series = FuyaoCorporateActionSeries(thscode: "600519.SH", actions: [older], fetchedAt: now)
        #expect(series.latest?.exDate == older.exDate)
        let two = FuyaoCorporateActionSeries(thscode: "600519.SH", actions: [older, newer], fetchedAt: now)
        #expect(two.actions.map(\.exDate) == [newer.exDate, older.exDate])
        #expect(two.action(on: beijingDay(2025, 12, 19))?.cashPerShare == 23.957)
        #expect(two.action(on: beijingDay(2025, 12, 20)) == nil)
    }

    // MARK: - 计划口径提示

    private func plan(_ createdAt: Date, status: TradePlan.Status = .active, id: UUID = UUID()) -> TradePlan {
        TradePlan(id: id, kind: .buy, price: 1200, quantity: 100, status: status, createdAt: createdAt)
    }

    @Test("Only plans created before a meaningful, already-passed ex-date are flagged")
    func noticeEligibility() {
        let exDate = beijingDay(2026, 6, 19)
        let action = FuyaoCorporateAction(thscode: "600519.SH", exDate: exDate, cashPerShare: 23.957, bonusPerShare: 0.1)
        let series = [stock: FuyaoCorporateActionSeries(thscode: "600519.SH", actions: [action], fetchedAt: now)]

        let before = plan(exDate.addingTimeInterval(-86_400))
        let sameDay = plan(exDate)
        let after = plan(exDate.addingTimeInterval(86_400))
        let cancelled = plan(exDate.addingTimeInterval(-86_400), status: .cancelled)
        let done = plan(exDate.addingTimeInterval(-86_400), status: .done)

        let notices = FuyaoPlanPriceBasisNotice.notices(
            plans: [(stock, before), (stock, sameDay), (stock, after), (stock, cancelled), (stock, done)],
            series: series,
            asOf: now
        )
        #expect(notices.count == 1)
        #expect(notices.first?.planID == before.id)
    }

    @Test("A future ex-date does not flag anything yet")
    func futureExDateIsSilent() {
        let future = FuyaoCorporateAction(thscode: "600519.SH",
                                          exDate: now.addingTimeInterval(30 * 86_400),
                                          cashPerShare: 5, bonusPerShare: 0)
        let series = [stock: FuyaoCorporateActionSeries(thscode: "600519.SH", actions: [future], fetchedAt: now)]
        let notices = FuyaoPlanPriceBasisNotice.notices(
            plans: [(stock, plan(now.addingTimeInterval(-86_400)))],
            series: series, asOf: now
        )
        #expect(notices.isEmpty)
    }

    @Test("A cash-less, bonus-less row never flags a plan")
    func zeroActionIsSilent() {
        let action = FuyaoCorporateAction(thscode: "600519.SH", exDate: now.addingTimeInterval(-86_400),
                                          cashPerShare: 0, bonusPerShare: 0)
        let series = [stock: FuyaoCorporateActionSeries(thscode: "600519.SH", actions: [action], fetchedAt: now)]
        #expect(FuyaoPlanPriceBasisNotice.notices(
            plans: [(stock, plan(now.addingTimeInterval(-2 * 86_400)))], series: series, asOf: now).isEmpty)
    }

    @Test("Symbols without a series, and non-A-share plans, stay silent")
    func missingSeriesIsSilent() {
        let exDate = now.addingTimeInterval(-86_400)
        let action = FuyaoCorporateAction(thscode: "600519.SH", exDate: exDate, cashPerShare: 5, bonusPerShare: 0)
        let onlyStock = [stock: FuyaoCorporateActionSeries(thscode: "600519.SH", actions: [action], fetchedAt: now)]
        let us = SymbolID(market: .us, code: "AAPL")
        let notices = FuyaoPlanPriceBasisNotice.notices(
            plans: [(us, plan(now.addingTimeInterval(-2 * 86_400)))],
            series: onlyStock, asOf: now
        )
        #expect(notices.isEmpty)
    }

    @Test("Several actions on one plan produce one notice each, newest first")
    func multipleActionsOrdering() {
        let first = FuyaoCorporateAction(thscode: "600519.SH", exDate: beijingDay(2025, 6, 20), cashPerShare: 10, bonusPerShare: 0)
        let second = FuyaoCorporateAction(thscode: "600519.SH", exDate: beijingDay(2026, 6, 19), cashPerShare: 23.957, bonusPerShare: 0)
        let series = [stock: FuyaoCorporateActionSeries(thscode: "600519.SH", actions: [first, second], fetchedAt: now)]
        let early = plan(beijingDay(2024, 1, 2))
        let notices = FuyaoPlanPriceBasisNotice.notices(plans: [(stock, early)], series: series, asOf: now)
        #expect(notices.count == 2)
        #expect(notices[0].action.exDate == second.exDate)
        #expect(notices.allSatisfy { $0.planID == early.id })
    }
}
