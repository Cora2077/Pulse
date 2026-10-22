import Foundation

// 龙虎榜与异动监控的网络层。两者都走 `fetchResearchData`（共用凭据与节流）。
//
// 解析的防御重点不是"字段缺失"，而是**重复行与可空身份**：
// 同一股票会同时有当日榜与三日榜两行，`thscode` 也可能是 null。

extension FuyaoProvider {
    /// 一个交易日的龙虎榜。
    ///
    /// - Parameter date: `yyyy-MM-dd`，必须是一年内的**交易日**。省略时由上游取
    ///   上一个交易日——那个日期只能从响应的 `trade_date` 读回来，本地算不出。
    /// - Note: 显式传非交易日会得到 `code=1002`，这里不做回退，也不猜。
    public func dragonTiger(
        board: FuyaoDragonTigerBoard = .all,
        date: Date? = nil
    ) async throws -> FuyaoDragonTigerDay {
        var query: [URLQueryItem] = [.init(name: "board_type", value: board.rawValue)]
        if let date { query.append(.init(name: "date", value: Self.beijingDayString(date))) }
        let data = try await fetchResearchData(path: Self.dragonTigerPath, query: query)
        try Task.checkCancellation()
        return try Self.parseDragonTiger(data: data, requestedBoard: board, fetchedAt: .now)
    }

    /// 个股机构交易详情：同一股票的一日榜与三日榜分别保留（最多两条）。
    public func dragonTigerInstitution(
        for symbol: SymbolID,
        date: Date? = nil,
        rangeDays: Int? = nil
    ) async throws -> [FuyaoDragonTigerInstitutionRecord] {
        guard let thscode = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        var query: [URLQueryItem] = [.init(name: "thscode", value: thscode)]
        if let date { query.append(.init(name: "date", value: Self.beijingDayString(date))) }
        if let rangeDays { query.append(.init(name: "range_days", value: String(rangeDays))) }
        let data = try await fetchResearchData(path: Self.dragonTigerInstitutionPath, query: query)
        try Task.checkCancellation()
        return try Self.parseDragonTigerInstitution(data: data, thscode: thscode)
    }

    /// 当前或历史的严重异动 / 重点监控记录。
    public func abnormalMonitors(
        state: FuyaoAbnormalMonitorState = .current,
        page: Int = 1
    ) async throws -> FuyaoAbnormalMonitorPage {
        guard page >= 1 else { throw ProviderError.clientError(status: 400, detail: "fuyao: invalid monitor page") }
        let data = try await fetchResearchData(path: Self.abnormalMonitorPath, query: [
            .init(name: "state", value: state.rawValue),
            .init(name: "page", value: String(page)),
            .init(name: "size", value: "30"),
        ])
        try Task.checkCancellation()
        return try Self.parseAbnormalMonitors(data: data, page: page, fetchedAt: .now)
    }

    // MARK: - 解析

