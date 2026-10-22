import Foundation

// 交易日历：上游校准本地表的唯一来源。
//
// 端点固定返回 `[今日-1年, 今日]`，无入参。**它不含未来**——所以它只能校准
// 过去一年，绝不能用来推断明天的休市安排。这一点写在类型注释里，也写在设置页。

extension FuyaoProvider {
    /// 拉取近一年的 A 股交易日，构造校准集合。
    public func verifiedTradingDays() async throws -> VerifiedTradingDays {
        let data = try await fetchResearchData(path: Self.tradingDaysPath)
        try Task.checkCancellation()
        return try Self.parseTradingDays(data: data, fetchedAt: .now)
    }

    static func parseTradingDays(data: Data, fetchedAt: Date) throws -> VerifiedTradingDays {
        let payload = try decodePayload(TradingDaysPayload.self, from: data, endpoint: "trading-days")
        var days: Set<CalendarDay> = []
        var first: CalendarDay?
        var last: CalendarDay?
        for row in payload.item ?? [] {
            // 优先用 `date`（yyyyMMdd），它与业务日语义完全一致；缺失时回退毫秒戳。
            let day = row.date.flatMap(Self.calendarDay(fromCompact:))
                ?? Self.millisecondDate(row.dateMs).map { CalendarDay($0, in: beijingTimeZone) }
            guard let day else { continue }
            days.insert(day)
            if first == nil { first = day }
            last = day
        }
        guard let lower = first, let upper = last ?? first else {
            throw ProviderError.badResponse("fuyao trading-days: empty series")
        }
        // 只保留确认为交易日的日子；区间取实际首末交易日。
        return VerifiedTradingDays(coverage: lower...upper, days: days, fetchedAt: fetchedAt)
    }

    /// `yyyyMMdd` → CalendarDay。格式不对返回 nil，不猜。
    static func calendarDay(fromCompact text: String) -> CalendarDay? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 8, trimmed.allSatisfy(\.isNumber),
              let year = Int(trimmed.prefix(4)),
              let month = Int(trimmed.dropFirst(4).prefix(2)),
              let day = Int(trimmed.suffix(2)),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }

    static let tradingDaysPath = "/api/a-share/calendar/trading-days"

    struct TradingDaysPayload: Decodable {
        let item: [TradingDayRow]?
    }

    struct TradingDayRow: Decodable {
        let date: String?
        let dateMs: Double?
    }
}
