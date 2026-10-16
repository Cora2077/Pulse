import Foundation

/// Free, unofficial Tonghuashun industry-board data (`bk_881155`, 银行).
/// Search and names are local. Quotes and the session trend have separate feeds;
/// native minute K-lines may lag substantially. Keep their actual timestamps and
/// OHLC: a sampled price line cannot faithfully reconstruct candlestick wicks.
public struct ThsSectorProvider: QuoteProvider {
    public static let providerID = "ths"
    let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(http: HTTPClient = HTTPClient(), now: @escaping @Sendable () -> Date = { .now }) {
        self.http = http
        self.now = now
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: Self.providerID,
            name: PulseLocalization.localizedString("provider.ths"),
            markets: [.sh],
            capabilities: [.search, .quotes, .candles, .referenceData],
            candleMarkets: [.sh],
            candlePeriods: Set(CandlePeriod.allCases),
            delay: [.sh: 0],
            rateLimit: RateLimitPolicy(minInterval: 0.3),
            suggestedPollInterval: 30
        )
    }

    public func covers(_ symbol: SymbolID) -> Bool {
        symbol.sectorIndex?.isValidWireCode == true
    }

    static func wireCode(for board: SectorIndexID) -> String { "bk_\(board.code)" }

    public func search(_ query: String) async throws -> [SymbolInfo] {
        try Task.checkCancellation()
        return SectorIndexCatalog.search(query)
    }

    public func securityNames(for symbols: [SymbolID]) async throws -> [SecurityName] {
        try Task.checkCancellation()
        let names = symbols.compactMap { symbol -> SecurityName? in
            guard covers(symbol), let board = symbol.sectorIndex else { return nil }
            return SecurityName(symbol: symbol, name: board.displayName, localeIdentifier: "zh-Hans")
        }
        guard !names.isEmpty else { throw ProviderError.unsupported(.referenceData) }
        return names
    }

    public func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        let boards = symbols.filter(covers)
        guard !boards.isEmpty else { throw ProviderError.unsupported(.quotes) }
        var quotes: [Quote] = []
        var lastError: (any Error)?
        // The endpoint accepts one board per request. Pace a batch here as well
        // as at the composite boundary, which only paces whole provider calls.
        for (index, symbol) in boards.enumerated() {
            try Task.checkCancellation()
            if index > 0 { try await Task.sleep(for: .milliseconds(300)) }
            guard let board = symbol.sectorIndex else { continue }
            do {
                let payload = try await fetchPayload(
                    "v6/realhead/\(Self.wireCode(for: board))/defer/last.js"
                )
                quotes.append(try Self.parseQuote(payload, symbol: symbol, now: now()))
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw CancellationError() }
                if case ProviderError.rateLimited = error { throw error }
                lastError = error
            }
        }
        if quotes.isEmpty, let lastError { throw lastError }
        return quotes
    }

    static func parseQuote(_ data: Data, symbol: SymbolID, now: Date = .now) throws -> Quote {
        struct Response: Decodable { let items: [String: FieldValue]? }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ProviderError.badResponse("ths quote: \(error.localizedDescription)") }
        guard let items = response.items, !items.isEmpty else {
            throw ProviderError.symbolNotFound(symbol)
        }
        guard let price = items["10"]?.doubleValue, price > 0,
              let previousClose = items["6"]?.doubleValue, previousClose > 0 else {
            throw ProviderError.badResponse("ths: missing quote price for \(symbol.code)")
        }
        return Quote(
            symbol: symbol,
            name: items["name"]?.stringValue ?? symbol.sectorIndex?.displayName,
            price: price, previousClose: previousClose,
            open: positive(items["7"]?.doubleValue),
            high: positive(items["8"]?.doubleValue),
            low: positive(items["9"]?.doubleValue),
            volume: nonnegative(items["13"]?.doubleValue),
            turnover: nonnegative(items["19"]?.doubleValue),
            currencyCode: "CNY",
            timestamp: parseTimestamp(items["time"]?.stringValue) ?? now
        )
    }

    public func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        guard count > 0 else { return [] }
        guard covers(symbol), let board = symbol.sectorIndex else {
            throw ProviderError.unsupported(.candles)
        }
        var candles: [Candle]
        if period == .minute1 {
            let payload = try await fetchPayload("v6/time/\(Self.wireCode(for: board))/last.js")
            struct Row: Decodable {
                let data: String?
                let date: String?
            }
            let rows: [String: Row]
            do { rows = try JSONDecoder().decode([String: Row].self, from: payload) }
            catch { throw ProviderError.badResponse("ths trend: \(error.localizedDescription)") }
            guard let row = rows[Self.wireCode(for: board)], let series = row.data, let date = row.date else {
                throw ProviderError.badResponse("ths: missing trend for \(board.code)")
            }
            candles = Self.parseTrend(series, date: date, timeZone: symbol.market.timeZone)
        } else if let path = Self.linePath(for: period, board: board) {
            candles = try await lineCandles(path: path, period: period, market: symbol.market)
        } else {
            throw ProviderError.unsupported(.candles)
        }
        if period == .day, let snapshot = try await dailySnapshot(for: symbol, board: board) {
            // `last.js` can omit the current trading day even after the close.
            // The separate snapshot has official daily OHLC, not sampled prices.
            candles = Self.mergingDailySnapshot(snapshot, into: candles)
        }
        guard !candles.isEmpty else {
            throw ProviderError.badResponse("ths: no candles for \(board.code)")
        }
        guard !period.isIntraday, count > candles.count else { return Array(candles.suffix(count)) }
        let history = try await extendedHistory(symbol: symbol, board: board, period: period, count: count)
        // The recent window wins overlaps so an older year file cannot erase the
        // current session. Return only real, dated source bars, even when short.
        var byTime = Dictionary(history.map { ($0.time, $0) }, uniquingKeysWith: { _, last in last })
        for candle in candles { byTime[candle.time] = candle }
        return Array(byTime.values.sorted { $0.time < $1.time }.suffix(count))
    }

    /// The history window and the official current-day snapshot update
    /// independently. Always consult the snapshot for daily charts, including
    /// after the close; retries of the history URL alone cannot repair this gap.
    private func dailySnapshot(for symbol: SymbolID, board: SectorIndexID) async throws -> Candle? {
        var snapshot: Candle?
        do {
            let data = try await fetchPayload("v6/line/\(Self.wireCode(for: board))/01/today.js")
            snapshot = try Self.parseDailySnapshot(data, board: board, now: now())
            if let snapshot, Self.reachesPresent([snapshot], market: symbol.market, now: now()) { return snapshot }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if case ProviderError.rateLimited = error { throw error }
        }
        // A quote also carries the official session OHLC. Use its own timestamp,
        // never `now`, so a stale quote cannot invent a candle for a holiday or a
        // session that has not started.
        do {
            let data = try await fetchPayload("v6/realhead/\(Self.wireCode(for: board))/defer/last.js")
            if let quoteBar = try Self.parseDailyQuote(data, now: now()) {
                if let snapshot, snapshot.time > quoteBar.time { return snapshot }
                return quoteBar
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if case ProviderError.rateLimited = error { throw error }
        }
        return snapshot // keep usable history if both independent feeds fail
    }

    static func parseDailySnapshot(_ data: Data, board: SectorIndexID, now: Date = .now) throws -> Candle? {
        let payload: [String: [String: FieldValue]]
        do { payload = try JSONDecoder().decode([String: [String: FieldValue]].self, from: data) }
        catch { throw ProviderError.badResponse("ths daily snapshot: \(error.localizedDescription)") }
        guard let fields = payload[wireCode(for: board)] else { return nil }
        let rawDate: String?
        if let text = fields["1"]?.stringValue, text.count == 8 {
            rawDate = text
        } else if let number = fields["1"]?.doubleValue, number.rounded() == number,
                  (10_000_000...99_999_999).contains(number) {
            rawDate = String(format: "%.0f", number)
        } else { rawDate = nil }
        guard let rawDate, let day = strictDate(rawDate, formatter: formatter("yyyyMMdd", timeZone: Market.sh.timeZone)) else { return nil }
        return dailyCandle(
            day: day, open: fields["7"]?.doubleValue, high: fields["8"]?.doubleValue,
            low: fields["9"]?.doubleValue, close: fields["11"]?.doubleValue,
            volume: fields["13"]?.doubleValue, now: now
        )
    }

    static func parseDailyQuote(_ data: Data, now: Date = .now) throws -> Candle? {
        struct Response: Decodable { let items: [String: FieldValue]? }
        let payload: Response
        do { payload = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ProviderError.badResponse("ths daily quote: \(error.localizedDescription)") }
        guard let fields = payload.items, let stamp = parseTimestamp(fields["time"]?.stringValue) else { return nil }
        return dailyCandle(
            day: stamp, open: fields["7"]?.doubleValue, high: fields["8"]?.doubleValue,
            low: fields["9"]?.doubleValue, close: fields["10"]?.doubleValue,
            volume: fields["13"]?.doubleValue, now: now
        )
    }

    private static func dailyCandle(
        day: Date, open: Double?, high: Double?, low: Double?, close: Double?, volume: Double?, now: Date
    ) -> Candle? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        let day = calendar.startOfDay(for: day)
        guard day <= calendar.startOfDay(for: now),
              let open, let high, let low, let close,
              [open, high, low, close].allSatisfy({ $0.isFinite && $0 > 0 }),
              high >= max(open, close), low <= min(open, close) else { return nil }
        return Candle(time: day, open: open, high: high, low: low, close: close, volume: nonnegative(volume))
    }

    static func mergingDailySnapshot(_ snapshot: Candle, into candles: [Candle]) -> [Candle] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        var byDay: [Date: Candle] = [:]
        for candle in candles { byDay[calendar.startOfDay(for: candle.time)] = candle }
        byDay[calendar.startOfDay(for: snapshot.time)] = snapshot
        return byDay.values.sorted { $0.time < $1.time }
    }

    /// Bound the entire freshness search to three HTTP requests. Query variation
    /// may reach a newer cached response, but cannot guarantee current data.
    private func lineCandles(path: String, period: CandlePeriod, market: Market) async throws -> [Candle] {
        var best: [Candle] = []
        var lastError: (any Error)?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let data = try await fetchPayload(path, attempts: 1, cacheBuster: attempt > 0)
                let parsed = try Self.parseCandles(data, period: period, timeZone: market.timeZone)
                guard !parsed.isEmpty else { throw ProviderError.badResponse("ths: empty candle series") }
                if (parsed.last?.time ?? .distantPast) >= (best.last?.time ?? .distantPast) { best = parsed }
                if Self.reachesPresent(best, period: period, market: market, now: now()) { return best }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw CancellationError() }
                if !Self.shouldRetry(error) { throw error }
                lastError = error
            }
            if attempt < 2 { try await Task.sleep(for: .milliseconds(300)) }
        }
        if !best.isEmpty { return best }  // historical truth is preferable to invented OHLC
        throw lastError ?? ProviderError.badResponse("ths: unavailable candle series")
    }

    static func reachesPresent(
        _ candles: [Candle], period: CandlePeriod = .day, market: Market, now: Date = .now
    ) -> Bool {
        guard let newest = candles.last?.time else { return false }
        let day = CalendarDay(now, in: market.timeZone)
        guard ExchangeCalendar.isTradingDay(market, on: day) else { return true }
        let session = IntradayTradingSession(market: market, referenceDate: now)
        guard now >= session.open else { return true }
        var expected = min(now, session.close)
        if let morningEnd = session.morningEnd, let afternoonStart = session.afternoonStart,
           now >= morningEnd, now < afternoonStart { expected = morningEnd }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        guard calendar.isDate(newest, inSameDayAs: expected) else { return false }
        guard let minutes = period.intradayMinutes else { return true }
        let tolerance = Double(minutes * 60 + 60)
        // Source minute bars are end-labelled; the forming bar may end slightly
        // after now. Morning bars are still current just after the lunch break.
        let age = expected.timeIntervalSince(newest)
        let lunchGrace = session.afternoonStart.map {
            now >= $0 && now.timeIntervalSince($0) < Double(minutes * 60)
        } ?? false
        if lunchGrace, newest >= (session.morningEnd ?? session.open) { return true }
        return age <= tolerance && age >= -tolerance
    }

    static func linePath(for period: CandlePeriod, board: SectorIndexID) -> String? {
        let segment: String
        switch period {
        case .day: segment = "02"
        case .week: segment = "10"
        case .month: segment = "20"
        case .minute5, .minute15: segment = "32"
        case .minute30: segment = "42"
        case .hour1: segment = "52"
        case .minute1: return nil
        }
        return "v6/line/\(wireCode(for: board))/\(segment)/last.js"
    }

    private func extendedHistory(
        symbol: SymbolID, board: SectorIndexID, period: CandlePeriod, count: Int
    ) async throws -> [Candle] {
        let segment: String
        switch period {
        case .day: segment = "02"
        case .week: segment = "10"
        case .month: segment = "20"
        default: return []
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = symbol.market.timeZone
        var year = calendar.component(.year, from: now())
        var byTime: [Date: Candle] = [:]
        // A UI-sized daily request normally needs two years. Bound the extra
        // network work even for a much larger caller request.
        for _ in 0..<3 where year >= 2007 {
            try Task.checkCancellation()
            do {
                let payload = try await fetchPayload("v6/line/\(Self.wireCode(for: board))/\(segment)/\(year).js")
                for candle in try Self.parseCandles(payload, period: period, timeZone: symbol.market.timeZone) {
                    byTime[candle.time] = candle
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw CancellationError() }
                if case ProviderError.rateLimited = error { throw error }
                // Year files are optional history top-ups; retain the valid
                // rolling window rather than fail an otherwise usable chart.
                break
            }
            if byTime.count >= count { break }
            year -= 1
        }
        return byTime.values.sorted { $0.time < $1.time }
    }

    private func fetchPayload(_ path: String, attempts: Int = 3, cacheBuster: Bool = false) async throws -> Data {
        var lastError: (any Error)?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://d.10jqka.com.cn/\(path)")
            if cacheBuster || attempt > 0 {
                components?.queryItems = [.init(name: "_", value: UUID().uuidString)]
            }
            guard let url = components?.url else { throw ProviderError.badResponse("ths: invalid URL") }
            do {
                let body = try await http.get(url, headers: ["Cache-Control": "no-cache"])
                try Task.checkCancellation()
                guard let payload = Self.jsonPayload(from: body) else {
                    throw ProviderError.badResponse("ths: invalid JSONP envelope")
                }
                return payload
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw CancellationError() }
                if !Self.shouldRetry(error) { throw error }
                lastError = error
            }
            if attempt + 1 < attempts { try await Task.sleep(for: .milliseconds(300)) }
        }
        throw lastError ?? ProviderError.badResponse("ths: unavailable payload")
    }

    private static func shouldRetry(_ error: any Error) -> Bool {
        guard let error = error as? ProviderError else { return false }
        switch error {
        case .network, .badResponse: return true
        case .clientError(let status, _): return status == 404 || status == 408
        case .rateLimited, .unsupported, .symbolNotFound: return false
        }
    }

    static func jsonPayload(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) ?? data.decodedGB18030(),
              let start = text.firstIndex(of: "("), let end = text.lastIndex(of: ")"), start < end else { return nil }
        let inner = text[text.index(after: start)..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : Data(inner.utf8)
    }

    struct FieldValue: Decodable {
        let raw: String?
        var doubleValue: Double? { raw.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        var stringValue: String? { raw }
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { raw = value }
            else if let value = try? container.decode(Double.self), value.isFinite { raw = String(value) }
            else { raw = nil }
        }
    }

    static func parseTimestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let value = text.split(separator: " ").prefix(2).joined(separator: " ")
        return strictDate(value, formatter: formatter("yyyy-MM-dd HH:mm:ss", timeZone: Market.sh.timeZone))
    }

    /// Source rows: yyyyMMdd[HHmm],open,high,low,close,shares,turnover,...
    static func parseCandles(_ data: Data, period: CandlePeriod, timeZone: TimeZone) throws -> [Candle] {
        struct Response: Decodable { let data: String? }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ProviderError.badResponse("ths candles: \(error.localizedDescription)") }
        guard let series = response.data else { return [] }
        let formatter = formatter(period.isIntraday ? "yyyyMMddHHmm" : "yyyyMMdd", timeZone: timeZone)
        var byTime: [Date: Candle] = [:]
        for row in series.split(separator: ";") {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 5, let time = strictDate(String(fields[0]), formatter: formatter),
                  let open = Double(fields[1]), let high = Double(fields[2]),
                  let low = Double(fields[3]), let close = Double(fields[4]),
                  [open, high, low, close].allSatisfy({ $0.isFinite && $0 > 0 }),
                  high >= max(open, close), low <= min(open, close) else { continue }
            let volume = fields.count > 5 ? nonnegative(Double(fields[5])) : nil
            byTime[time] = Candle(time: time, open: open, high: high, low: low, close: close, volume: volume)
        }
        let candles = byTime.values.sorted { $0.time < $1.time }
        guard period == .minute15 else { return candles }
        // THS labels five-minute bars by END: 09:35/09:40/09:45
        // belong together. Convert to starts for the shared floor-bucketer,
        // then restore end labels on the resulting 15-minute bars.
        let starts = candles.map { candle -> Candle in
            var copy = candle
            copy.time = copy.time.addingTimeInterval(-5 * 60)
            return copy
        }
        return CandleResampler.resample(starts, into: .minute15, timeZone: timeZone).map { candle in
            var copy = candle
            copy.time = copy.time.addingTimeInterval(15 * 60)
            return copy
        }
    }

    /// HHmm,indexLevel,minuteTurnover,auxiliaryPrice,minuteShares.
    /// Shares are per-minute, already in the same units as realhead field 13.
    static func parseTrend(_ series: String, date: String, timeZone: TimeZone) -> [Candle] {
        let formatter = formatter("yyyyMMddHHmm", timeZone: timeZone)
        var byTime: [Date: Candle] = [:]
        for row in series.split(separator: ";") {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, let price = Double(fields[1]), price.isFinite, price > 0,
                  let hhmm = Int(fields[0]), (0...2359).contains(hhmm), hhmm % 100 < 60,
                  let time = strictDate(date + String(format: "%04d", hhmm), formatter: formatter) else { continue }
            let volume = fields.count > 4 ? nonnegative(Double(fields[4])) : nil
            byTime[time] = Candle(time: time, open: price, high: price, low: price, close: price, volume: volume)
        }
        return byTime.values.sorted { $0.time < $1.time }
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    private static func strictDate(_ value: String, formatter: DateFormatter) -> Date? {
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    private static func nonnegative(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    private static func positive(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}
