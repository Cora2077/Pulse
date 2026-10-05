import Foundation
import CryptoKit

public enum EastmoneyTradingEvents {
    public enum Source: String, CaseIterable, Codable, Sendable {
        case earnings
        case dividends
        case unlocks

        var reportName: String {
            switch self {
            case .earnings: "RPT_STOCKCALENDAR"
            case .dividends: "RPT_SHAREBONUS_DET"
            case .unlocks: "RPT_LIFT_STAGE"
            }
        }

        var dateField: String {
            switch self {
            case .earnings, .unlocks: self == .earnings ? "NOTICE_DATE" : "FREE_DATE"
            case .dividends: "EX_DIVIDEND_DATE"
            }
        }

        var kind: InstrumentEvent.Kind {
            switch self {
            case .earnings: .earnings
            case .dividends: .dividend
            case .unlocks: .unlock
            }
        }

        var label: String {
            switch self {
            case .earnings: "预约披露日"
            case .dividends: "除权除息日"
            case .unlocks: "限售解禁日"
            }
        }
    }

    public struct Record: Codable, Hashable, Sendable, Identifiable {
        public var symbol: SymbolID
        public var event: InstrumentEvent
        public var sourceName: String
        public var isForecast: Bool
        public var source: Source

        public var id: String { "\(symbol.description):\(source.rawValue):\(event.id.uuidString)" }
    }

    public struct Update: Sendable {
        public let source: Source
        public let records: [Record]
        public let succeededSymbols: Set<SymbolID>
        public let failedSymbols: Set<SymbolID>

        public var errorMessage: String? {
            failedSymbols.isEmpty ? nil : "\(source.label)数据暂时不可用"
        }
    }

