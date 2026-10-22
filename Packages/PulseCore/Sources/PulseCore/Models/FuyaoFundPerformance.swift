import Foundation

// 基金（场内 ETF / LOF）的业绩与回撤。
//
// 三个端点拼成一份可读的答案，但**单位并不一致**，这是本模型存在的主要理由：
//
// - `performance/returns`：区间收益、同类平均、同类排名与总数。全是**百分数原值**
//   （`19.66` 就是 +19.66%）。
// - `performance/drawdowns`：最大回撤，**全是负值百分数**（`-12.5` 就是 -12.5%）。
//   负号是契约的一部分，取绝对值会把方向丢掉。
// - `performance/nav`：净值点位。`adj_nav` 是**复权净值，不等于累计净值**。
//   不传 `range` 时只返回最新一条。
//
// 还有两个易错点：`nav_type` 决定字段是否出现（没请求的类型不会有该键）；
// 区间收益里 `peer_average_*` 与 `rank_*` 只覆盖部分周期，缺哪个就是没有。

/// 一个考察周期。顺序即展示顺序（由近及远）。
public enum FuyaoPerformanceWindow: String, Codable, CaseIterable, Sendable, Identifiable {
    case week
    case month
    case tmonth
    case hyear
    case year
    case twoyear
    case tyear
    case fyear
    /// 今年以来。只有 `drawdowns` 提供，`returns` 没有对应键。
    case nowyear
    /// 成立以来。同样只有 `drawdowns` 提供。
    case now

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: "近一周"
        case .month: "近一月"
        case .tmonth: "近三月"
        case .hyear: "近半年"
        case .year: "近一年"
        case .twoyear: "近两年"
        case .tyear: "近三年"
        case .fyear: "近五年"
        case .nowyear: "今年以来"
        case .now: "成立以来"
        }
    }

    /// `returns` 接口用 `return_<window>` 作为键。
    var returnKey: String { "return_" + rawValue }
    /// `drawdowns` 接口直接用窗口名作键。
    var drawdownKey: String { rawValue }
    /// `returns` 的同类平均键是 `peer_average_<window>`。
    var peerAverageKey: String { "peer_average_" + rawValue }
    var rankKey: String { "rank_" + rawValue }
    var rankTotalKey: String { "rank_total_" + rawValue }
}

/// 一个周期的收益与同类比较。所有收益字段都是**百分数原值**。
public struct FuyaoPerformancePeriod: Codable, Hashable, Sendable, Identifiable {
    public let window: FuyaoPerformanceWindow
    /// 区间收益率，百分数原值。
    public let returnPercent: Double?
    /// 同类平均收益率，百分数原值。
    public let peerAveragePercent: Double?
    /// 同类排名（从 1 开始）。
    public let rank: Int?
    /// 参与排名的总数。
    public let rankTotal: Int?
    /// 最大回撤，**负值百分数**；缺失为 nil。
    public let drawdownPercent: Double?

    public var id: String { window.rawValue }

    public init(window: FuyaoPerformanceWindow, returnPercent: Double?,
                peerAveragePercent: Double?, rank: Int?, rankTotal: Int?,
                drawdownPercent: Double?) {
        self.window = window
        self.returnPercent = returnPercent
        self.peerAveragePercent = peerAveragePercent
        self.rank = rank
        self.rankTotal = rankTotal
        self.drawdownPercent = drawdownPercent
    }

    /// 是否跑赢同类平均。只在两侧都有值时才判断，缺一个就返回 nil。
    public var exceedsPeer: Bool? {
        guard let returnPercent, let peerAveragePercent,
              returnPercent.isFinite, peerAveragePercent.isFinite else { return nil }
        return returnPercent > peerAveragePercent
    }

    /// 排名的百分位（1 表示最前）。用于跨周期比较名次的相对位置。
    public var rankPercentile: Double? {
        guard let rank, let rankTotal, rank >= 1, rankTotal >= 1, rank <= rankTotal else { return nil }
        return Double(rank) / Double(rankTotal) * 100
    }
}

/// 净值点位。
public struct FuyaoFundNavPoint: Codable, Hashable, Sendable, Identifiable {
    public let date: Date
    /// 单位净值。未请求 `unit` 时为 nil。
    public let unitNav: Double?
    /// 复权净值。**不等于累计净值**。未请求 `adj` 时为 nil。
    public let adjustedNav: Double?

    public var id: Date { date }

    public init(date: Date, unitNav: Double?, adjustedNav: Double?) {
        self.date = date
        self.unitNav = unitNav
        self.adjustedNav = adjustedNav
    }
}

/// 一只基金的业绩快照。
public struct FuyaoFundPerformance: Codable, Hashable, Sendable {
    public let thscode: String
    public let periods: [FuyaoPerformancePeriod]
    public let navs: [FuyaoFundNavPoint]
    public let fetchedAt: Date
    /// 各端点各自的失败信息。部分失败保留其余成功数据。
    public let errors: [String: String]

    public init(thscode: String, periods: [FuyaoPerformancePeriod],
                navs: [FuyaoFundNavPoint], fetchedAt: Date, errors: [String: String] = [:]) {
        self.thscode = thscode
        self.periods = periods
        self.navs = navs
        self.fetchedAt = fetchedAt
        self.errors = errors
    }

    /// 只保留有任一数据的周期，顺序固定。
    public var nonEmptyPeriods: [FuyaoPerformancePeriod] {
        let order = FuyaoPerformanceWindow.allCases
        return periods
            .filter { $0.returnPercent != nil || $0.drawdownPercent != nil || $0.rank != nil }
            .sorted { (order.firstIndex(of: $0.window) ?? .max) < (order.firstIndex(of: $1.window) ?? .max) }
    }

    /// 最新点位。升序序列的最后一条，但只取日期最晚者（不假设顺序）。
    public var mostRecentNav: FuyaoFundNavPoint? {
        navs.max { $0.date < $1.date }
    }

    /// 是否有任何内容可展示。
    public var hasData: Bool { !nonEmptyPeriods.isEmpty || mostRecentNav != nil }

    public func period(_ window: FuyaoPerformanceWindow) -> FuyaoPerformancePeriod? {
        periods.first { $0.window == window }
    }
}

/// 业绩数据的格式化。
public enum FuyaoPerformanceFormat {
    /// 收益与回撤都是百分数原值，直接加 `%`，**不再乘 100**。
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return trimmed(value, digits: 2) + "%"
    }

    /// 回撤按契约是负值，这里保留符号；若上游给了正值也不擅自翻转。
    public static func drawdown(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return trimmed(value, digits: 2) + "%"
    }

    /// 净值保留 4 位（上游精度）。
    public static func nav(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return trimmed(value, digits: 4)
    }

    /// 排名写成 `12 / 480`，让"第几名"与"总共多少"同时可见。
    public static func rank(_ rank: Int?, _ total: Int?) -> String {
        guard let rank else { return "—" }
        guard let total else { return "第 \(rank)" }
        return "\(rank) / \(total)"
    }

    /// 定点后去掉多余尾零，不做"好看"的舍入。
    public static func trimmed(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
