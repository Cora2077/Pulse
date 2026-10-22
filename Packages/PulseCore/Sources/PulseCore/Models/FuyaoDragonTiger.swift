import Foundation

// 龙虎榜与严重异动监控。两者都是"收盘后才知道的资金面与监管面"，
// 与本机的成交账本无关：这里只转述上游，不做因果解释。
//
// 三条实测约束（2026-10-20 只读样本）决定了下面每个字段的形状：
//
// 1. **同一股票会同时出现在当日榜与三日榜上**。样本里 `count=72`、`stock_count=67`，
//    `range_days` 分布 `{1: 55, 3: 17}`。任何按股票的汇总必须先按 `range_days`
//    分组，否则金额会被重复计入。
// 2. **`thscode` 可以是 null**。样本里有 4 行只有 `ticker` 与 `name`（例如退市股
//    `301139`），另有 6 行是 `.BJ`。所以身份是可选值，去重键要能退回 `ticker`。
// 3. **`count` 是上游记录数，不是股票数**。界面上"多少只股票"和"多少条记录"
//    是两个数字，不能互相顶替。

/// 龙虎榜的三种榜单。`hot_money` 时 `stock_items` 为空数组，数据全在
/// `hot_money_items` 里，反之亦然——所以两者是互斥的两张表，不是同一张表的不同列。
public enum FuyaoDragonTigerBoard: String, Codable, CaseIterable, Sendable, Identifiable {
    case all
    case org
    case hotMoney = "hot_money"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "全部"
        case .org: "机构榜"
        case .hotMoney: "游资榜"
        }
    }

    /// 哪些榜单填充股票维度表。
    public var fillsStockRows: Bool { self != .hotMoney }
}

/// 三日榜的区间天数标记。上游只用 1 与 3，但把它建模成有名字的常量而不是裸数字，
/// 是因为这两个值决定"能不能相加"这件事。
public enum FuyaoDragonTigerRange: Int, Codable, Sendable {
    case day = 1
    case threeDay = 3

    public var title: String {
        switch self {
        case .day: "当日榜"
        case .threeDay: "三日榜"
        }
    }

    /// 与另一区间能否直接相加：只有同区间才可以。
    public func isAdditive(with other: FuyaoDragonTigerRange) -> Bool { self == other }
}

/// 一条股票维度的龙虎榜记录。
public struct FuyaoDragonTigerRow: Codable, Hashable, Sendable, Identifiable {
    /// 可为 nil：上游有约 5% 的行只给 `ticker`。
    public let thscode: String?
    public let ticker: String
    public let name: String
    /// 上榜区间；1 = 当日榜，3 = 三日榜。未知值不折叠成 1。
    public let rangeDays: Int
    /// 当日涨跌幅，**小数**（`0.0999` = +9.99%）。
    public let changeFraction: Double?
    /// 龙虎榜净买入，元。负值是净卖出，不是缺失。
    public let netValue: Double?
    /// 净买入占比，**小数**。
    public let netRate: Double?
    public let buyValue: Double?
    public let sellValue: Double?
    public let amount: Double?
    public let orgNetValue: Double?
    public let orgNetRate: Double?
    public let orgBuyCount: Int?
    public let orgSellCount: Int?
    /// 同花顺人气排名，数值越小越靠前。
    public let hotRank: Int?
    public let limitReason: String?
    public let concepts: [String]

    /// 去重键：完整代码优先，缺失时退回 ticker；再与区间组合，
    /// 因为同一股票的当日榜与三日榜是两条**不同**的记录。
    public var id: String { "\(thscode ?? ticker)|\(rangeDays)" }

    /// 本 App 的沪深身份。`.BJ` 与缺代码的行没有身份，与 `FuyaoConstituent` 的
    /// 既有处理保持一致。
    public var symbol: SymbolID? {
        guard let thscode else { return nil }
        return FuyaoConstituent(thscode: thscode, name: name).symbol
    }

    /// 区间身份；不在已知集合里时为 nil（界面按"区间未知"展示，不猜成 1 日）。
    public var range: FuyaoDragonTigerRange? { FuyaoDragonTigerRange(rawValue: rangeDays) }

    public init(
        thscode: String?, ticker: String, name: String, rangeDays: Int,
        changeFraction: Double? = nil, netValue: Double? = nil, netRate: Double? = nil,
        buyValue: Double? = nil, sellValue: Double? = nil, amount: Double? = nil,
        orgNetValue: Double? = nil, orgNetRate: Double? = nil,
        orgBuyCount: Int? = nil, orgSellCount: Int? = nil,
        hotRank: Int? = nil, limitReason: String? = nil, concepts: [String] = []
    ) {
        self.thscode = thscode
        self.ticker = ticker
        self.name = name
        self.rangeDays = rangeDays
        self.changeFraction = changeFraction
        self.netValue = netValue
        self.netRate = netRate
        self.buyValue = buyValue
        self.sellValue = sellValue
        self.amount = amount
        self.orgNetValue = orgNetValue
        self.orgNetRate = orgNetRate
        self.orgBuyCount = orgBuyCount
        self.orgSellCount = orgSellCount
        self.hotRank = hotRank
        self.limitReason = limitReason
        self.concepts = concepts
    }
}

