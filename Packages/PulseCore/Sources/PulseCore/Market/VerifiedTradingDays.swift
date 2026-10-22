import Foundation

/// 上游校准过的交易日集合。
///
/// 存在的理由：本地 `ExchangeCalendar` 的沪深节假日表只核验到 **2026 年**，
/// 之后静默回退到"工作日"规则。板块 5/20 日相对强弱、涨跌停历史日期、复盘
/// "上一交易日"都依赖交易日，却没有地方能发现本地表错了。
///
/// 边界必须刻意保留：
/// - 上游端点固定返回 `[今日 - 1 年, 今日]`，**不含未来**。所以本类型只回答
///   过去一年内的判断；问未来日期时明确说"无覆盖"，绝不用它推断休市。
/// - 它不改 `PositionTransaction.date` 的本机民用日语义——成交日期是用户录入
///   的当地日历日，与交易所日历是两件事。
/// - 差异检测只提示，不写回。历史成交日期不因上游日历而改变。
public struct VerifiedTradingDays: Codable, Hashable, Sendable {
    /// 覆盖区间（含两端）。
    public let coverage: ClosedRange<CalendarDay>
    /// 该区间内确认为交易日的工作日。
    public let days: Set<CalendarDay>
    /// 拉取时间。
    public let fetchedAt: Date

    public init(coverage: ClosedRange<CalendarDay>, days: Set<CalendarDay>, fetchedAt: Date) {
        self.coverage = coverage
        self.days = days
        self.fetchedAt = fetchedAt
    }

    /// 是否覆盖某一天。超出区间即为无覆盖——不是"休市"。
    public func covers(_ day: CalendarDay) -> Bool {
        coverage.contains(day)
    }

    /// 该日是否交易日。无覆盖时返回 nil（未知），而不是 false。
    public func isTradingDay(_ day: CalendarDay) -> Bool? {
        guard covers(day) else { return nil }
        return days.contains(day)
    }

    /// 该日之前（不含）最近的交易日。无覆盖时返回 nil。
    public func previousTradingDay(before day: CalendarDay, limit: Int = 30) -> CalendarDay? {
        guard covers(day) else { return nil }
        var candidate = day
        for _ in 0..<limit {
            candidate = ExchangeCalendar.previousDay(candidate)
            guard covers(candidate) else { return nil }
            if days.contains(candidate) { return candidate }
        }
        return nil
    }

    /// 最近 `count` 个交易日，按时间升序。不足时返回实际数量。
    public func lastTradingDays(_ count: Int, onOrBefore day: CalendarDay) -> [CalendarDay] {
        guard count > 0, covers(day) else { return [] }
        var result: [CalendarDay] = []
        var candidate = day
        while result.count < count {
            guard covers(candidate) else { break }
            if days.contains(candidate) { result.append(candidate) }
            candidate = ExchangeCalendar.previousDay(candidate)
        }
        return result.reversed()
    }

    /// 与本地表在过去一年内的差异。
    ///
    /// 两个方向都报：本地认为是交易日而上游不发（多算），以及本地认为休市而
    /// 上游有数据（少算）。只用于在设置页提示，**不改任何历史记录**。
    public struct Discrepancy: Codable, Hashable, Sendable {
        /// 本地判为交易日、上游未列出。
        public let localOnly: [CalendarDay]
        /// 上游列出、本地判为休市。
        public let upstreamOnly: [CalendarDay]

        public var isEmpty: Bool { localOnly.isEmpty && upstreamOnly.isEmpty }
        public var total: Int { localOnly.count + upstreamOnly.count }
    }

    public func discrepancies(with market: Market) -> Discrepancy {
        var localOnly: [CalendarDay] = []
        var upstreamOnly: [CalendarDay] = []
        var day = coverage.lowerBound
        while day <= coverage.upperBound {
            let local = ExchangeCalendar.isTradingDay(market, on: day)
            let upstream = days.contains(day)
            // 只比较双方都"有说法"的日子。周末与已知假期两侧都该是休市。
            if local && !upstream { localOnly.append(day) }
            if !local && upstream { upstreamOnly.append(day) }
            day = ExchangeCalendar.nextDay(day)
        }
        return Discrepancy(localOnly: localOnly, upstreamOnly: upstreamOnly)
    }
}

/// 校准状态：给界面一个诚实的说法。
public enum TradingDayCalibration: Sendable, Equatable {
    /// 尚未拉取过。
    case notCalibrated
    /// 已有校准数据。
    case calibrated(VerifiedTradingDays)
    /// 拉取失败，但保留了之前成功的副本。
    case stale(VerifiedTradingDays, error: String)
}