    static func parseDragonTiger(
        data: Data,
        requestedBoard: FuyaoDragonTigerBoard,
        fetchedAt: Date
    ) throws -> FuyaoDragonTigerDay {
        let payload = try decodePayload(DragonTigerPayload.self, from: data, endpoint: "dragon-tiger-list")
        guard let tradeDate = beijingDay(of: payload.tradeDate) else {
            throw ProviderError.badResponse("fuyao dragon-tiger: missing trade_date")
        }
        let stocks = (payload.stockItems ?? []).compactMap { row -> FuyaoDragonTigerRow? in
            // `ticker` 是唯一不可缺的身份碎片；连它都没有的行无法归到任何股票。
            guard let ticker = row.ticker?.trimmedNonEmpty else { return nil }
            let thscode = row.thscode?.trimmedNonEmpty.map { $0.uppercased() }
            // 区间缺失时保留为 0 会与"当日榜"混淆，这里用 -1 表示未知，
            // 让 `range` 计算属性返回 nil，界面据"区间未知"单独列出。
            let range = row.rangeDays ?? -1
            guard let name = row.name?.trimmedNonEmpty ?? row.name else { return nil }
            return FuyaoDragonTigerRow(
                thscode: thscode,
                ticker: ticker,
                name: name.isEmpty ? ticker : name,
                rangeDays: range,
                changeFraction: finite(row.change),
                netValue: finite(row.netValue),
                netRate: finite(row.netRate),
                buyValue: finite(row.buyValue),
                sellValue: finite(row.sellValue),
                amount: finite(row.amount),
                orgNetValue: finite(row.orgNetValue),
                orgNetRate: finite(row.orgNetRate),
                orgBuyCount: count(row.orgBuyNum),
                orgSellCount: count(row.orgSellNum),
                hotRank: count(row.hotRank),
                limitReason: row.limitReason?.trimmedNonEmpty,
                concepts: (row.conceptList ?? []).compactMap { $0.name?.trimmedNonEmpty }
            )
        }
        // 同一 (身份, 区间) 只保留第一条：上游可能重复返回同一记录。
        var seen: Set<String> = []
        let uniqueStocks = stocks.filter { seen.insert($0.id).inserted }

        let hotMoney = (payload.hotMoneyItems ?? []).compactMap { item -> FuyaoHotMoney? in
            guard let name = item.name?.trimmedNonEmpty else { return nil }
            let rows = (item.rows ?? []).compactMap { row -> FuyaoDragonTigerRow? in
                guard let ticker = row.ticker?.trimmedNonEmpty else { return nil }
                let range = row.rangeDays ?? -1
                return FuyaoDragonTigerRow(
                    thscode: row.thscode?.trimmedNonEmpty?.uppercased(),
                    ticker: ticker,
                    name: row.name?.trimmedNonEmpty ?? ticker,
                    rangeDays: range,
                    changeFraction: finite(row.change),
                    netValue: finite(row.netValue),
                    netRate: finite(row.netRate),
                    buyValue: finite(row.buyValue),
                    sellValue: finite(row.sellValue),
                    amount: finite(row.amount),
                    hotRank: count(row.hotRank),
                    limitReason: row.limitReason?.trimmedNonEmpty,
                    concepts: (row.conceptList ?? []).compactMap { $0.name?.trimmedNonEmpty }
                )
            }
            return FuyaoHotMoney(name: name, buying: finite(item.buying), rows: rows)
        }.sorted { ($0.buying ?? 0) > ($1.buying ?? 0) }

        // 上游回显的 board_type 优先于请求值：它说的是这份数据实际是什么榜。
        let board = payload.boardType.flatMap(FuyaoDragonTigerBoard.init(rawValue:)) ?? requestedBoard
        return FuyaoDragonTigerDay(
            boardType: board,
            tradeDate: tradeDate,
            dataTime: millisecondDate(payload.timestamp),
            stockRows: uniqueStocks.sorted { ($0.netValue ?? 0) > ($1.netValue ?? 0) },
            hotMoneyRows: hotMoney,
            recordCount: count(payload.count),
            stockCount: count(payload.stockCount),
            fetchedAt: fetchedAt
        )
    }

    static func parseDragonTigerInstitution(
        data: Data,
        thscode: String
    ) throws -> [FuyaoDragonTigerInstitutionRecord] {
        let payload = try decodePayload(InstitutionPayload.self, from: data, endpoint: "dragon-tiger-institution")
        if let echoed = payload.thscode?.trimmedNonEmpty,
           echoed.uppercased() != thscode.uppercased() {
            throw ProviderError.badResponse(
                "fuyao dragon-tiger-institution: echoed \(echoed) for \(thscode)")
        }
        return (payload.item ?? []).compactMap { row in
            guard let range = row.rangeDays else { return nil }
            return FuyaoDragonTigerInstitutionRecord(
                rangeDays: range,
                startDate: beijingDay(of: row.startDate),
                endDate: beijingDay(of: row.endDate),
                orgBuyValue: finite(row.orgBuyValue),
                orgSellValue: finite(row.orgSellValue),
                orgNetValue: finite(row.orgNetValue),
                orgBuyCount: count(row.orgBuyNum),
                orgSellCount: count(row.orgSellNum),
                orgNetRate: finite(row.orgNetRate),
                // 席位数组是"条数"语义，同一 department_id 可以出现多次；
                // 这里保留重复，只在展示时按名称聚合，绝不在此去重。
                buySeats: (row.buyDepartments ?? []).compactMap { Self.seat($0) },
                sellSeats: (row.sellDepartments ?? []).compactMap { Self.seat($0) }
            )
        }
    }

