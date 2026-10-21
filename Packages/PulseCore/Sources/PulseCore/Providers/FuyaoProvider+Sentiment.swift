import Foundation

extension FuyaoProvider {
    public func marketStatistics(date: Date? = nil) async throws -> FuyaoTimed<FuyaoMarketStatistics> {
        let query: [URLQueryItem] = date.map { [.init(name: "date", value: Self.beijingDayString($0))] } ?? []
        let data = try await fetchResearchData(path: "/api/a-share/special-data/limit-up-statistics", query: query)
        try Task.checkCancellation()
        return try Self.parseMarketStatistics(data: data, fetchedAt: .now)
    }
    public func limitPool(_ kind: FuyaoLimitKind, tradeDate: Date, page: Int = 1) async throws -> FuyaoTimed<FuyaoLimitPool> {
        guard page >= 1 else { throw ProviderError.clientError(status: 400, detail: "fuyao: invalid pool page") }
        let date = Self.beijingDay(of: Self.beijingDayString(tradeDate))!
        let data = try await fetchResearchData(path: "/api/a-share/special-data/" + kind.rawValue, query: [
            .init(name: "date_ms", value: String(Int64(date.timeIntervalSince1970 * 1000))),
            .init(name: "page", value: String(page)), .init(name: "size", value: "200")
        ])
        try Task.checkCancellation()
        return try Self.parseLimitPool(data: data, kind: kind, tradeDate: date, page: page, fetchedAt: .now)
    }
    static func parseMarketStatistics(data: Data, fetchedAt: Date) throws -> FuyaoTimed<FuyaoMarketStatistics> {
        let payload = try decodePayload(MarketStatisticsDTO.self, from: data, endpoint: "market-statistics")
        guard let date = beijingDay(of: payload.tradeDate) else { throw ProviderError.badResponse("fuyao: missing market trade date") }
        func count(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
        let rate = payload.sealRate.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        var seen: Set<Int> = []
        let tiers = (payload.exactBoards ?? []).compactMap { row -> FuyaoMarketStatistics.Tier? in
            guard let board = row.boardNum, board >= 2, let value = count(row.stockCount), seen.insert(board).inserted else { return nil }
            return .init(boardNumber: board, count: value)
        }.sorted { $0.boardNumber > $1.boardNumber }
        let time = millisecondDate(payload.timestamp)
        let stats = FuyaoMarketStatistics(tradeDate: date, dataTime: time, limitUp: count(payload.limitUpStockCount),
            opened: count(payload.openStockCount), touched: count(payload.touchedLimitUpStockCount), sealRate: rate, tiers: tiers)
        return .init(value: stats, dataTime: time, fetchedAt: fetchedAt)
    }
    static func parseLimitPool(data: Data, kind: FuyaoLimitKind, tradeDate: Date, page: Int, fetchedAt: Date) throws -> FuyaoTimed<FuyaoLimitPool> {
        let payload = try decodePayload(LimitPoolDTO.self, from: data, endpoint: kind.rawValue)
        if let responsePage = payload.pagination?.page, responsePage != page { throw ProviderError.badResponse("fuyao: pool page mismatch") }
        var seen: Set<String> = []
        let rows = (payload.item ?? []).compactMap { row -> FuyaoLimitStock? in
            guard let code = row.thscode, Self.isConstituentThscode(code), seen.insert(code).inserted else { return nil }
            return .init(thscode: code, name: row.name ?? code,
                changePercent: row.priceChangeRatioPct.flatMap { $0.isFinite ? $0 : nil },
                consecutiveDays: row.continueDayCnt.flatMap { $0 > 0 ? $0 : nil }, boardText: row.continueDayText, reason: row.limitUpReason)
        }
        let time = millisecondDate(payload.timestamp)
        let pool = FuyaoLimitPool(kind: kind, tradeDate: tradeDate, dataTime: time, stocks: rows,
            total: payload.pagination?.total.flatMap { $0 >= 0 ? $0 : nil }, page: page,
            pages: payload.pagination?.pages.flatMap { $0 >= 0 ? $0 : nil })
        return .init(value: pool, dataTime: time, fetchedAt: fetchedAt)
    }
    private struct MarketStatisticsDTO: Decodable {
        let timestamp: Double?
        let tradeDate: String?
        let sealRate: Double?
        let openStockCount: Int?
        let limitUpStockCount: Int?
        let touchedLimitUpStockCount: Int?
        let exactBoards: [TierDTO]?
    }
    private struct TierDTO: Decodable { let boardNum: Int?; let stockCount: Int? }
    private struct LimitPoolDTO: Decodable { let timestamp: Double?; let pagination: Pagination?; let item: [LimitStockDTO]? }
    private struct Pagination: Decodable { let total: Int?; let pages: Int?; let page: Int? }
    private struct LimitStockDTO: Decodable {
        let thscode: String?; let name: String?; let priceChangeRatioPct: Double?
        let continueDayCnt: Int?; let continueDayText: String?; let limitUpReason: String?
    }
}
