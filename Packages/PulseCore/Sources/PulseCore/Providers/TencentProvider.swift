import Foundation

/// Tencent quote snapshots (qt.gtimg.cn, unofficial API).
/// Capabilities: batch quotes plus real-time A-share minute series and native
/// daily/weekly/monthly history; other markets fall back to the next provider.
/// The response is GBK-encoded text of the form `v_sh600519="1~<name>~600519~<price>~<prevClose>~<open>~...";`.
/// The `hf_` channel (international futures, which is how Pulse reaches the
/// precious metals) answers on the same endpoint in a different, comma-separated
/// format — see `InternationalFuturesQuote`.
public struct TencentProvider: QuoteProvider {
    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "tencent",
            name: PulseLocalization.localizedString("provider.tencent"),
            markets: [.us, .hk, .sh, .sz, .metal],
            capabilities: [.quotes, .search, .candles],
            candleMarkets: [.sh, .sz],
            // Minute periods come from the minute endpoint, day/week/month from
            // the fqkline history endpoint.
            candlePeriods: Set(CandlePeriod.allCases),
            delay: [.us: 0, .hk: 900, .sh: 0, .sz: 0, .metal: 0],
            rateLimit: RateLimitPolicy(minInterval: 2, batchSize: 60),
            suggestedPollInterval: 15
        )
    }

    // MARK: - Symbol mapping

    /// International-futures channel prefix. Its payload format differs from the
    /// equity one, so the prefix also routes parsing.
    static let internationalPrefix = "hf_"

    static func tencentSymbol(for id: SymbolID) -> String? {
        if let metal = id.metalID {
            // Only the international channel: this endpoint does not serve the
            // domestic `nf_` futures at all.
            let contract: String? = switch metal {
            case .gold: "GC"
            case .silver: "SI"
            case .platinum: "XPT"
            case .palladium: "XPD"
            case .goldSpot: "XAU"
            case .silverSpot: "XAG"
            case .shanghaiGoldSpot, .shanghaiGold, .shanghaiSilver: nil
            }
            return contract.map { internationalPrefix + $0 }
        }
        if let index = id.indexID {
            return switch index {
            case .sp500: "usINX"
            case .nasdaqComposite: "usIXIC"
            case .dowJonesIndustrial: "usDJI"
            case .nasdaq100: "usNDX"
            case .vix: "usVIX"
            case .russell1000, .russell2000: nil
            case .hangSeng: "hkHSI"
            case .hangSengTech: "hkHSTECH"
            case .shanghaiComposite: "sh000001"
            case .shenzhenComponent: "sz399001"
            case .chiNext: "sz399006"
            // No code on this endpoint answers for either: `jpN225`, `krKS11`
            // and the `int_` variants all come back `pv_none_match`.
            case .nikkei225, .kospi: nil
            }
        }
        switch id.market {
        case .us: return "us" + id.code
        case .hk: return "hk" + id.paddedCode(width: 5)
        case .sh: return "sh" + id.code
        case .sz: return "sz" + id.code
        case .crypto: return id.code
        // Tencent's international channel has no domestic-futures counterpart:
        // `nf_` codes are not served on this endpoint at all.
        case .metal, .metalCN: return nil
        // Tencent does serve Tokyo and Seoul (`jp7203`, `kr005930`), but only as
        // quotes: the minute endpoint answers with a single point and the daily
        // K-line with a single bar, so there is no history behind them. Measured,
        // not assumed. Yahoo covers both markets fully, so nothing is routed here.
        case .jp, .kr, .kq: return nil
        }
    }

    // MARK: - QuoteProvider

    public func search(_ query: String) async throws -> [SymbolInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let url = URL(string: "https://smartbox.gtimg.cn/s3/?v=2&q=\(encoded)&t=all")!
        let data = try await http.get(url, headers: ["Referer": "https://gu.qq.com/"])
        guard let text = data.decodedGB18030() ?? String(data: data, encoding: .utf8) else {
            throw ProviderError.badResponse("tencent smartbox: undecodable response")
        }
        return Self.parseSearch(text: text)
    }

    /// smartbox response: `v_hint="sh~000847~\\u817e...~txja~ZS^hk~00700~\\u817e...~txkg~GP^..."`
    /// Entries are separated by ^, fields by ~: [market, code, name (unicode-escaped), pinyin, type]
    static func parseSearch(text: String) -> [SymbolInfo] {
        guard let start = text.firstIndex(of: "\""),
              let end = text.lastIndex(of: "\""), start < end else { return [] }
        let body = text[text.index(after: start)..<end]
        var results: [SymbolInfo] = []
        for entry in body.split(separator: "^") {
            let f = entry.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { continue }
            let market: Market? = switch f[0] {
            case "sh": .sh
            case "sz": .sz
            case "hk": .hk
            case "us": .us
            default: nil  // jj (OTC funds), bk (sectors), etc. are not supported yet
            }
            guard let market else { continue }

            // US codes carry an exchange suffix (aapl.oq / tme.n); take the part before the dot
            var code = f[1]
            if market == .us, let dot = code.firstIndex(of: ".") {
                code = String(code[..<dot])
            }

            let type: InstrumentType? = switch f[4].prefix(2).uppercased() {
            case "GP": .equity
            case "ZS": .index
            case "ET": .etf
            case "LO", "JJ": .fund
            default: nil
            }
            guard let type else { continue }

            let name = unescapeUnicode(f[2])
            guard !name.isEmpty else { continue }
            results.append(SymbolInfo(
                symbol: SymbolID(market: market, code: code),
                name: name,
                exchangeName: market.displayName,
                type: type
            ))
        }
        return results
    }

    /// smartbox returns Chinese names in \uXXXX escaped form
    static func unescapeUnicode(_ raw: String) -> String {
        guard raw.contains("\\u") else { return raw }
        return raw.applyingTransform(StringTransform("Hex-Any"), reverse: false) ?? raw
    }

    public func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        guard symbol.market.isChinaA else {
            throw ProviderError.unsupported(.candles)
        }
        if period.isIntraday {
            return try await minuteCandles(for: symbol, period: period, count: count)
        }
        return try await historicalCandles(for: symbol, period: period, count: count)
    }

    private func minuteCandles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        guard let tencentSymbol = Self.tencentSymbol(for: symbol) else {
            throw ProviderError.symbolNotFound(symbol)
        }
        var components = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query")!
        components.queryItems = [.init(name: "code", value: tencentSymbol)]
        let data = try await http.get(components.url!, headers: ["Referer": "https://gu.qq.com/"])
        let response: MinuteResponse
        do {
            response = try JSONDecoder().decode(MinuteResponse.self, from: data)
        } catch {
            throw ProviderError.badResponse("tencent minute: \(error.localizedDescription)")
        }
        guard response.code == 0,
              let minuteData = response.data?[tencentSymbol]?.data else {
            throw ProviderError.symbolNotFound(symbol)
        }
        let candles = Self.parseMinuteCandles(
            date: minuteData.date,
            rows: minuteData.data,
            market: symbol.market,
            period: period
        )
        guard !candles.isEmpty else {
            throw ProviderError.badResponse("tencent minute: no rows parsed")
        }
        return Array(candles.suffix(count))
    }

    // MARK: - Historical candles

    /// Native daily/weekly/monthly history for the China A markets
    /// (`web.ifzq.gtimg.cn/appstock/app/fqkline/get`).
    ///
    /// The final query field is the adjustment mode: left empty it returns
    /// unadjusted ("不复权") prices, which is what the rest of Pulse's OHLC
    /// semantics assume. Only the A-share markets are served here.
    private func historicalCandles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        // A non-positive count is a caller mistake, not a source failure: answer
        // it without spending a request.
        guard count > 0 else { return [] }
        guard symbol.market.isChinaA,
              let wireSymbol = Self.tencentSymbol(for: symbol),
              let interval = Self.historyInterval(for: period) else {
            throw ProviderError.unsupported(.candles)
        }
        let clamped = min(count, Self.historyMaxCount)
        var components = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get")!
        components.queryItems = [
            .init(name: "param", value: "\(wireSymbol),\(interval),,,\(clamped),"),
        ]
        let data = try await http.get(components.url!, headers: ["Referer": "https://gu.qq.com/"])
        let candles = try Self.parseHistoricalCandles(
            data,
            symbol: symbol,
            wireSymbol: wireSymbol,
            period: period
        )
        // The endpoint can include today's provisional bar in addition to lmt.
        return Array(candles.suffix(clamped))
    }

    /// The wire name of an interval; nil for intraday periods.
    static func historyInterval(for period: CandlePeriod) -> String? {
        switch period {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .minute1, .minute5, .minute15, .minute30, .hour1: nil
        }
    }

    /// Tencent serves at most 640 bars per request.
    static let historyMaxCount = 640

    /// Parses `{"code":0,"msg":"","data":{"sh000688":{"day":[[…]],"qt":{…}}}}`.
    ///
    /// Each row is `[date, open, close, high, low, volume]` — note that the third
    /// value is the *close*, not the high, and that volume is reported in lots of
    /// 100 shares like the quote endpoint. Metadata keys such as `qt` and any
    /// trailing row fields are ignored, and a row that is malformed or
    /// contradicts itself (non-finite, non-positive, high below low) is dropped
    /// rather than allowed to poison the chart.
    static func parseHistoricalCandles(
        _ data: Data,
        symbol: SymbolID,
        wireSymbol: String,
        period: CandlePeriod
    ) throws -> [Candle] {
        guard let interval = historyInterval(for: period) else {
            throw ProviderError.unsupported(.candles)
        }
        let response: HistoricalResponse
        do {
            response = try JSONDecoder().decode(HistoricalResponse.self, from: data)
        } catch {
            throw ProviderError.badResponse("tencent history: \(error.localizedDescription)")
        }
        guard response.code == 0 else {
            throw ProviderError.badResponse("tencent history: code \(response.code)")
        }
        guard let rows = response.data?[wireSymbol]?.series?[interval] else {
            throw ProviderError.symbolNotFound(symbol)
        }

        // The exchange's own day, so a bar can never land on the neighbouring date.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = symbol.market.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var byDate: [Date: Candle] = [:]
        for row in rows {
            guard let candle = parseHistoricalRow(row.values, formatter: formatter) else { continue }
            byDate[candle.time] = candle  // a repeated date keeps the last row
        }
        // Unusable rows alone must surface as an error, so Composite can fail
        // over instead of caching an empty success.
        guard !byDate.isEmpty else {
            throw ProviderError.badResponse("tencent history: no usable rows for \(wireSymbol)")
        }
        return byDate.values.sorted { $0.time < $1.time }
    }

    private static func parseHistoricalRow(_ row: [HistoryValue], formatter: DateFormatter) -> Candle? {
        guard row.count >= 5,  // a trailing volume field is optional
              let date = formatter.date(from: row[0].stringValue),
              formatter.string(from: date) == row[0].stringValue,  // reject 2025-13-45 etc.
              let open = row[1].doubleValue,
              let close = row[2].doubleValue,
              let high = row[3].doubleValue,
              let low = row[4].doubleValue,
              open.isFinite, close.isFinite, high.isFinite, low.isFinite,
              open > 0, close > 0,
              high >= max(open, close), low <= min(open, close), low > 0 else { return nil }
        // Volume is reported in lots; convert to shares to match the quote and
        // minute parsers. Values that are absent or unusable become nil.
        let volume = row.count > 5 ? row[5].doubleValue.flatMap { value -> Double? in
            guard value.isFinite, value >= 0 else { return nil }
            let shares = value * 100
            return shares.isFinite ? shares : nil
        } : nil
        return Candle(time: date, open: open, high: high, low: low, close: close, volume: volume)
    }

    public func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        let batchSize = descriptor.rateLimit?.batchSize ?? 60
        var quotes: [Quote] = []
        for chunk in symbols.chunked(into: batchSize) {
            let mapping = Dictionary(uniqueKeysWithValues: chunk.compactMap { symbol in
                Self.tencentSymbol(for: symbol).map { ($0, symbol) }
            })
            guard !mapping.isEmpty else { continue }
            let list = mapping.keys.sorted().joined(separator: ",")
            let url = URL(string: "https://qt.gtimg.cn/q=\(list)")!
            let data = try await http.get(url, headers: ["Referer": "https://gu.qq.com/"])
            guard let text = data.decodedGB18030() ?? String(data: data, encoding: .utf8) else {
                throw ProviderError.badResponse("tencent: undecodable response")
            }
            quotes += Self.parseQuotes(text: text, mapping: mapping)
        }
        guard !quotes.isEmpty else {
            // HTTP was already 200: failing to parse means a symbol problem (e.g. an instrument Tencent doesn't know), not a source failure
            throw ProviderError.clientError(status: 200, detail: "tencent: no quotes parsed (unknown symbols?)")
        }
        return quotes
    }

    // MARK: - Parsing

    /// Known field positions: 1 name, 3 last price, 4 previous close, 5 open, 30 timestamp, 31 change, 32 change %,
    /// 33 high, 34 low, 36 volume (in lots of 100 shares for A-shares), 37 turnover
    /// (in units of 10,000 CNY for A-shares, full local-currency units for HK/US shares)
    static func parseQuotes(text: String, mapping: [String: SymbolID]) -> [Quote] {
        var result: [Quote] = []
        for line in text.split(separator: ";") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.hasPrefix("v_") else { continue }
            let wireSymbol = String(key.dropFirst(2))
            guard let symbol = mapping[wireSymbol] else { continue }
            let payload = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"\n\r "))
            if wireSymbol.hasPrefix(internationalPrefix) {
                // A different payload shape entirely; see InternationalFuturesQuote.
                if let quote = InternationalFuturesQuote.parse(payload: payload, symbol: symbol) {
                    result.append(quote)
                }
                continue
            }
            let f = payload.components(separatedBy: "~")
            guard f.count > 37,
                  let price = Double(f[3]), price > 0,
                  let prevClose = Double(f[4]) else { continue }

            let volumeRaw = Double(f[36]) ?? Double(f[6])
            let volumeMultiplier: Double = symbol.market.isChinaA ? 100 : 1  // A-share volume is reported in lots (100 shares)
            let volume = volumeRaw.map { $0 * volumeMultiplier }
            result.append(Quote(
                symbol: symbol,
                name: f[1].isEmpty ? nil : f[1],
                price: price,
                previousClose: prevClose,
                open: Double(f[5]),
                high: Double(f[33]),
                low: Double(f[34]),
                volume: volume,
                turnover: parseTurnover(f[37], market: symbol.market, price: price, volume: volume),
                currencyCode: symbol.market.currencyCode,
                timestamp: parseTimestamp(f[30], timeZone: symbol.market.timeZone) ?? .now
            ))
        }
        return result
    }

    /// Tencent reports A-share turnover in ten-thousands, while HK/US responses already contain the full amount.
    /// Reject values that are implausibly far from price × volume so a future source-unit change cannot poison the model.
    static func parseTurnover(_ raw: String, market: Market, price: Double, volume: Double?) -> Double? {
        guard let reported = Double(raw), reported.isFinite, reported >= 0 else { return nil }
        let multiplier: Double = market.isChinaA ? 10_000 : 1
        let turnover = reported * multiplier
        guard turnover.isFinite, turnover <= 1_000_000_000_000_000 else { return nil }

        guard let volume, volume > 0 else { return turnover }
        let reference = price * volume
        guard reference.isFinite, reference > 0 else { return nil }
        let ratio = turnover / reference
        guard (0.01...100).contains(ratio) else { return nil }
        return turnover
    }

    /// Timestamp format varies by market: A-shares "20260703112400", HK/US "2026/07/03 11:24:00", etc. — all parsed in the exchange's time zone
    static func parseTimestamp(_ raw: String, timeZone: TimeZone) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formats = ["yyyyMMddHHmmss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    static func parseMinuteCandles(
        date: String,
        rows: [String],
        market: Market,
        period: CandlePeriod,
        now: Date = .now
    ) -> [Candle] {
        guard period.isIntraday else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = market.timeZone
        formatter.dateFormat = "yyyyMMdd HHmm"

        var minutes: [Candle] = []
        var previousCumulativeVolume = 0.0
        for row in rows {
            let fields = row.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3,
                  let parsedTime = formatter.date(from: "\(date) \(fields[0])"),
                  let price = Double(fields[1]), price > 0,
                  let cumulativeVolume = Double(fields[2]) else { continue }
            // Tencent labels the in-progress point with the minute bucket's end (e.g. 10:44 at 10:43:24).
            // Keep its freshest price, but display that provisional point at the actual fetch time.
            let lead = parsedTime.timeIntervalSince(now)
            let time = lead > 0 && lead <= 60 ? now : parsedTime
            let incrementalLots = max(cumulativeVolume - previousCumulativeVolume, 0)
            previousCumulativeVolume = cumulativeVolume
            minutes.append(Candle(
                time: time,
                open: price,
                high: price,
                low: price,
                close: price,
                volume: incrementalLots * 100
            ))
        }

        guard let span = period.intradayMinutes, span > 1 else { return minutes }
        let grouped = Dictionary(grouping: minutes) { candle in
            // Anchor buckets to each continuous exchange session. This makes an
            // A-share 60-minute bar start at 09:30/13:00 rather than the wall-clock
            // hour, and prevents a bucket from crossing the lunch break.
            let session = IntradayTradingSession(market: market, referenceDate: candle.time)
            let segments = [
                (session.open, session.morningEnd ?? session.close),
                session.afternoonStart.map { ($0, session.close) },
            ].compactMap { $0 }
            let segmentIndex = segments.firstIndex { segment in
                candle.time >= segment.0.addingTimeInterval(-60)
                    && candle.time <= segment.1.addingTimeInterval(60)
            } ?? 0
            let segment = segments[segmentIndex]
            let segmentMinutes = max(Int(segment.1.timeIntervalSince(segment.0) / 60), 1)
            let elapsed = max(Int(candle.time.timeIntervalSince(segment.0) / 60), 0)
            // A provider may stamp the closing sample exactly at 11:30/15:00.
            // Keep that sample in the final bucket instead of creating a one-point bar.
            let clampedElapsed = min(elapsed, segmentMinutes - 1)
            let bucket = clampedElapsed / span
            return "\(segment.0.timeIntervalSince1970)-\(segmentIndex)-\(bucket)"
        }
        return grouped.values.compactMap { group -> Candle? in
            let sorted = group.sorted { $0.time < $1.time }
            guard let first = sorted.first, let last = sorted.last else { return nil }
            return Candle(
                time: first.time,
                open: first.open,
                high: sorted.map(\.high).max() ?? first.high,
                low: sorted.map(\.low).min() ?? first.low,
                close: last.close,
                volume: sorted.compactMap(\.volume).reduce(0, +)
            )
        }
        .sorted { $0.time < $1.time }
    }
}