    private static let endpoint = URL(string: "https://datacenter-web.eastmoney.com/api/data/v1/get")!
    private static let batchSize = 40
    private static let requestTimeout: TimeInterval = 12
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    /// Event dates use one date-only calendar across fetching, editing, and display.
    public static var dateCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        return calendar
    }

    public static func supports(_ symbol: SymbolID) -> Bool { eastmoneyCode(for: symbol) != nil }

    /// Pull only explicitly requested A-share symbols, in short batches with a per-request timeout.
    public static func fetch(
        symbols: [SymbolID],
        now: Date = .now,
        session: URLSession = .shared
    ) async -> [Update] {
        let supported = Array(Set(symbols.filter { eastmoneyCode(for: $0) != nil }))
            .sorted { $0.description < $1.description }
        guard !supported.isEmpty else { return [] }
        let batches = stride(from: 0, to: supported.count, by: batchSize).map {
            Array(supported[$0..<min($0 + batchSize, supported.count)])
        }
        var updates: [Update] = []
        for batch in batches {
            let batchUpdates = await withTaskGroup(of: Update.self, returning: [Update].self) { group in
                for source in Source.allCases {
                    group.addTask {
                        await fetch(source: source, symbols: batch, now: now, session: session)
                    }
                }
                var results: [Update] = []
                for await update in group { results.append(update) }
                return results
            }
            updates.append(contentsOf: batchUpdates)
        }
        return updates
    }

    private static func fetch(
        source: Source,
        symbols: [SymbolID],
        now: Date,
        session: URLSession
    ) async -> Update {
        guard let from = dateString(now),
              let end = dateCalendar.date(byAdding: .day, value: 90, to: startOfDay(now)),
              let through = dateString(end),
              let url = requestURL(source: source, symbols: symbols, from: from, through: through) else {
            return Update(source: source, records: [], succeededSymbols: [], failedSymbols: Set(symbols))
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: requestTimeout)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("https://data.eastmoney.com/", forHTTPHeaderField: "Referer")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let records = parse(data, source: source, symbols: Set(symbols), now: now, sourceURL: url.absoluteString) else {
                return Update(source: source, records: [], succeededSymbols: [], failedSymbols: Set(symbols))
            }
            return Update(source: source, records: records, succeededSymbols: Set(symbols), failedSymbols: [])
        } catch {
            return Update(source: source, records: [], succeededSymbols: [], failedSymbols: Set(symbols))
        }
    }

    private static func requestURL(source: Source, symbols: [SymbolID], from: String, through: String) -> URL? {
        let codes = symbols.compactMap { eastmoneyCode(for: $0) }.map { "\"\($0)\"" }.joined(separator: ",")
        guard !codes.isEmpty else { return nil }
        var filters = "(SECURITY_CODE in (\(codes)))"
        if source == .earnings { filters += "(EVENT_TYPE=\"预约披露日\")" }
        filters += "(\(source.dateField)>='\(from)')(\(source.dateField)<='\(through)')"
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "reportName", value: source.reportName),
            URLQueryItem(name: "columns", value: "ALL"),
            URLQueryItem(name: "filter", value: filters),
            URLQueryItem(name: "pageNumber", value: "1"),
            URLQueryItem(name: "pageSize", value: "500"),
            URLQueryItem(name: "sortColumns", value: source.dateField),
            URLQueryItem(name: "sortTypes", value: "1"),
            URLQueryItem(name: "source", value: "WEB"),
            URLQueryItem(name: "client", value: "WEB")
        ]
        return components?.url
    }

    static func parse(
        _ data: Data,
        source: Source,
        symbols: Set<SymbolID>,
        now: Date,
        sourceURL: String
    ) -> [Record]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if (root["success"] as? Bool) == false {
            return (root["code"] as? Int) == 9201 ? [] : nil
        }
        guard (root["success"] as? Bool) == true,
              let result = root["result"] as? [String: Any],
              let rows = result["data"] as? [[String: Any]] else { return nil }
        let pages = result["pages"] as? Int ?? (rows.count == 500 ? 2 : 1)
        guard pages == 1 else { return nil }

        let lower = startOfDay(now)
        guard let upper = dateCalendar.date(byAdding: .day, value: 90, to: lower) else { return nil }
        let records = rows.compactMap { row -> Record? in
            guard let code = row["SECURITY_CODE"] as? String,
                  let secuCode = row["SECUCODE"] as? String,
                  let market = market(from: secuCode),
                  let symbol = symbols.first(where: { $0.market == market && eastmoneyCode(for: $0) == code }),
                  let date = parseDate(row[source.dateField]), date >= lower, date <= upper,
                  let title = title(in: row, source: source) else { return nil }
            if source == .earnings && row["EVENT_TYPE"] as? String != "预约披露日" { return nil }
            let event = InstrumentEvent(
                id: stableID(source: source, symbol: symbol, date: date, title: title),
                kind: source.kind, date: date, title: title, sourceURL: sourceURL
            )
            return Record(symbol: symbol, event: event, sourceName: "东方财富", isForecast: source == .earnings, source: source)
        }
        var seen: Set<String> = []
        return records.filter { seen.insert($0.id).inserted }
    }

    static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String, raw.count >= 10 else { return nil }
        let datePart = String(raw.prefix(10))
        let pieces = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = dateCalendar
        components.timeZone = shanghai
        components.year = year
        components.month = month
        components.day = day
        guard let result = components.date else { return nil }
        let check = dateCalendar.dateComponents([.year, .month, .day], from: result)
        return check.year == year && check.month == month && check.day == day ? result : nil
    }

    private static func title(in row: [String: Any], source: Source) -> String? {
        let field: String
        switch source {
        case .earnings: field = "LEVEL1_CONTENT"
        case .dividends: field = "IMPL_PLAN_PROFILE"
        case .unlocks: field = "FREE_SHARES_TYPE"
        }
        guard let title = row[field] as? String else { return nil }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func eastmoneyCode(for symbol: SymbolID) -> String? {
        guard symbol.market == .sh || symbol.market == .sz,
              symbol.code.count == 6, symbol.code.allSatisfy(\.isNumber) else { return nil }
        return symbol.code
    }

    private static func market(from secuCode: String) -> Market? {
        if secuCode.hasSuffix(".SH") { return .sh }
        if secuCode.hasSuffix(".SZ") { return .sz }
        return nil
    }

    private static func startOfDay(_ date: Date) -> Date {
        dateCalendar.startOfDay(for: date)
    }

    private static func dateString(_ date: Date) -> String? {
        let components = dateCalendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func stableID(source: Source, symbol: SymbolID, date: Date, title: String) -> UUID {
        let seed = "\(source.rawValue)|\(symbol.description)|\(date.timeIntervalSince1970)|\(title)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
