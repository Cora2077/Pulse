import Foundation

// A 股新股发行与申购日历。
//
// 这一天独有的几个事实决定了模型形状：
// 1. **股票代码与申购代码是两个字段**（`ticker` vs `subscription_code`）。新股上市
//    后的交易代码与打新时输入的申购代码经常不同，合并它们会让用户按错代码。
// 2. **`listing_date` 与 `issue_price` 在未确定时就是 `null`**。不补 0、不猜范围。
// 3. **没有中签率、没有申购上限**。契约不提供，界面也就不做这两列。
// 4. 京市（`.BJ`）标的在本 App 没有对应市场身份，能展示但不能加入自选。

/// 发行阶段。
public enum FuyaoIPOStage: String, Codable, CaseIterable, Sendable, Identifiable {
    case upcoming
    case subscribable
    case awaitingListing = "awaiting_listing"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .upcoming: "待申购"
        case .subscribable: "可申购"
        case .awaitingListing: "待上市"
        }
    }

    /// 展示顺序：先能做的，再是即将发生的。
    public var sortOrder: Int {
        switch self {
        case .subscribable: 0
        case .upcoming: 1
        case .awaitingListing: 2
        }
    }
}

/// 发行市场分组。京市与沪深分开请求，契约本身就是两个枚举值。
public enum FuyaoIPOMarket: String, Codable, CaseIterable, Sendable, Identifiable {
    case shSz = "sh_sz"
    case bj

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shSz: "沪深"
        case .bj: "北交所"
        }
    }

    /// 本 App 能否为这个市场的标的建立身份。北交所在 `Market` 里没有对应值。
    public var supportsSymbolIdentity: Bool { self == .shSz }
}

/// 一条发行记录。
public struct FuyaoIPOEntry: Codable, Hashable, Sendable, Identifiable {
    /// 发行股票的标准代码（`.SH` / `.SZ` / `.BJ`），未确定时为 nil。
    public let thscode: String?
    /// 上市后的交易代码。
    public let ticker: String
    public let name: String
    /// 打新时输入的申购代码。可以与 `ticker` 不同。
    public let subscriptionCode: String?
    /// 申购日（北京日历日零点）。未定时为 nil。
    public let subscriptionDate: Date?
    /// 上市日。未定时为 nil。
    public let listingDate: Date?
    /// 发行价（元）。未定时为 nil。
    public let issuePrice: Double?
    public let market: FuyaoIPOMarket
    public let stage: FuyaoIPOStage

    /// 身份用完整代码；缺失时退回 ticker + 阶段，避免两次请求的同名条目互相覆盖。
    public var id: String { "\(thscode ?? ticker)|\(stage.rawValue)|\(market.rawValue)" }

    /// 本 App 的沪深身份。京市与缺代码的行没有身份，与 `FuyaoConstituent` 的处理一致。
    public var symbol: SymbolID? {
        guard let thscode else { return nil }
        return FuyaoConstituent(thscode: thscode, name: name).symbol
    }

    public init(thscode: String?, ticker: String, name: String, subscriptionCode: String?,
                subscriptionDate: Date?, listingDate: Date?, issuePrice: Double?,
                market: FuyaoIPOMarket, stage: FuyaoIPOStage) {
        self.thscode = thscode
        self.ticker = ticker
        self.name = name
        self.subscriptionCode = subscriptionCode
        self.subscriptionDate = subscriptionDate
        self.listingDate = listingDate
        self.issuePrice = issuePrice
        self.market = market
        self.stage = stage
    }

    /// 申购代码是否与交易代码不同——不同时界面必须两列都显示。
    public var hasDistinctSubscriptionCode: Bool {
        guard let subscriptionCode, !subscriptionCode.isEmpty else { return false }
        return subscriptionCode != ticker
    }
}

/// 一次查询的结果（一个市场 × 一个阶段）。
public struct FuyaoIPOList: Codable, Hashable, Sendable {
    public let market: FuyaoIPOMarket
    public let stage: FuyaoIPOStage
    public let entries: [FuyaoIPOEntry]
    public let fetchedAt: Date
    public let error: String?

    public init(market: FuyaoIPOMarket, stage: FuyaoIPOStage, entries: [FuyaoIPOEntry],
                fetchedAt: Date, error: String? = nil) {
        self.market = market
        self.stage = stage
        self.entries = entries
        self.fetchedAt = fetchedAt
        self.error = error
    }
}

/// 六个查询合并后的日历。
public struct FuyaoIPOCalendar: Sendable {
    public let lists: [FuyaoIPOList]
    public let fetchedAt: Date

    public init(lists: [FuyaoIPOList], fetchedAt: Date) {
        self.lists = lists
        self.fetchedAt = fetchedAt
    }

    /// 所有条目，按阶段、申购日排序。同一条目可能在不同阶段重复出现，按 id 去重。
    public var entries: [FuyaoIPOEntry] {
        var seen: Set<String> = []
        return lists
            .flatMap(\.entries)
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.stage.sortOrder != rhs.stage.sortOrder {
                    return lhs.stage.sortOrder < rhs.stage.sortOrder
                }
                switch (lhs.subscriptionDate, rhs.subscriptionDate) {
                case let (left?, right?) where left != right: return left < right
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.ticker < rhs.ticker
                }
            }
    }

    public func entries(stage: FuyaoIPOStage) -> [FuyaoIPOEntry] {
        entries.filter { $0.stage == stage }
    }

    /// 各阶段的失败信息。部分失败保留成功项。
    public var errors: [FuyaoIPOStage: String] {
        var result: [FuyaoIPOStage: String] = [:]
        for list in lists where list.error != nil {
            result[list.stage] = list.error
        }
        return result
    }

    public var hasData: Bool { !entries.isEmpty }

    /// 是否有任何查询成功过（用于区分"真没有"与"全失败"）。
    public var anySucceeded: Bool { lists.contains { $0.error == nil } }
}

/// 展示格式。
public enum FuyaoIPOFormat {
    /// 日期未知就是未知，不显示空串或今天。
    public static func day(_ date: Date?) -> String {
        guard let date else { return "待定" }
        return ResearchFormatDay.string(from: date)
    }

    /// 发行价未定写"待定"，定了就按元显示。
    public static func price(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "待定" }
        return String(format: "%.2f 元", value)
    }
}

/// 北京日历日的 `yyyy-MM-dd` 文本，避免视图层各自实现一遍。
enum ResearchFormatDay {
    static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
