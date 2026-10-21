import Foundation

// Per-stock intelligence on Fuyao: news, anomaly explanations, the A-share heat
// board and one stock's rank history. Every request rides `fetchResearchData`,
// so it uses the same credential and pacing as quotes; the models are plain
// values and caching is the caller's decision.
//
// Freshness is kept honest rather than convenient: a vendor time that is
// missing stays nil instead of becoming `now`, and a window-start timestamp is
// never presented as the time of the newest row.

extension FuyaoProvider {
    // MARK: - Public queries

    /// The first page of one stock's news timeline, newest first.
    public func stockNews(for symbol: SymbolID) async throws -> FuyaoTimed<[FuyaoNewsItem]> {
        guard let thscode = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        let data = try await fetchResearchData(path: "/api/news/stock/timeline-list", query: [
            .init(name: "thscode", value: thscode),
            .init(name: "offset", value: "first"),
            .init(name: "size", value: "20"),
        ])
        try Task.checkCancellation()
        // This feed carries no response-level time. The main file's injectable
        // clock is private to it, so the receipt time is the wall clock.
        let fetchedAt = Date.now
        return try Self.parseStockNews(data: data, fetchedAt: fetchedAt)
    }

    /// Today's anomaly explanations for one stock.
    public func anomalies(for symbol: SymbolID) async throws -> FuyaoTimed<[FuyaoAnomaly]> {
        guard let thscode = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        let data = try await fetchResearchData(path: "/api/a-share/special-data/anomaly-analysis-stock", query: [
            .init(name: "thscodes", value: thscode),
        ])
        try Task.checkCancellation()
        let payload = try Self.decodePayload(AnomalyPayload.self, from: data, endpoint: "anomaly-analysis")
        return FuyaoTimed(
            value: Self.anomalyItems(payload.item ?? [], thscode: thscode),
            dataTime: Self.millisecondDate(payload.timestamp),
            fetchedAt: Date.now
        )
    }

    /// The 24-hour A-share heat board, top 100.
    public func hotStocks() async throws -> FuyaoTimed<[FuyaoHotStock]> {
        let data = try await fetchResearchData(path: "/api/a-share/special-data/hot-stock-list", query: [
            .init(name: "period", value: "day"),
            .init(name: "limit", value: "100"),
        ])
        try Task.checkCancellation()
        let payload = try Self.decodePayload(HotStockPayload.self, from: data, endpoint: "hot-stock-list")
        return FuyaoTimed(
            value: Self.hotStockItems(payload.item ?? []),
            dataTime: Self.millisecondDate(payload.timestamp),
            fetchedAt: Date.now
        )
    }

    /// One stock's daily heat rank over the window `start`..`end`, both ends
    /// included as Beijing calendar days.
    public func rankTrend(for symbol: SymbolID, start: Date, end: Date) async throws -> FuyaoTimed<[FuyaoRankPoint]> {
        guard let thscode = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        let data = try await fetchResearchData(path: "/api/a-share/special-data/hot-stock-rank-trend", query: [
            .init(name: "thscode", value: thscode),
            .init(name: "start_date", value: Self.beijingDayString(start)),
            .init(name: "end_date", value: Self.beijingDayString(end)),
        ])
        try Task.checkCancellation()
        let payload = try Self.decodePayload(RankTrendPayload.self, from: data, endpoint: "hot-stock-rank-trend")
        let points = Self.rankPoints(payload.item ?? [], thscode: thscode)
        // `data.timestamp` is the window's first day, not when the ranks were
        // read; the newest point is what says how current the series is.
        return FuyaoTimed(value: points, dataTime: points.last?.date, fetchedAt: Date.now)
    }

    // MARK: - Parsing

