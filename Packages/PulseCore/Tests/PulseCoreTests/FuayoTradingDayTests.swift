import Foundation
import Testing
@testable import PulseCore

@Suite("Verified trading days: coverage bounds and local discrepancy")
struct FuayoTradingDayTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)
    private func data(_ string: String) -> Data { Data(string.utf8) }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay { .init(year: y, month: m, day: d) }

    /// 三天序列，含一个跨周末的间隔。
    private var body: Data {
        data(#"""
        {"code":0,"data":{"timestamp":1792648826286,"item":[
          {"date_ms":1791820800000,"date":"20261013"},
          {"date_ms":1791907200000,"date":"20261014"},
          {"date_ms":1791993600000,"date":"20261015"},
          {"date_ms":1792080000000,"date":"20261016"},
          {"date_ms":1792339200000,"date":"20261019"}
        ]}}
        """#)
    }

    // MARK: - 解析

    @Test("Dates come from the yyyyMMdd field and keep the real trading range")
    func parsesDays() throws {
        let result = try FuyaoProvider.parseTradingDays(data: body, fetchedAt: now)
        #expect(result.days.count == 5)
        #expect(result.days.contains(day(2026, 10, 13)))
        #expect(result.days.contains(day(2026, 10, 19)))
        #expect(result.fetchedAt == now)
        // 区间取实际首末交易日。
        #expect(result.coverage.lowerBound == day(2026, 10, 13))
        #expect(result.coverage.upperBound == day(2026, 10, 19))
    }

    @Test("A malformed date is skipped rather than guessed")
    func skipsMalformedDates() throws {
        let body = data(#"""
        {"code":0,"data":{"item":[
          {"date":"2026-10-13"},
          {"date":"20261332"},
          {"date":"20261013"},
          {"date":null,"date_ms":null}
        ]}}
        """#)
        let result = try FuyaoProvider.parseTradingDays(data: body, fetchedAt: now)
        // 只有 20261013 合法；`20261332` 月份越界，被拒。
        #expect(result.days == [day(2026, 10, 13)])
    }

    @Test("An empty series is an error, not an empty calendar")
    func emptySeriesIsError() {
        let body = data(#"{"code":0,"data":{"item":[]}}"#)
        #expect(throws: ProviderError.self) {
            try FuyaoProvider.parseTradingDays(data: body, fetchedAt: now)
        }
    }

    // MARK: - 覆盖边界

    @Test("A day outside coverage is unknown, never 'closed'")
    func outsideCoverageIsUnknown() throws {
        let result = try FuyaoProvider.parseTradingDays(data: body, fetchedAt: now)
        // 区间内：明确答案。
        #expect(result.isTradingDay(day(2026, 10, 13)) == true)
        #expect(result.isTradingDay(day(2026, 10, 17)) == false)  // 周六在区间内但非交易日
        // 区间外：nil，而不是 false。这是本类型最重要的一条。
        #expect(result.isTradingDay(day(2027, 1, 4)) == nil)
        #expect(result.isTradingDay(day(2025, 1, 1)) == nil)
        #expect(result.covers(day(2027, 1, 4)) == false)
    }

    @Test("Previous trading day walks past the weekend and stops at coverage")
    func previousTradingDay() throws {
        let result = try FuyaoProvider.parseTradingDays(data: body, fetchedAt: now)
        // 10-19（周一）之前是 10-16（周五），跨过周末。
        #expect(result.previousTradingDay(before: day(2026, 10, 19)) == day(2026, 10, 16))
        // 区间起点之前没有答案。
        #expect(result.previousTradingDay(before: day(2026, 10, 13)) == nil)
    }

    @Test("Last N trading days stay inside coverage and come back ascending")
    func lastTradingDays() throws {
        let result = try FuyaoProvider.parseTradingDays(data: body, fetchedAt: now)
        let last3 = result.lastTradingDays(3, onOrBefore: day(2026, 10, 19))
        #expect(last3 == [day(2026, 10, 15), day(2026, 10, 16), day(2026, 10, 19)])
        // 请求超过覆盖范围时返回实际能给的，不补假日期。
        #expect(result.lastTradingDays(100, onOrBefore: day(2026, 10, 19)).count == 5)
    }

    // MARK: - 本地差异

    @Test("Discrepancy reports both directions and never mutates anything")
    func discrepancies() throws {
        // 构造一份与本地表故意不同的日历：把 2026-10-13（周二）拿掉，
        // 再把 2026-10-17（周六）加进去。
        let days: Set<CalendarDay> = [
            day(2026, 10, 14), day(2026, 10, 15), day(2026, 10, 16), day(2026, 10, 17)
        ]
        let result = VerifiedTradingDays(
            coverage: day(2026, 10, 13)...day(2026, 10, 17), days: days, fetchedAt: now)
        let difference = result.discrepancies(with: .sh)
        // 本地认为 10-13 交易，上游没有 → localOnly。
        #expect(difference.localOnly.contains(day(2026, 10, 13)))
        // 上游给了周六 10-17，本地判休市 → upstreamOnly。
        #expect(difference.upstreamOnly.contains(day(2026, 10, 17)))
        #expect(difference.total >= 2)
        #expect(!difference.isEmpty)
    }

    @Test("An agreeing calendar reports no discrepancy")
    func noDiscrepancy() {
        // 只取一个确定两边都开市的工作日。
        let result = VerifiedTradingDays(
            coverage: day(2026, 10, 14)...day(2026, 10, 14),
            days: [day(2026, 10, 14)], fetchedAt: now)
        let difference = result.discrepancies(with: .sh)
        // 2026-10-14 是周三且非节假日：两侧都开市。
        #expect(difference.isEmpty)
    }

    @Test("CalendarDay round-trips through Codable as yyyy-MM-dd")
    func calendarDayCodable() throws {
        let value = day(2026, 10, 14)
        let encoded = try JSONEncoder().encode(value)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"2026-10-14\"")
        let decoded = try JSONDecoder().decode(CalendarDay.self, from: encoded)
        #expect(decoded == value)
    }
}
