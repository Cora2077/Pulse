import Foundation

extension FuyaoProvider {
    public func financialStatement(_ kind: FuyaoStatementKind, for symbol: SymbolID) async throws -> FuyaoTimed<[FuyaoFinancialPeriod]> {
        guard let code = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        let data = try await fetchResearchData(path: "/api/a-share/financials/" + kind.rawValue, query: [
            .init(name: "thscode", value: code), .init(name: "period", value: "quarterly"), .init(name: "limit", value: "8")
        ])
        try Task.checkCancellation()
        return try Self.parseFinancialStatement(data: data, thscode: code, asOf: .now)
    }
    public func valuation(for symbol: SymbolID) async throws -> FuyaoTimed<FuyaoValuation?> {
        guard let code = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        let data = try await fetchResearchData(path: "/api/a-share/valuations/snapshot", query: [.init(name: "thscodes", value: code)])
        try Task.checkCancellation()
        return try Self.parseValuation(data: data, thscode: code, fetchedAt: .now)
    }
    static func parseFinancialStatement(data: Data, thscode: String, asOf: Date) throws -> FuyaoTimed<[FuyaoFinancialPeriod]> {
        let payload = try decodePayload(FinancialPayload.self, from: data, endpoint: "financial-statements")
        var byPeriod: [Date: FuyaoFinancialPeriod] = [:]
        for row in payload.item ?? [] {
            guard row.thscode == thscode, let year = row.fiscalYear, let period = row.fiscalPeriod,
                  let end = millisecondDate(row.periodEndMs), end <= asOf else { continue }
            let disclosed = millisecondDate(row.reportDateMs)
            if let disclosed, disclosed > asOf { continue }
            let fields: [(String, Double?)] = [
                ("revenue", row.operatingIncome), ("parentProfit", row.parentHolderNetProfit), ("netProfit", row.netProfit),
                ("eps", row.basicEps), ("operatingCashFlow", row.actCashFlowNet), ("receivables", row.accountsReceivable),
                ("assets", row.assetsTotal), ("liabilities", row.totalDebt)
            ]
            var values: [String: Double] = [:]
            for (key, value) in fields { if let value, value.isFinite { values[key] = value } }
            let candidate = FuyaoFinancialPeriod(fiscalYear: year, fiscalPeriod: period, periodEnd: end,
                disclosedAt: disclosed, currency: row.currency, values: values)
            // Keep the latest disclosed revision returned by this query.
            if let old = byPeriod[end], (old.disclosedAt ?? .distantPast) > (disclosed ?? .distantPast) { continue }
            byPeriod[end] = candidate
        }
        let rows = byPeriod.values.sorted { $0.periodEnd > $1.periodEnd }
        // Payload timestamp is a report period end, not a live update clock.
        return .init(value: rows, dataTime: rows.first?.periodEnd, fetchedAt: asOf)
    }
    static func parseValuation(data: Data, thscode: String, fetchedAt: Date) throws -> FuyaoTimed<FuyaoValuation?> {
        let payload = try decodePayload(ValuationPayload.self, from: data, endpoint: "valuations")
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        let value = payload.item?.first(where: { $0.thscode == thscode }).map {
            FuyaoValuation(thscode: $0.thscode, peTTM: finite($0.peTtm), peMRQ: finite($0.peMrq),
                pbMRQ: finite($0.pbMrq), psTTM: finite($0.psTtm), pcfTTM: finite($0.pcfTtm))
        }
        return .init(value: value, dataTime: millisecondDate(payload.timestamp), fetchedAt: fetchedAt)
    }
    private struct FinancialPayload: Decodable { let item: [FinancialRow]? }
    private struct FinancialRow: Decodable {
        let thscode: String?; let fiscalYear: Int?; let fiscalPeriod: String?
        let periodEndMs: Double?; let reportDateMs: Double?; let currency: String?
        let operatingIncome: Double?; let parentHolderNetProfit: Double?; let netProfit: Double?; let basicEps: Double?
        let actCashFlowNet: Double?; let accountsReceivable: Double?; let assetsTotal: Double?; let totalDebt: Double?
    }
    private struct ValuationPayload: Decodable { let timestamp: Double?; let item: [ValuationRow]? }
    private struct ValuationRow: Decodable {
        let thscode: String; let peTtm: Double?; let peMrq: Double?; let pbMrq: Double?; let psTtm: Double?; let pcfTtm: Double?
    }
}