/// 游资维度的一行：一个游资名称下挂着的股票。
public struct FuyaoHotMoney: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    /// 聚合净买入，元。
    public let buying: Double?
    public let rows: [FuyaoDragonTigerRow]
    public var id: String { name }

    public init(name: String, buying: Double?, rows: [FuyaoDragonTigerRow]) {
        self.name = name
        self.buying = buying
        self.rows = rows
    }
}

/// 一个交易日的榜单。
public struct FuyaoDragonTigerDay: Codable, Hashable, Sendable {
    public let boardType: FuyaoDragonTigerBoard
    /// 业务日期，来自响应的 `trade_date`，**不由本地推算**：省略 `date` 时上游给的是
    /// 上一个交易日，本地算不出来。
    public let tradeDate: Date
    /// 上游就绪时间；缺失保持 nil。
    public let dataTime: Date?
    public let stockRows: [FuyaoDragonTigerRow]
    public let hotMoneyRows: [FuyaoHotMoney]
    /// 上游记录数（含同一股票的当日榜与三日榜各行）。
    public let recordCount: Int?
    /// 上游去重后的股票数。与 `recordCount` 不同是常态。
    public let stockCount: Int?
    public let fetchedAt: Date

    public init(
        boardType: FuyaoDragonTigerBoard, tradeDate: Date, dataTime: Date?,
        stockRows: [FuyaoDragonTigerRow], hotMoneyRows: [FuyaoHotMoney],
        recordCount: Int?, stockCount: Int?, fetchedAt: Date
    ) {
        self.boardType = boardType
        self.tradeDate = tradeDate
        self.dataTime = dataTime
        self.stockRows = stockRows
        self.hotMoneyRows = hotMoneyRows
        self.recordCount = recordCount
        self.stockCount = stockCount
        self.fetchedAt = fetchedAt
    }

    /// 按上榜区间分组。**这是唯一可以做金额汇总的分组方式**：
    /// 跨区间相加会把同一只票的两段区间金额叠成一份。
    public var rowsByRange: [FuyaoDragonTigerRange: [FuyaoDragonTigerRow]] {
        var result: [FuyaoDragonTigerRange: [FuyaoDragonTigerRow]] = [:]
        for row in stockRows {
            guard let range = row.range else { continue }
            result[range, default: []].append(row)
        }
        for key in result.keys {
            result[key]?.sort { ($0.netValue ?? 0) > ($1.netValue ?? 0) }
        }
        return result
    }

    /// 区间未知的行：既不参与分组汇总，也不被丢弃，单独列出来。
    public var rowsWithUnknownRange: [FuyaoDragonTigerRow] {
        stockRows.filter { $0.range == nil }
    }

    /// 命中给定身份的记录（当日榜与三日榜都会返回，调用方不要合并两者）。
    public func rows(for symbol: SymbolID) -> [FuyaoDragonTigerRow] {
        stockRows.filter { $0.symbol == symbol }
    }

    /// 机构净买入为正的前 `count` 行（同区间内）。
    public func topInstitutionalNet(count: Int, range: FuyaoDragonTigerRange) -> [FuyaoDragonTigerRow] {
        (rowsByRange[range] ?? [])
            .filter { ($0.orgNetValue ?? 0) > 0 }
            .sorted { ($0.orgNetValue ?? 0) > ($1.orgNetValue ?? 0) }
            .prefix(count)
            .map { $0 }
    }
}

// MARK: - 严重异动与重点监控

/// 一条当前或历史的监控记录。
public struct FuyaoAbnormalMonitor: Codable, Hashable, Sendable, Identifiable {
    /// 可为 nil：源里的空代码原样保留。
    public let thscode: String?
    public let name: String?
    /// 监控开始日（北京日历日零点）。
    public let startDate: Date
    /// 结束日；**nil 表示仍在监控中**，不是数据缺失。
    public let endDate: Date?
    /// 原始业务类型码。展示以 `label` 为准，不硬编码 1/2。
    public let monitorType: Int?
    public let label: String

    public var id: String { "\(thscode ?? name ?? "")|\(Int(startDate.timeIntervalSince1970))|\(monitorType ?? 0)" }

    public var isOngoing: Bool { endDate == nil }

    public var symbol: SymbolID? {
        guard let thscode else { return nil }
        return FuyaoConstituent(thscode: thscode, name: name ?? thscode).symbol
    }

    public init(thscode: String?, name: String?, startDate: Date, endDate: Date?,
                monitorType: Int?, label: String) {
        self.thscode = thscode
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.monitorType = monitorType
        self.label = label
    }
}

/// 一页监控记录。
public struct FuyaoAbnormalMonitorPage: Codable, Hashable, Sendable {
    public let records: [FuyaoAbnormalMonitor]
    public let page: Int
    public let size: Int
    public let total: Int?
    public let hasNext: Bool
    public let fetchedAt: Date

    public init(records: [FuyaoAbnormalMonitor], page: Int, size: Int,
                total: Int?, hasNext: Bool, fetchedAt: Date) {
        self.records = records
        self.page = page
        self.size = size
        self.total = total
        self.hasNext = hasNext
        self.fetchedAt = fetchedAt
    }

    /// 命中给定身份的记录。`endDate == nil`（监控中）的记录会保留。
    public func records(for symbol: SymbolID) -> [FuyaoAbnormalMonitor] {
        records.filter { $0.symbol == symbol }
    }

    /// 仍在监控中的记录。
    public var ongoing: [FuyaoAbnormalMonitor] { records.filter(\.isOngoing) }
}
