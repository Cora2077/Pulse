import Foundation

// 除权除息事件流。与其它研究能力一样，请求走 `fetchResearchData`：同一凭据、
// 同一条节流预算，并向在途报价让出时隙。
//
// 该端点每次只接受**一个** thscode（逗号不被接受），所以多标的必须串行补齐。

extension FuyaoProvider {
    /// 一只标的的除权除息事件序列。
    ///
    /// `from` / `to` 用 `YYYY-MM-DD`（北京日历日），都可省略；省略即由上游决定
    /// 范围。响应里的事件按 `ex_date_ms` 降序，本方法保持这一顺序。
    public func corporateActions(
        for symbol: SymbolID,
        from: Date? = nil,
        to: Date? = nil
    ) async throws -> FuyaoCorporateActionSeries {
        guard let thscode = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        // 只对普通股票有意义；指数与板块没有分红送转。这是请求层面的问题，
        // 不是来源故障，所以用 clientError（不会触发熔断）。
        guard symbol.indexID == nil, symbol.sectorIndex == nil else {
            throw ProviderError.clientError(status: 400, detail: "fuyao corporate-actions: not an equity")
        }
        var query: [URLQueryItem] = [.init(name: "thscode", value: thscode)]
        if let from { query.append(.init(name: "from", value: Self.beijingDayString(from))) }
        if let to { query.append(.init(name: "to", value: Self.beijingDayString(to))) }
        let data = try await fetchResearchData(path: Self.corporateActionsPath, query: query)
        try Task.checkCancellation()
        return try Self.parseCorporateActions(data: data, thscode: thscode, fetchedAt: .now)
    }

    // MARK: - 解析

    /// 解析事件流。重复的同日事件只留第一条；两个数值都为零的事件被丢弃
    /// （它们对价格没有影响）；无法确认日期或代码不匹配的行同样丢弃。
    static func parseCorporateActions(
        data: Data,
        thscode: String,
        fetchedAt: Date
    ) throws -> FuyaoCorporateActionSeries {
        let payload = try decodePayload(CorporateActionsPayload.self, from: data, endpoint: "corporate-actions")
        // 端点会把入参代码回显在 `data.thscode`。若两侧都有值且不一致，说明答案
        // 不是这一只标的的，整份拒收，而不是把别的票的分红记到这只票上。
        if let echoed = payload.thscode?.corporateActionText,
           echoed.uppercased() != thscode.uppercased() {
            throw ProviderError.badResponse(
                "fuyao corporate-actions: echoed \(echoed) for \(thscode)")
        }
        var seen: Set<Date> = []
        var actions: [FuyaoCorporateAction] = []
        for row in payload.item ?? [] {
            guard let exDate = millisecondDate(row.exDateMs) else { continue }
            // 事件日期必须落在北京日历日的零点；否则时区口径不清，宁可丢弃。
            let day = Self.beijingDay(of: Self.beijingDayString(exDate))
            guard let day, day == exDate else { continue }
            guard seen.insert(day).inserted else { continue }
            let action = FuyaoCorporateAction(
                thscode: thscode,
                exDate: day,
                cashPerShare: row.dividendPerShare,
                bonusPerShare: row.perShareBonus
            )
            guard action.isMeaningful else { continue }
            actions.append(action)
        }
        return FuyaoCorporateActionSeries(
            thscode: thscode,
            actions: actions,
            fetchedAt: fetchedAt,
            dataTime: millisecondDate(payload.timestamp)
        )
    }

    // MARK: - 线格式

    static let corporateActionsPath = "/api/a-share/corporate-actions/adjustment-factors"

    struct CorporateActionsPayload: Decodable {
        let thscode: String?
        let timestamp: Double?
        let item: [CorporateActionRow]?
    }

    struct CorporateActionRow: Decodable {
        let ticker: String?
        let exDateMs: Double?
        let dividendPerShare: Double?
        let perShareBonus: Double?
    }
}

private extension String {
    /// 去掉首尾空白后的非空文本；空白即缺失。
    var corporateActionText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