    private static func seat(_ raw: SeatRow) -> FuyaoDragonTigerSeat? {
        guard let id = raw.departmentId?.trimmedNonEmpty else { return nil }
        return FuyaoDragonTigerSeat(departmentID: id, name: raw.name?.trimmedNonEmpty)
    }

    static func parseAbnormalMonitors(
        data: Data,
        page: Int,
        fetchedAt: Date
    ) throws -> FuyaoAbnormalMonitorPage {
        let payload = try decodePayload(MonitorPayload.self, from: data, endpoint: "abnormal-monitor-list")
        let records = (payload.item ?? []).compactMap { row -> FuyaoAbnormalMonitor? in
            guard let start = millisecondDate(row.startDateMs) else { return nil }
            let startDay = beijingDay(of: beijingDayString(start)) ?? start
            let endDay = millisecondDate(row.endDateMs).flatMap { beijingDay(of: beijingDayString($0)) }
            return FuyaoAbnormalMonitor(
                thscode: row.thscode?.trimmedNonEmpty?.uppercased(),
                name: row.name?.trimmedNonEmpty,
                startDate: startDay,
                endDate: endDay,
                monitorType: row.monitorType,
                label: row.monitorLabel?.trimmedNonEmpty ?? "未标注"
            )
        }
        let pagination = payload.pagination
        return FuyaoAbnormalMonitorPage(
            records: records,
            page: pagination?.page ?? page,
            size: pagination?.size ?? 30,
            total: count(pagination?.total),
            hasNext: pagination?.hasNext ?? false,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - 数值清洗

    /// 非有限值不是数据，按缺失处理；负数照原样保留（净卖出是真实方向）。
    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func count(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    // MARK: - 线格式

    static let dragonTigerPath = "/api/a-share/special-data/dragon-tiger-list"
    static let dragonTigerInstitutionPath = "/api/a-share/special-data/dragon-tiger-stock-institution"
    static let abnormalMonitorPath = "/api/a-share/special-data/abnormal-monitor-list"

    struct DragonTigerPayload: Decodable {
        let timestamp: Double?
        let boardType: String?
        let tradeDate: String?
        let count: Int?
        let stockCount: Int?
        let stockItems: [DragonTigerRowDTO]?
        let hotMoneyItems: [HotMoneyDTO]?
    }

    struct DragonTigerRowDTO: Decodable {
        let thscode: String?
        let ticker: String?
        let name: String?
        let change: Double?
        let netValue: Double?
        let netRate: Double?
        let buyValue: Double?
        let sellValue: Double?
        let amount: Double?
        let orgNetValue: Double?
        let orgNetRate: Double?
        let orgBuyNum: Int?
        let orgSellNum: Int?
        let hotRank: Int?
        let limitReason: String?
        let conceptList: [ConceptDTO]?
        let rangeDays: Int?
    }

    struct ConceptDTO: Decodable { let name: String? }

    struct HotMoneyDTO: Decodable {
        let name: String?
        let buying: Double?
        let rows: [DragonTigerRowDTO]?
    }

    struct InstitutionPayload: Decodable {
        let thscode: String?
        let tradeDate: String?
        let item: [InstitutionRowDTO]?
    }

    struct InstitutionRowDTO: Decodable {
        let rangeDays: Int?
        let startDate: String?
        let endDate: String?
        let orgBuyValue: Double?
        let orgSellValue: Double?
        let orgNetValue: Double?
        let orgBuyNum: Int?
        let orgSellNum: Int?
        let orgNetRate: Double?
        let buyDepartments: [SeatRow]?
        let sellDepartments: [SeatRow]?
    }

    struct SeatRow: Decodable {
        let departmentId: String?
        let name: String?
    }

    struct MonitorPayload: Decodable {
        let item: [MonitorRowDTO]?
        let pagination: MonitorPaginationDTO?
    }

    struct MonitorRowDTO: Decodable {
        let thscode: String?
        let name: String?
        let startDateMs: Double?
        let endDateMs: Double?
        let monitorType: Int?
        let monitorLabel: String?
    }

    struct MonitorPaginationDTO: Decodable {
        let page: Int?
        let size: Int?
        let total: Int?
        let hasNext: Bool?
    }
}

/// 异动监控的查询状态。
public enum FuyaoAbnormalMonitorState: String, Codable, Sendable {
    case current
    case history
}

/// 个股机构交易详情的一条记录（一日榜或三日榜，最多两条）。
public struct FuyaoDragonTigerInstitutionRecord: Codable, Hashable, Sendable, Identifiable {
    public let rangeDays: Int
    public let startDate: Date?
    public let endDate: Date?
    public let orgBuyValue: Double?
    public let orgSellValue: Double?
    public let orgNetValue: Double?
    public let orgBuyCount: Int?
    public let orgSellCount: Int?
    /// 小数占比。
    public let orgNetRate: Double?
    /// 买入席位。**同一 `departmentID` 可以重复出现**，代表该席位占了几条；
    /// 这是"条数"语义，不是集合语义。
    public let buySeats: [FuyaoDragonTigerSeat]
    public let sellSeats: [FuyaoDragonTigerSeat]

    public var id: Int { rangeDays }

    public var range: FuyaoDragonTigerRange? { FuyaoDragonTigerRange(rawValue: rangeDays) }

    public init(rangeDays: Int, startDate: Date?, endDate: Date?,
                orgBuyValue: Double?, orgSellValue: Double?, orgNetValue: Double?,
                orgBuyCount: Int?, orgSellCount: Int?, orgNetRate: Double?,
                buySeats: [FuyaoDragonTigerSeat], sellSeats: [FuyaoDragonTigerSeat]) {
        self.rangeDays = rangeDays
        self.startDate = startDate
        self.endDate = endDate
        self.orgBuyValue = orgBuyValue
        self.orgSellValue = orgSellValue
        self.orgNetValue = orgNetValue
        self.orgBuyCount = orgBuyCount
        self.orgSellCount = orgSellCount
        self.orgNetRate = orgNetRate
        self.buySeats = buySeats
        self.sellSeats = sellSeats
    }

    /// 按席位身份聚合，保留出现次数。界面用这个结果，但**不把它当成"不同营业部数"**。
    public func groupedSeats(_ seats: [FuyaoDragonTigerSeat]) -> [(seat: FuyaoDragonTigerSeat, appearances: Int)] {
        var order: [String] = []
        var counts: [String: (FuyaoDragonTigerSeat, Int)] = [:]
        for seat in seats {
            if counts[seat.departmentID] == nil { order.append(seat.departmentID) }
            let existing = counts[seat.departmentID]?.1 ?? 0
            counts[seat.departmentID] = (seat, existing + 1)
        }
        return order.compactMap { id in counts[id].map { (seat: $0.0, appearances: $0.1) } }
    }
}

public struct FuyaoDragonTigerSeat: Codable, Hashable, Sendable, Identifiable {
    public let departmentID: String
    public let name: String?
    public var id: String { departmentID }

    public init(departmentID: String, name: String?) {
        self.departmentID = departmentID
        self.name = name
    }

    public var displayName: String { name ?? departmentID }
}

private extension String {
    /// 去掉首尾空白后的非空文本；空白即缺失。
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