    static func parseStockNews(data: Data, fetchedAt: Date) throws -> FuyaoTimed<[FuyaoNewsItem]> {
        let payload = try decodePayload(NewsPayload.self, from: data, endpoint: "news-timeline")
        var seen: Set<String> = []
        let items = (payload.items ?? []).compactMap { item -> FuyaoNewsItem? in
            guard let id = item.id?.nilIfBlank,
                  let title = item.title?.nilIfBlank,
                  seen.insert(id).inserted else { return nil }
            return FuyaoNewsItem(
                id: id,
                title: title,
                summary: item.summary?.nilIfBlank,
                source: item.source?.nilIfBlank,
                publishedAt: millisecondDate(item.publishTimeMs),
                url: webURL(item.jumpUrl)
            )
        }
        // Newest first; a headline with no time goes after every dated one, and
        // equal times keep the feed's order.
        let ordered = items.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.publishedAt, rhs.element.publishedAt) {
                case let (left?, right?):
                    return left == right ? lhs.offset < rhs.offset : left > right
                case (nil, nil): return lhs.offset < rhs.offset
                case (_?, nil): return true
                case (nil, _?): return false
                }
            }
            .map(\.element)
        return FuyaoTimed(value: ordered, dataTime: nil, fetchedAt: fetchedAt)
    }

    static func parseAnomalies(data: Data, thscode: String, fetchedAt: Date) throws -> FuyaoTimed<[FuyaoAnomaly]> {
        let payload = try decodePayload(AnomalyPayload.self, from: data, endpoint: "anomaly-analysis")
        return FuyaoTimed(
            value: anomalyItems(payload.item ?? [], thscode: thscode),
            dataTime: millisecondDate(payload.timestamp),
            fetchedAt: fetchedAt
        )
    }

    static func parseHotStocks(data: Data, fetchedAt: Date) throws -> FuyaoTimed<[FuyaoHotStock]> {
        let payload = try decodePayload(HotStockPayload.self, from: data, endpoint: "hot-stock-list")
        return FuyaoTimed(
            value: hotStockItems(payload.item ?? []),
            dataTime: millisecondDate(payload.timestamp),
            fetchedAt: fetchedAt
        )
    }

    static func parseRankTrend(data: Data, thscode: String, fetchedAt: Date) throws -> FuyaoTimed<[FuyaoRankPoint]> {
        let payload = try decodePayload(RankTrendPayload.self, from: data, endpoint: "hot-stock-rank-trend")
        let points = rankPoints(payload.item ?? [], thscode: thscode)
        return FuyaoTimed(value: points, dataTime: points.last?.date, fetchedAt: fetchedAt)
    }

    private static func anomalyItems(_ rows: [AnomalyItem], thscode: String) -> [FuyaoAnomaly] {
        rows.compactMap { row in
            // One row asked for; another stock's explanation says nothing about it.
            guard let code = row.thscode?.nilIfBlank,
                  code.caseInsensitiveCompare(thscode) == .orderedSame,
                  let text = row.analysisContent?.nilIfBlank else { return nil }
            return FuyaoAnomaly(
                thscode: code,
                name: row.stockName?.nilIfBlank ?? code,
                text: text,
                keywords: (row.keywordList ?? []).compactMap { $0.nilIfBlank },
                tag: row.tagName?.nilIfBlank ?? ""
            )
        }
    }

    private static func hotStockItems(_ rows: [HotStockItem]) -> [FuyaoHotStock] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            let code = row.thscode?.nilIfBlank
            guard let code, let rank = ranked(row.rank), seen.insert(code.uppercased()).inserted else { return nil }
            return FuyaoHotStock(
                thscode: code,
                name: row.name?.nilIfBlank ?? code,
                rank: rank,
                rankChange: row.rankChange,
                trend: row.rankTrend?.nilIfBlank
            )
        }
        .sorted { $0.rank < $1.rank }
    }

    /// Rank points of the requested stock only, oldest first. Each point joins
    /// the series on its `date_ms` (the Beijing midnight upstream anchors it
    /// to); a point without one is dated by its `date` string and dropped when
    /// it has neither. Rows resolving to the same date keep the last one.
    private static func rankPoints(_ rows: [RankPointItem], thscode: String) -> [FuyaoRankPoint] {
        var byDate: [Date: FuyaoRankPoint] = [:]
        for row in rows {
            guard let code = row.thscode?.nilIfBlank,
                  code.caseInsensitiveCompare(thscode) == .orderedSame,
                  let rank = ranked(row.rank),
                  let date = millisecondDate(row.dateMs) ?? beijingDay(of: row.date) else { continue }
            byDate[date] = FuyaoRankPoint(thscode: code, date: date, rank: rank)
        }
        return byDate.values.sorted { $0.date < $1.date }
    }

    /// A board rank is a positive whole number; anything else is not a rank.
    private static func ranked(_ raw: Int?) -> Int? {
        guard let raw, raw > 0 else { return nil }
        return raw
    }

    /// The ceiling for a plausible upstream time; a larger value is corrupt.
    static let maxPlausibleTimestampMs: Double = 32_503_680_000_000  // 3000-01-01

    /// Unix milliseconds to a date. Missing, zero, negative, non-finite or
    /// absurd values carry no time and are not replaced with the local clock.
    static func millisecondDate(_ raw: Double?) -> Date? {
        guard let raw, raw.isFinite, raw > 0, raw < maxPlausibleTimestampMs else { return nil }
        let seconds = raw / 1000
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// An absolute HTTP/HTTPS link; anything else (relative, other schemes, junk)
    /// is not a link this app will open.
    static func webURL(_ raw: String?) -> URL? {
        guard let text = raw?.nilIfBlank,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// `yyyy-MM-dd` for the Beijing calendar day containing `date`.
    static func beijingDayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Beijing midnight of a `yyyy-MM-dd` string, when it names a real day.
    static func beijingDay(of raw: String?) -> Date? {
        guard let text = raw?.nilIfBlank else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
        else { return nil }
        return date
    }

    // MARK: - Wire shapes

    struct NewsPayload: Decodable {
        let items: [NewsItem]?
    }

    struct NewsItem: Decodable {
        // Optional so one malformed headline is skipped, not a whole page.
        let id: String?
        let title: String?
        let summary: String?
        let source: String?
        let publishTimeMs: Double?
        let jumpUrl: String?
    }

    struct AnomalyPayload: Decodable {
        let timestamp: Double?
        let item: [AnomalyItem]?
    }

    struct AnomalyItem: Decodable {
        let thscode: String?
        let stockName: String?
        let analysisContent: String?
        let keywordList: [String]?
        let tagName: String?
    }

    struct HotStockPayload: Decodable {
        let timestamp: Double?
        let item: [HotStockItem]?
    }

    struct HotStockItem: Decodable {
        let thscode: String?
        let name: String?
        let rank: Int?
        let rankChange: Int?
        let rankTrend: String?
    }

    struct RankTrendPayload: Decodable {
        let timestamp: Double?
        let item: [RankPointItem]?
    }

    struct RankPointItem: Decodable {
        let thscode: String?
        let date: String?
        let dateMs: Double?
        let rank: Int?
    }
}

private extension String {
    /// The text without surrounding whitespace, or nil when nothing is left.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
