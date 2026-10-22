import Foundation

// A 股除权除息事件流（分红 / 送股）与本机价格口径提示。
//
// 这个模型存在的理由是**口径不一致**：项目用不复权价记录真实成交与计划触发价，
// 用前复权价画图。除权日不复权序列会出现真实断层——用户看到价格"忽然跌了"，
// 但应用从不解释原因，也不提示那条在除权前设下的计划，其触发价在序列里的相对
// 位置已经改变。
//
// 这里只做两件事：转述上游事件，以及用纯函数判断"哪条计划需要复核"。
// 它不修改任何计划、不重算成本、不推断分红到账。
//
// 上游 `GET /api/a-share/corporate-actions/adjustment-factors` 只给两个数值字段
// （每股现金分红、每股送股比），事件类型由这两个值隐式区分；**不含配股**
// （配股比例与价格只出现在 market-dumps 的 Parquet 里）。所以界面必须写明
// "配股不在本数据内"，不能把"没有配股记录"读成"没有配股"。

/// 一次除权除息事件。日期是 Asia/Shanghai 的当日零点。
public struct FuyaoCorporateAction: Codable, Hashable, Sendable, Identifiable {
    public let thscode: String
    /// 除权除息日（上游 `ex_date_ms`）。零点的日历日身份，不是某一时刻。
    public let exDate: Date
    /// 每股现金分红（税前、原始货币）。`nil` 表示上游缺该字段；`0` 表示非现金事件。
    public let cashPerShare: Double?
    /// 每股送股比例（`0.1` 表示 10 送 1）。`nil` 同上；`0` 表示纯现金分红。
    public let bonusPerShare: Double?

    /// 同一代码同一天只保留一条：上游可能因多次修订重复返回。
    public var id: String { "\(thscode)|\(Int(exDate.timeIntervalSince1970))" }

    public var hasCash: Bool { (cashPerShare ?? 0) > 0 }
    public var hasBonus: Bool { (bonusPerShare ?? 0) > 0 }
    /// 两个数值都为零的事件没有任何价格影响，不进入展示。
    public var isMeaningful: Bool { hasCash || hasBonus }

    public init(thscode: String, exDate: Date, cashPerShare: Double?, bonusPerShare: Double?) {
        self.thscode = thscode
        self.exDate = exDate
        self.cashPerShare = Self.positive(cashPerShare)
        self.bonusPerShare = Self.positive(bonusPerShare)
    }

    /// 非有限值与负值都不是可信的分红比例，按缺失处理。
    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// 一只标的的事件序列，按除权日降序（最新在前）。
public struct FuyaoCorporateActionSeries: Codable, Hashable, Sendable {
    public let thscode: String
    public let actions: [FuyaoCorporateAction]
    /// 本机收到这份答案的时间；与事件日期无关。
    public let fetchedAt: Date
    /// 上游就绪时间（`data.timestamp` 语义未在本端点声明时保持 nil，不补 `now`）。
    public let dataTime: Date?

    public init(thscode: String, actions: [FuyaoCorporateAction], fetchedAt: Date, dataTime: Date? = nil) {
        self.thscode = thscode
        self.actions = actions.sorted { $0.exDate > $1.exDate }
        self.fetchedAt = fetchedAt
        self.dataTime = dataTime
    }

    /// 最近一次有价格影响的除权。
    public var latest: FuyaoCorporateAction? { actions.first }

    /// 落在 `date` 之前（不含）的最近一次除权。
    public func latest(before date: Date) -> FuyaoCorporateAction? {
        let beijing = FuyaoCorporateAction.exDateCalendar
        return actions.first { $0.exDate < date && Self.isSameOrEarlierDay($0.exDate, than: date, calendar: beijing) }
    }

    /// `date` 所在交易日内或之前最近的除权，用于"今天这只票除权了吗"。
    public func action(on day: Date) -> FuyaoCorporateAction? {
        let calendar = FuyaoCorporateAction.exDateCalendar
        return actions.first { calendar.isDate($0.exDate, inSameDayAs: day) }
    }

    private static func isSameOrEarlierDay(_ lhs: Date, than rhs: Date, calendar: Calendar) -> Bool {
        let left = calendar.dateComponents([.year, .month, .day], from: lhs)
        let right = calendar.dateComponents([.year, .month, .day], from: rhs)
        return (left.year ?? 0, left.month ?? 0, left.day ?? 0) <= (right.year ?? 0, right.month ?? 0, right.day ?? 0)
    }
}

public extension FuyaoCorporateAction {
    /// 除权日按 Asia/Shanghai 解释：上游给的是该市场日历日零点。
    static let exDateCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        return calendar
    }()
}

// MARK: - 计划口径提示

/// 一条计划与一次除权的关系。纯派生值，不落库、不改价。
///
/// 命中条件是三条同时成立：计划仍在等待、计划创建于该次除权之前、该次除权确实
/// 有现金分红或送股。少任何一条都不提示——否则会在除权后新建的计划上撒谎。
public struct FuyaoPlanPriceBasisNotice: Hashable, Sendable, Identifiable {
    public let planID: UUID
    public let symbol: SymbolID
    public let action: FuyaoCorporateAction

    public var id: String { "\(planID.uuidString)|\(action.id)" }

    public init(planID: UUID, symbol: SymbolID, action: FuyaoCorporateAction) {
        self.planID = planID
        self.symbol = symbol
        self.action = action
    }

    /// 一次性算出所有需要复核的计划，按除权日降序、同日按计划创建时间升序。
    ///
    /// - Parameters:
    ///   - plans: 候选计划与它们所属的标的。调用方只传活跃计划即可，但本函数
    ///     仍会拦截非 `.active` 的计划，因为它不该依赖调用方过滤得是否干净。
    ///   - series: 按标的索引的事件序列；缺失即该标的没有可判定的除权。
    ///   - asOf: 判定时点。晚于它的除权不算数，避免"预告中的未来除权"提前提示。
    public static func notices(
        plans: [(symbol: SymbolID, plan: TradePlan)],
        series: [SymbolID: FuyaoCorporateActionSeries],
        asOf: Date = .now
    ) -> [FuyaoPlanPriceBasisNotice] {
        var result: [FuyaoPlanPriceBasisNotice] = []
        for entry in plans {
            guard entry.plan.status == .active else { continue }
            guard let actions = series[entry.symbol]?.actions, !actions.isEmpty else { continue }
            for action in actions {
                guard action.isMeaningful else { continue }
                // 未来除权不提示：它还没发生，价格断层也还没出现。
                guard action.exDate <= asOf else { continue }
                // 计划必须早于除权日才谈得上"设价时还没除权"。
                guard entry.plan.createdAt < action.exDate else { continue }
                result.append(.init(planID: entry.plan.id, symbol: entry.symbol, action: action))
            }
        }
        return result.sorted {
            if $0.action.exDate != $1.action.exDate { return $0.action.exDate > $1.action.exDate }
            return $0.planID.uuidString < $1.planID.uuidString
        }
    }
}
