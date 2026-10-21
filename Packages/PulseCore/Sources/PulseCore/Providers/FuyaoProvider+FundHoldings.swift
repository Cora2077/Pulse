import Foundation

extension FuyaoProvider {
    #if DEBUG
    /// Public market fixtures only, for explicit local API-contract acceptance.
    public func debugFundContract(for symbol: SymbolID) async throws -> String {
        guard let code = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        let raw = try await fetchResearchData(path: "/api/fund/portfolio/stock-report-dates", query: [.init(name: "thscode", value: code)])
        let reportText = String(decoding: raw, as: UTF8.self)
        let parsed = try? Self.parseFundReports(data: raw, fetchedAt: .now)
        guard let report = parsed.flatMap({ Self.latestFundReport($0.value, asOf: .now) }) else { return "reports=" + reportText }
        let holdings = try await fetchResearchData(path: "/api/fund/portfolio/stock-history", query: [
            .init(name: "thscode", value: code), .init(name: "report_type", value: report.reportType),
            .init(name: "end_date", value: Self.beijingDayString(report.endDate))
        ])
        return "reports=" + reportText + "\nholdings=" + String(decoding: holdings, as: UTF8.self)
    }
    #endif
    public func fundReports(for symbol: SymbolID) async throws -> FuyaoTimed<[FuyaoFundReport]> {
        guard let code = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        let data = try await fetchResearchData(path: "/api/fund/portfolio/stock-report-dates", query: [.init(name: "thscode", value: code)])
        try Task.checkCancellation()
        return try Self.parseFundReports(data: data, fetchedAt: .now)
    }
    public func fundHoldings(for symbol: SymbolID, report: FuyaoFundReport) async throws -> FuyaoFundHoldings {
        guard let code = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        let data = try await fetchResearchData(path: "/api/fund/portfolio/stock-history", query: [
            .init(name: "thscode", value: code), .init(name: "report_type", value: report.reportType),
            .init(name: "end_date", value: Self.beijingDayString(report.endDate))
        ])
        try Task.checkCancellation()
        let parsed = try Self.parseFundHoldings(data: data, fund: symbol, report: report, fetchedAt: .now)
        var rows: [FuyaoFundHolding] = []
        for row in parsed.holdings {
            try Task.checkCancellation()
            var code = row.thscode
            if Self.isBareFundStockCode(code) {
                let cacheKey = code + "|" + row.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let cached = fundHoldingCodeCache[cacheKey], Date.now.timeIntervalSince(cached.resolvedAt) < 86_400 {
                    code = cached.code
                } else {
                    do {
                        let raw = try await fetchResearchData(path: "/api/meta/tickers/search", query: [
                            .init(name: "q", value: code), .init(name: "asset_type", value: "a-share"), .init(name: "limit", value: "20")
                        ])
                        let full = try Self.parseFundStockCode(data: raw, ticker: code, name: row.name)
                        if let full { fundHoldingCodeCache[cacheKey] = (full, .now); code = full }
                    } catch {
                        try Task.checkCancellation()
                        // Unverified identities stay bare and cannot merge with
                        // direct positions. Do not infer an exchange by prefix.
                        if Self.isQuotaRefusal(error) {
                            rows.append(row)
                            let remaining = Array(parsed.holdings.dropFirst(rows.count))
                            rows.append(contentsOf: remaining)
                            return .init(fund: symbol, report: report, holdings: rows, fetchedAt: parsed.fetchedAt)
                        }
                    }
                }
            }
            rows.append(.init(thscode: code, name: row.name, weightPercent: row.weightPercent, reportEnd: row.reportEnd, rank: row.rank))
        }
        return .init(fund: symbol, report: report, holdings: rows, fetchedAt: parsed.fetchedAt)
    }
    /// `asOf` excludes future report periods only. This endpoint returns
    /// currently available disclosure, not a historical point-in-time dataset.
    public func latestFundHoldings(for symbol: SymbolID, asOf: Date = .now) async throws -> FuyaoFundHoldings {
        let reports = try await fundReports(for: symbol)
        guard let report = Self.latestFundReport(reports.value, asOf: asOf) else {
            throw ProviderError.clientError(status: 404, detail: "fuyao: no disclosed stock report")
        }
        return try await fundHoldings(for: symbol, report: report)
    }
    static func latestFundReport(_ reports: [FuyaoFundReport], asOf: Date) -> FuyaoFundReport? {
        reports.filter { $0.endDate <= asOf }.sorted {
            if $0.endDate != $1.endDate { return $0.endDate > $1.endDate }
            func priority(_ type: String) -> Int {
                switch type.lowercased() { case "annual", "year": 0; case "half", "semi", "semiannual", "half-year": 1; case "quarter": 2; default: 3 }
            }
            let a = priority($0.reportType), b = priority($1.reportType)
            return a == b ? $0.reportType < $1.reportType : a < b
        }.first
    }
    static func parseFundReports(data: Data, fetchedAt: Date) throws -> FuyaoTimed<[FuyaoFundReport]> {
        let payload = try decodePayload(FundReportPayload.self, from: data, endpoint: "fund-report-dates")
        var seen: Set<String> = []
        let rows = (payload.item ?? []).compactMap { row -> FuyaoFundReport? in
            guard let type = row.reportType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty,
                  let end = millisecondDate(row.endDateMs), seen.insert(type + beijingDayString(end)).inserted else { return nil }
            return FuyaoFundReport(reportType: type, reportTypeName: row.reportTypeName, endDate: end)
        }.sorted { $0.endDate > $1.endDate }
        return .init(value: rows, dataTime: millisecondDate(payload.timestamp), fetchedAt: fetchedAt)
    }
    static func parseFundHoldings(data: Data, fund: SymbolID, report: FuyaoFundReport, fetchedAt: Date) throws -> FuyaoFundHoldings {
        let payload = try decodePayload(FundHoldingPayload.self, from: data, endpoint: "fund-stock-history")
        var seen: Set<String> = []
        let rows = (payload.item ?? []).compactMap { row -> FuyaoFundHolding? in
            guard row.assetType == "stock", let raw = row.thscode else { return nil }
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !code.isEmpty, code.count <= 40, !code.contains(","),
                  !code.contains(where: { $0.isWhitespace }) else { return nil }
            // The deployed fund endpoint returns the report type's display
            // name (e.g. 季度), while the catalog returns quarter + 季度.
            if let type = row.reportType, type != report.reportType, type != report.reportTypeName { return nil }
            if let rawEnd = row.endDateMs {
                guard let end = millisecondDate(rawEnd), beijingDayString(end) == beijingDayString(report.endDate) else { return nil }
            }
            guard seen.insert(code).inserted else { return nil }
            let weight = row.holdRatio.flatMap { $0.isFinite && $0 >= 0 && $0 <= 100 ? $0 : nil }
            return .init(thscode: code, name: row.name ?? code, weightPercent: weight, reportEnd: report.endDate,
                rank: row.rank.flatMap { $0 > 0 ? $0 : nil })
        }
        return .init(fund: fund, report: report, holdings: rows, fetchedAt: fetchedAt)
    }
    private struct FundReportPayload: Decodable {
        let timestamp: Double?
        let item: [FundReportRow]?
    }
    static func isBareFundStockCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func parseFundStockCode(data: Data, ticker: String, name: String) throws -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ticker else { return nil }
        let payload = try decodePayload(SearchPayload.self, from: data, endpoint: "fund-stock-identity")
        let codes = Set((payload.item ?? []).filter {
            $0.assetType == AssetKind.aShare.rawValue && $0.thscode.split(separator: ".").first.map(String.init) == ticker
                && Self.isConstituentThscode($0.thscode)
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name
        }.map(\.thscode))
        return codes.count == 1 ? codes.first : nil
    }
    private struct FundReportRow: Decodable {
        let reportType: String?
        let reportTypeName: String?
        let endDateMs: Double?
    }
    private struct FundHoldingPayload: Decodable { let item: [FundHoldingRow]? }
    private struct FundHoldingRow: Decodable {
        let thscode: String?
        let name: String?
        let assetType: String?
        let holdRatio: Double?
        let rank: Int?
        let reportType: String?
        let endDateMs: Double?
    }
}