private struct MinuteResponse: Decodable {
    let code: Int
    let data: [String: SymbolPayload]?

    struct SymbolPayload: Decodable {
        let data: MinuteData
    }

    struct MinuteData: Decodable {
        let date: String
        let data: [String]
    }
}

/// A JSON scalar whose type the source is not consistent about: the real
/// responses quote the OHLC and volume as strings, but a number must not be
/// dropped if Tencent ever sends one.
private enum HistoryValue: Decodable {
    case string(String)
    case number(Double)
    case unusable

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else { self = .unusable }
    }

    var stringValue: String {
        switch self {
        case .string(let raw): raw
        case .number(let value): String(value)
        case .unusable: ""
        }
    }

    var doubleValue: Double? {
        switch self {
        case .string(let raw): Double(raw)
        case .number(let value): value
        case .unusable: nil
        }
    }
}

/// Skip an invalid row without discarding the other dates in the response.
private struct HistoryRow: Decodable {
    let values: [HistoryValue]

    init(from decoder: any Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            values = []
            return
        }
        var decoded: [HistoryValue] = []
        while !container.isAtEnd { decoded.append(try container.decode(HistoryValue.self)) }
        values = decoded
    }
}

private struct HistoricalResponse: Decodable {
    let code: Int
    let data: [String: SymbolPayload]?

    struct SymbolPayload: Decodable {
        let series: [String: [HistoryRow]]?

        /// Every other key (`qt`, `prec`, …) is metadata the chart does not use.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            var series: [String: [HistoryRow]] = [:]
            for key in container.allKeys {
                if let rows = try? container.decode([HistoryRow].self, forKey: key) {
                    series[key.stringValue] = rows
                }
            }
            self.series = series.isEmpty ? nil : series
        }
    }
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
