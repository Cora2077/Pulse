import Foundation

/// Fuyao (扶摇), Hithink/Tonghuashun's official A-share data service
/// (fuyao.aicubes.cn). BYOK: the user signs an API key with their Tonghuashun
/// account and every request carries it in `X-api-key`.
///
/// The service returns HTTP 200 for business errors too; the real outcome rides
/// the `code` field of a uniform ApiResponse envelope, so error mapping happens
/// on the envelope rather than the status line.
///
/// Three snapshot endpoints share one response shape, and which one an
/// instrument takes follows what it *is*, not which market it sits in: exchange
/// shares batch through `a-share`, index and Tonghuashun board codes batch
/// through `a-share-index`, and an ETF/LOF fund has a one-code endpoint of its
/// own. So `000001.SZ` (Ping An Bank) and `000001.SH` (the Shanghai Composite)
/// reach different URLs although they share a ticker; the meta lookup decides by
/// exact thscode and never by a prefix.
///
/// History is day-only. Actual-price callers default to `adjust=none`, while
/// historical charts explicitly request `forward` through a separate cache. The fund
/// history endpoint offers forward adjustment only, which would silently mix
/// adjusted closes into an unadjusted cache; fund candles are therefore left
/// unsupported here and the composite hands them to Tencent.
public actor FuyaoProvider: QuoteProvider {
    public static let providerID = "fuyao"
    static let baseURL = "https://fuyao.aicubes.cn"

    /// What a thscode is, as the meta endpoint classifies it. Unknown until that
    /// lookup answers, which is what keeps an index, a REIT and an exchange
    /// share from being mistaken for one another.
    enum AssetKind: String, Sendable {
        case aShare = "a-share"
        case fundETF = "fund-etf"
        case fundLOF = "fund-lof"
        case index = "a-share-index"

        var instrumentType: InstrumentType {
            switch self {
            case .aShare: .equity
            case .fundETF: .etf
            case .fundLOF: .fund
            case .index: .index
            }
        }

        /// A fund's history endpoint is forward-adjusted only.
        var isFund: Bool { self == .fundETF || self == .fundLOF }
    }

    /// Internal pacing configuration; fixtures can skip network-sized waits.
    struct RequestPacing: Sendable {
        static let production = RequestPacing(
            minInterval: 0.5,
            sleepsWhenPaced: true
        )

        var minInterval: TimeInterval
        var sleepsWhenPaced: Bool
    }

    struct CachedMeta: Sendable {
        let kind: AssetKind
        let name: String?
        let resolvedAt: Date
    }

    /// A classified thscode: the wire identity, what it is, and Pulse's identity.
    struct SearchMatch: Sendable {
        let thscode: String
        let kind: AssetKind
        let name: String
        let symbol: SymbolID

        var info: SymbolInfo {
            SymbolInfo(
                symbol: symbol,
                name: name.isEmpty ? symbol.displayCode : name,
                exchangeName: symbol.sectorIndex == nil ? symbol.market.displayName : SectorIndexID.exchangeName,
                type: kind.instrumentType
            )
        }
    }

    private let http: HTTPClient
    private let pacing: RequestPacing
    private let now: @Sendable () -> Date
    private var apiKey: String?
    private var metaCache: [String: CachedMeta] = [:]
    private var metaFailures: [String: Date] = [:]
    private var lastRequestStart: Date?
    private var activeQuoteOperations = 0
    var fundHoldingCodeCache: [String: (code: String, resolvedAt: Date)] = [:]

    public init(apiKey: String? = nil, http: HTTPClient = HTTPClient()) {
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.http = http
        self.pacing = .production
        self.now = { Date.now }
    }

    init(
        apiKey: String? = nil,
        http: HTTPClient = HTTPClient(),
        pacing: RequestPacing,
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.http = http
        self.pacing = pacing
        self.now = now
    }

    public func updateAPIKey(_ key: String?) {
        apiKey = key?.isEmpty == true ? nil : key
        // A lookup that failed under one key says nothing about the next.
        metaFailures.removeAll()
    }

    public nonisolated var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: Self.providerID,
            name: PulseLocalization.localizedString("provider.fuyao"),
            markets: [.sh, .sz],
            capabilities: [.quotes, .candles, .search, .referenceData],
            candlePeriods: [.day],
            delay: [.sh: 0, .sz: 0],
            // The service publishes dynamic rate limits, not a guaranteed QPS.
            // Pace every HTTP request, including internal metadata and fund fan-out.
            rateLimit: RateLimitPolicy(minInterval: 0.5, batchSize: 100),
            credentials: [CredentialField(key: "apiKey", label: "API Key")],
            // One-second polling; large mixed batches also obey request pacing.
            suggestedPollInterval: 1
        )
    }

    /// Exercises authentication and one snapshot round-trip when a key is saved.
    public func validateConnection() async throws {
        _ = try await quotes(for: [SymbolID(market: .sh, code: "600519")])
    }

    // MARK: - Symbol mapping

    /// Maps an identity this source can address to its thscode. Indices and
    /// boards answer through their semantic identities; a listing code stays a
    /// listing code until the meta lookup classifies it.
    static func thscode(for id: SymbolID) -> String? {
        guard id.market == .sh || id.market == .sz else { return nil }
        if let index = id.indexID {
            return switch index {
            case .shanghaiComposite: "000001.SH"
            case .shenzhenComponent: "399001.SZ"
            case .chiNext: "399006.SZ"
            default: nil
            }
        }
        if let board = id.sectorIndex {
            guard board.isValidWireCode else { return nil }
            return board.code + ".TI"
        }
        guard id.metalID == nil, id.cryptoPair == nil else { return nil }
        let code = id.code
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        // The metadata response decides the asset type. Prefix filters would
        // exclude exchange indices such as 000688.SH and newly listed funds.
        return code + (id.market == .sh ? ".SH" : ".SZ")
    }

    /// The Pulse identity of one search row. A `code.TI` row is a Tonghuashun
    /// board, and only when the source itself calls it an index.
    static func symbolID(fromThscode thscode: String, assetType: String?) -> SymbolID? {
        let parts = thscode.split(separator: ".")
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let code = String(parts[0])
        if parts[1] == "TI" {
            guard assetType == AssetKind.index.rawValue,
                  code.utf8.count == 6, code.hasPrefix("88"),
                  code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            let known = SectorIndexCatalog.board(code: code)
            return SymbolID(sectorIndex: SectorIndexID(code: code, name: known?.name ?? code))
        }
        let market: Market? = switch parts[1] {
        case "SH": .sh
        case "SZ": .sz
        default: nil  // BJ (Beijing Stock Exchange) has no Market case yet
        }
        guard let market else { return nil }
        // The suffix is what separates 000001.SH (the composite) from 000001.SZ
        // (Ping An Bank); a bare ticker would collapse the two into one identity.
        if let index = MarketIndexID.resolve(market: market, code: code), Self.isBenchmark(index) {
            return SymbolID(index: index)
        }
        return SymbolID(market: market, code: code)
    }

    static func symbolID(fromThscode thscode: String) -> SymbolID? {
        symbolID(fromThscode: thscode, assetType: nil)
    }

    public nonisolated func covers(_ symbol: SymbolID) -> Bool {
        Self.thscode(for: symbol) != nil
    }

    static func url(_ path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(string: Self.baseURL + path)!
        components.queryItems = query
        return components.url!
    }

    /// thscodes in wire order, each with the first identity that asked for it.
    static func uniqueThscodes(for symbols: [SymbolID]) -> [(thscode: String, symbol: SymbolID)] {
        var seen: Set<String> = []
        return symbols.compactMap { symbol in
            guard let thscode = thscode(for: symbol), seen.insert(thscode).inserted else { return nil }
            return (thscode, symbol)
        }
    }

    // MARK: - QuoteProvider

    public func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        activeQuoteOperations += 1
        defer { activeQuoteOperations -= 1 }
        let key = try requireKey()
        // Identity, not occurrence: a watchlist row repeated must not ask twice or
        // collide in a batch dictionary.
        var seen: Set<SymbolID> = []
        let unique = symbols.filter { seen.insert($0).inserted }
        let plans = try await snapshotPlans(for: unique, key: key)

        var rows: [SymbolID: (quote: Quote, timestamp: Date)] = [:]
        var lastError: (any Error)?
        var names: [SymbolID: String] = [:]
        for plan in plans {
            try Task.checkCancellation()
            do {
                let data = try await fetch(plan.scope.url, key: key)
                let timestamp = try Self.batchTimestamp(data: data, scope: plan.scope)
                let parsed = try Self.parseSnapshot(data: data)
                for (thscode, symbol) in plan.symbols {
                    if names[symbol] == nil { names[symbol] = cachedName(for: symbol) ?? "" }
                    guard let quote = parsed[thscode] else { continue }
                    // A symbol two endpoints answered (it should not happen) keeps
                    // the first answer rather than failing the batch.
                    rows[symbol] = rows[symbol] ?? (quote, timestamp)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // A quota refusal ends the batch; any other failure costs only the
                // symbols this endpoint carried, never the ones already answered.
                if Self.isQuotaRefusal(error) { throw error }
                lastError = error
            }
        }

        guard !rows.isEmpty else {
            if let lastError { throw lastError }
            // The envelope said code=0 and carried nothing: Fuyao does not have
            // these instruments, which is not a source failure.
            throw ProviderError.clientError(status: 200, detail: "fuyao: no quotes parsed (unknown symbols?)")
        }
        return unique.compactMap { symbol in
            guard var row = rows[symbol] else { return nil }
            row.quote.symbol = symbol
            row.quote.currencyCode = symbol.market.currencyCode
            row.quote.timestamp = row.timestamp
            // A known name is attached from the cache this call already consulted,
            // so a quote never waits on — or triggers — a name request per tick.
            if let name = names[symbol], !name.isEmpty { row.quote.name = name }
            return row.quote
        }
    }

    public func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        try await candles(for: symbol, period: period, count: count, adjustment: .none)
    }

    public func candles(for symbol: SymbolID, period: CandlePeriod, count: Int, adjustment: CandleAdjustment) async throws -> [Candle] {
        guard period == .day else { throw ProviderError.unsupported(.candles) }
        guard count > 0 else { return [] }
        guard let thscode = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        let key = try requireKey()
        let end = now()

        let url: URL
        switch try await resolvedKind(for: symbol, key: key) {
        case .fundETF, .fundLOF:
            // Fuyao's fund history is `adjust=forward` only; there is no unadjusted
            // variant to serve. Mixing it into the unadjusted candle cache would
            // move every historical price, so the composite falls back to Tencent.
            throw ProviderError.unsupported(.candles)
        case .index, .board:
            // This endpoint rejects `adjust` outright and reaches back five years.
            url = Self.indexHistoryURL(thscode: thscode, count: count, end: end)
        case .aShare:
            url = Self.shareHistoryURL(thscode: thscode, count: count, end: end, adjustment: adjustment)
        case .unresolved:
            throw ProviderError.symbolNotFound(symbol)
        }
        let data = try await fetch(url, key: key)
        return try Self.finishCandles(data: data, count: count, symbol: symbol)
    }

    public func search(_ query: String) async throws -> [SymbolInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let key = try requireKey()
        let url = Self.url("/api/meta/tickers/search", query: [
            // Exchange-traded instruments and the index/board codes; an untyped
            // search mixes those into the ticker space.
            .init(name: "q", value: trimmed),
            .init(name: "asset_type", value: "a-share,fund-etf,fund-lof,a-share-index"),
            .init(name: "limit", value: "20"),
        ])
        let data = try await fetch(url, key: key)
        let matches = try Self.parseSearch(data: data)
        // Search warms the same cache the quote path resolves through, so adding a
        // result never costs a second lookup to learn what it is.
        absorb(matches)
        return matches.map { match in
            var info = match.info
            // A board the catalog already carries keeps the catalog's spelling, the
            // way `SectorIndexCatalog.search` presents it.
            if let known = info.symbol.sectorIndex.flatMap({ SectorIndexCatalog.board(code: $0.code) }) {
                info.name = known.displayName
            }
            return info
        }
    }

    /// Names for instruments Fuyao can address. A benchmark's or a board's name
    /// is Pulse's own catalog spelling; anything else comes from the meta cache,
    /// so a one-second quote cadence does not mean a name request per tick.
    public func securityNames(for symbols: [SymbolID]) async throws -> [SecurityName] {
        try Task.checkCancellation()
        var names: [SecurityName] = []
        var seen: Set<SymbolID> = []
        var lookup: [SymbolID] = []
        for symbol in symbols where seen.insert(symbol).inserted {
            if let index = symbol.indexID, let name = Self.localizedName(for: index) {
                names.append(SecurityName(symbol: symbol, name: name, localeIdentifier: "zh-Hans"))
            } else if let board = symbol.sectorIndex {
                names.append(SecurityName(symbol: symbol, name: board.displayName, localeIdentifier: "zh-Hans"))
            } else {
                lookup.append(symbol)
            }
        }

        if !lookup.isEmpty {
            let key = try requireKey()
            var lastError: (any Error)?
            for (thscode, symbol) in Self.uniqueThscodes(for: lookup) {
                try Task.checkCancellation()
                do {
                    guard let match = try await resolveMeta(thscode: thscode, key: key)
                    else { continue }  // The source has no row: an answer, not a failure.
                    if let name = Self.resolvedName(match, symbol: symbol) {
                        names.append(SecurityName(symbol: symbol, name: name, localeIdentifier: "zh-Hans"))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    if Self.isQuotaRefusal(error) { throw error }
                    lastError = error
                }
            }
            if names.isEmpty, let lastError { throw lastError }
        }
        guard !names.isEmpty else { throw ProviderError.unsupported(.referenceData) }
        return names
    }

    private static func localizedName(for index: MarketIndexID) -> String? {
        switch index {
        case .shanghaiComposite, .shenzhenComponent, .chiNext: index.displayName
        default: nil
        }
    }

    private func requireKey() throws -> String {
        guard let apiKey else {
            // Not a source failure: routing normally keeps an unconfigured Fuyao
            // disabled, so this only answers stray direct calls.
            throw ProviderError.clientError(status: 401, detail: "fuyao: no API key configured")
        }
        return apiKey
    }

    /// Research uses the same credential and request pacing as live quotes.
    /// Callers decode the business envelope before exposing any result.
    func fetchResearchData(path: String, query: [URLQueryItem] = []) async throws -> Data {
        let key = try requireKey()
        return try await fetch(Self.url(path, query: query), key: key, isResearch: true)
    }

    public func researchInstrumentType(for symbol: SymbolID) async throws -> InstrumentType? {
        let kind = try await resolvedKind(for: symbol, key: requireKey())
        switch kind {
        case .aShare: return .equity
        case .fundETF: return .etf
        case .fundLOF: return .fund
        case .index, .board: return .index
        case .unresolved: return nil
        }
    }

    // MARK: - Pacing

    /// Every request this actor makes goes through here, so the minimum spacing
    /// holds for the composite's calls and for the internal fan-out alike — the
    /// composite only paces whole calls. The slot is claimed only once the
    /// caller is ready to send, and a cancelled caller leaves no reservation
    /// behind for the next one to wait out.
    private func fetch(_ url: URL, key: String, isResearch: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        while true {
            // Research yields the next slot to an in-flight quote operation,
            // including its metadata/fund fan-out. It never queues ahead of
            // every-second quotes merely because a large board was opened.
            if isResearch, activeQuoteOperations > 0 {
                try await Task.sleep(for: .milliseconds(25))
                try Task.checkCancellation()
                continue
            }
            guard let last = lastRequestStart, pacing.minInterval > 0 else { break }
            let wait = pacing.minInterval - now().timeIntervalSince(last)
            if wait > 0 {
                guard pacing.sleepsWhenPaced else {
                    throw ProviderError.badResponse("fuyao: test pacing exceeded")
                }
                try await Task.sleep(for: .seconds(wait))
                try Task.checkCancellation()
            } else {
                break
            }
        }
        lastRequestStart = now()
        return try await http.get(url, headers: ["X-api-key": key])
    }

    /// A 429 or a quota refusal: retrying into it is the storm the batch stops on.
    static func isQuotaRefusal(_ error: any Error) -> Bool {
        guard let providerError = error as? ProviderError else { return false }
        return switch providerError {
        case .rateLimited: true
        case .clientError(_, let detail): detail.hasPrefix("fuyao") && detail.contains("code 4001")
        default: false
        }
    }

    // MARK: - Routing and meta classification

    /// How an instrument is quoted or historied. Unlike `AssetKind` it also
    /// covers the semantic identities and the instrument the lookup could not
    /// place.
    enum ResolvedKind: Sendable {
        case aShare
        case fundETF
        case fundLOF
        case index
        case board
        /// Metadata could not identify this instrument; let another source serve it.
        case unresolved

        var assetKind: AssetKind {
            switch self {
            case .fundETF: .fundETF
            case .fundLOF: .fundLOF
            case .index, .board: .index
            case .aShare, .unresolved: .aShare
            }
        }
    }

    /// One endpoint's share of a batch: which thscodes it asks for as a
    /// comma-separated list (or one fund's single code), and the Pulse identity
    /// each thscode answers as.
    struct Scope: Hashable, Sendable {
        enum Group: Hashable, Sendable { case shares, indices, fund }

        let group: Group
        let codes: [String]

        /// One request however many codes it carries: the 100-symbol batch ceiling
        /// keeps the query string well short of any URL limit, so the spacing —
        /// not the request size — is what paces this source.
        var url: URL {
            switch group {
            case .shares:
                FuyaoProvider.url("/api/a-share/prices/snapshot", query: [.init(name: "thscodes", value: codes.joined(separator: ","))])
            case .indices:
                FuyaoProvider.url("/api/a-share-index/prices/snapshot", query: [.init(name: "thscodes", value: codes.joined(separator: ","))])
            case .fund:
                FuyaoProvider.url("/api/fund/market/snapshot", query: [.init(name: "thscode", value: codes[0])])
            }
        }
    }

    struct SnapshotPlan: Sendable {
        let scope: Scope
        let symbols: [(thscode: String, symbol: SymbolID)]
    }

    /// Groups a batch by endpoint: shares on `a-share`, indices and boards on
    /// `a-share-index`, every fund on a request of its own — so one fund's
    /// failure costs only that fund. Every underlying request is paced.
    private func snapshotPlans(for symbols: [SymbolID], key: String) async throws -> [SnapshotPlan] {
        var shares: [(String, SymbolID)] = []
        var indexRouting: [(String, SymbolID)] = []
        var funds: [(String, SymbolID, AssetKind)] = []
        var claimed: Set<String> = []
        var lastError: (any Error)?

        for symbol in symbols {
            try Task.checkCancellation()
            guard let thscode = Self.thscode(for: symbol), claimed.insert(thscode).inserted else { continue }
            if symbol.sectorIndex != nil || Self.isBenchmark(symbol) {
                indexRouting.append((thscode, symbol))
                continue
            }
            let kind: ResolvedKind
            if let cached = cachedKind(for: symbol) {
                kind = cached
            } else {
                do {
                    kind = try await resolvedKind(for: symbol, key: key)
                } catch {
                    try Task.checkCancellation()
                    if Self.isQuotaRefusal(error) { throw error }
                    lastError = error
                    continue
                }
            }
            switch kind {
            case .board, .index:
                indexRouting.append((thscode, symbol))
            case .fundETF, .fundLOF:
                funds.append((thscode, symbol, kind.assetKind))
            case .aShare:
                shares.append((thscode, symbol))
            case .unresolved:
                continue
            }
        }

        var plans: [SnapshotPlan] = []
        for batch in shares.chunked(into: 100) {
            plans.append(SnapshotPlan(
                scope: Scope(group: .shares, codes: Self.uniqueCodes(batch)),
                symbols: batch
            ))
        }
        for batch in indexRouting.chunked(into: 100) {
            plans.append(SnapshotPlan(
                scope: Scope(group: .indices, codes: Self.uniqueCodes(batch)),
                symbols: batch
            ))
        }
        for fund in funds {
            plans.append(SnapshotPlan(
                scope: Scope(group: .fund, codes: [fund.0]),
                symbols: [(fund.0, fund.1)]
            ))
        }
        if plans.isEmpty, let lastError { throw lastError }
        return plans
    }

    private static func uniqueCodes(_ entries: [(String, SymbolID)]) -> [String] {
        var seen: Set<String> = []
        return entries.compactMap { seen.insert($0.0).inserted ? $0.0 : nil }
    }

    private static func isBenchmark(_ symbol: SymbolID) -> Bool {
        symbol.indexID.map(isBenchmark) ?? false
    }

    static func isBenchmark(_ index: MarketIndexID) -> Bool {
        switch index {
        case .shanghaiComposite, .shenzhenComponent, .chiNext: true
        default: false
        }
    }

    private func cachedKind(for symbol: SymbolID) -> ResolvedKind? {
        if let board = symbol.sectorIndex, board.isValidWireCode { return .board }
        if Self.isBenchmark(symbol) { return .index }
        guard let thscode = Self.thscode(for: symbol),
              let cached = metaCache[thscode],
              now().timeIntervalSince(cached.resolvedAt) < Self.metaTTL else { return nil }
        return Self.resolvedKind(of: cached.kind, thscode: thscode)
    }

    private static func resolvedKind(of kind: AssetKind, thscode: String) -> ResolvedKind {
        switch kind {
        case .aShare: .aShare
        case .fundETF: .fundETF
        case .fundLOF: .fundLOF
        case .index: thscode.hasSuffix(".TI") ? .board : .index
        }
    }

    /// The cached answer, or one exact search. A miss is remembered briefly as a
    /// miss; a failed lookup is never remembered as a classification.
    private func resolvedKind(for symbol: SymbolID, key: String) async throws -> ResolvedKind {
        if let cached = cachedKind(for: symbol) { return cached }
        guard let thscode = Self.thscode(for: symbol) else { throw ProviderError.symbolNotFound(symbol) }
        if isRecentlyUnresolved(thscode) { return .unresolved }
        guard let match = try await resolveMeta(thscode: thscode, key: key) else {
            return .unresolved
        }
        return Self.resolvedKind(of: match.kind, thscode: thscode)
    }

    private func isRecentlyUnresolved(_ thscode: String) -> Bool {
        guard let failedAt = metaFailures[thscode] else { return false }
        return now().timeIntervalSince(failedAt) < Self.metaFailureTTL
    }

    /// One exact search for `thscode`, cached for a day. Only a row whose
    /// thscode matches exactly is taken, so a prefix hit on another instrument
    /// — a REIT for a fund query, say — can never reclassify this one.
    private func resolveMeta(thscode: String, key: String) async throws -> SearchMatch? {
        if let cached = metaCache[thscode], now().timeIntervalSince(cached.resolvedAt) < Self.metaTTL,
           let symbol = Self.symbolID(fromThscode: thscode, assetType: cached.kind.rawValue) {
            return SearchMatch(thscode: thscode, kind: cached.kind, name: cached.name ?? "", symbol: symbol)
        }
        if isRecentlyUnresolved(thscode) { return nil }
        let url = Self.url("/api/meta/tickers/search", query: [
            .init(name: "q", value: thscode),
            .init(name: "limit", value: "1"),
        ])
        let data: Data
        do {
            data = try await fetch(url, key: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw error
        }
        let matches = try Self.parseSearch(data: data)
        guard let exact = matches.first(where: { $0.thscode == thscode }) else {
            // Not a failure: the source simply has no exact row for it.
            metaFailures[thscode] = now()
            return nil
        }
        metaCache[thscode] = CachedMeta(kind: exact.kind, name: exact.name.nilIfEmpty, resolvedAt: now())
        metaFailures[thscode] = nil
        return exact
    }

    /// The name a resolved row gives an instrument. A board's published name only
    /// stands in when Pulse's own catalog does not carry that board: a rename must
    /// not ripple through saved rows, which is the catalog's job to decide.
    private static func resolvedName(_ match: SearchMatch, symbol: SymbolID) -> String? {
        guard let board = symbol.sectorIndex ?? match.symbol.sectorIndex else {
            return match.name.isEmpty ? nil : match.name
        }
        if let known = SectorIndexCatalog.board(code: board.code) { return known.displayName }
        return match.name.isEmpty ? nil : match.name
    }

    private func cachedName(for symbol: SymbolID) -> String? {
        if let index = symbol.indexID { return Self.localizedName(for: index) }
        if let board = symbol.sectorIndex { return board.displayName }
        guard let thscode = Self.thscode(for: symbol),
              let cached = metaCache[thscode],
              now().timeIntervalSince(cached.resolvedAt) < Self.metaTTL,
              let name = cached.name, !name.isEmpty else { return nil }
        return name
    }

    private func absorb(_ matches: [SearchMatch]) {
        for match in matches {
            metaCache[match.thscode] = CachedMeta(
                kind: match.kind, name: match.name.nilIfEmpty, resolvedAt: now()
            )
            metaFailures[match.thscode] = nil
        }
    }

    static func parseSearch(data: Data) throws -> [SearchMatch] {
        let payload = try decodePayload(SearchPayload.self, from: data, endpoint: "search")
        return (payload.item ?? []).compactMap { item in
            guard let kind = AssetKind(rawValue: item.assetType ?? ""),
                  var symbol = symbolID(fromThscode: item.thscode, assetType: item.assetType) else {
                return nil
            }
            if let board = symbol.sectorIndex, SectorIndexCatalog.board(code: board.code) == nil {
                symbol = SymbolID(sectorIndex: SectorIndexID(code: board.code, name: item.name))
            }
            return SearchMatch(thscode: item.thscode, kind: kind, name: item.name, symbol: symbol)
        }
    }

    // MARK: - History plan

    /// Day bars for one share, with an explicit price basis.
    static func shareHistoryURL(thscode: String, count: Int, end: Date, adjustment: CandleAdjustment = .none) -> URL {
        let (start, stop) = historyWindow(count: count, end: end, maxDays: Self.shareHistoryMaxDays)
        return url("/api/a-share/prices/historical", query: [
            .init(name: "thscode", value: thscode),
            .init(name: "interval", value: "1d"),
            .init(name: "start", value: milliseconds(start)),
            .init(name: "end", value: milliseconds(stop)),
            .init(name: "adjust", value: adjustment.rawValue),
        ])
    }

    /// Day bars for an index or a board. This endpoint rejects `adjust`
    /// altogether — sending one fails the request — and reaches back five years.
    static func indexHistoryURL(thscode: String, count: Int, end: Date) -> URL {
        let (start, stop) = historyWindow(count: count, end: end, maxDays: Self.indexHistoryMaxDays)
        return url("/api/a-share-index/prices/historical", query: [
            .init(name: "thscode", value: thscode),
            .init(name: "interval", value: "1d"),
            .init(name: "start", value: milliseconds(start)),
            .init(name: "end", value: milliseconds(stop)),
        ])
    }

    /// Trading days are roughly 70% of calendar days; double plus slack keeps
    /// `count` bars through holidays, within what the endpoint will serve.
    static func historyWindow(count: Int, end: Date, maxDays: Double) -> (Date, Date) {
        let spanDays = min(max(Double(count) * 2 + 30, 30), maxDays)
        return (end.addingTimeInterval(-spanDays * 86_400), end)
    }

    static let shareHistoryMaxDays: Double = 3600
    static let indexHistoryMaxDays: Double = 1820

    static func milliseconds(_ date: Date) -> String {
        String(Int((date.timeIntervalSince1970 * 1000).rounded()))
    }

    static func finishCandles(data: Data, count: Int, symbol: SymbolID) throws -> [Candle] {
        let candles = try parseCandles(data: data)
        guard !candles.isEmpty else { throw ProviderError.symbolNotFound(symbol) }
        return Array(candles.suffix(count))
    }

    // MARK: - Envelope

    struct Envelope<Payload: Decodable>: Decodable {
        let code: Int
        let message: String?
        let data: Payload?
    }

    struct SnapshotPayload: Decodable {
        let timestamp: Double?
        let item: [SnapshotItem]?
    }

    struct SnapshotItem: Decodable {
        let thscode: String
        let lastPrice: Double?
        let prevPrice: Double?
        let openPrice: Double?
        let highPrice: Double?
        let lowPrice: Double?
        let volume: Double?
        let turnover: Double?
    }

    struct HistoricalPayload: Decodable {
        let item: [BarItem]?
    }

    struct BarItem: Decodable {
        let dateMs: Double
        let openPrice: Double?
        let highPrice: Double?
        let lowPrice: Double?
        let closePrice: Double?
        let volume: Double?
    }

    struct SearchPayload: Decodable {
        let item: [TickerItem]?
    }

    struct TickerItem: Decodable {
        let thscode: String
        let name: String
        let exchange: String?
        let assetType: String?
    }

    /// Decodes the uniform ApiResponse envelope and maps business error codes onto
    /// ProviderError; only quota (4001) and upstream failures (5xxx) may trip the
    /// circuit breaker.
    static func decodePayload<Payload: Decodable>(
        _ type: Payload.Type,
        from data: Data,
        endpoint: String
    ) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope: Envelope<Payload>
        do {
            envelope = try decoder.decode(Envelope<Payload>.self, from: data)
        } catch {
            throw ProviderError.badResponse("fuyao \(endpoint): \(error.localizedDescription)")
        }
        guard envelope.code == 0 else {
            throw providerError(code: envelope.code, message: envelope.message, endpoint: endpoint)
        }
        guard let payload = envelope.data else {
            throw ProviderError.badResponse("fuyao \(endpoint): success without data")
        }
        return payload
    }

    static func providerError(code: Int, message: String?, endpoint: String) -> ProviderError {
        let detail = "fuyao \(endpoint): code \(code) \(message ?? "")"
        return switch code {
        case 4001: .rateLimited
        // 2004 means the endpoint exists but will not serve this request on this
        // plan (a fund history call, say). It is a property of the request, not
        // of the source: tripping the breaker would take every A-share quote offline.
        case 2004: .clientError(status: 403, detail: detail)
        case 1001...1999: .clientError(status: 400, detail: detail)
        case 2001, 2003: .clientError(status: 401, detail: detail)
        case 3001...3999: .clientError(status: 404, detail: detail)
        default: .badResponse(detail)
        }
    }

    // MARK: - Parsing

    /// A snapshot response's rows by thscode. What each thscode *is* was decided
    /// when the batch was planned — the wire suffix alone does not say whether
    /// `000001.SH` is the composite or a share — so a row becomes a quote only
    /// when the plan asked for its thscode, and it is joined to the planned
    /// identity there.
    static func parseSnapshot(data: Data) throws -> [String: Quote] {
        let payload = try decodePayload(SnapshotPayload.self, from: data, endpoint: "snapshot")
        var rows: [String: Quote] = [:]
        // A duplicated row (the API normally sends none) is answered once.
        for item in payload.item ?? [] where rows[item.thscode] == nil {
            guard let quote = Self.quote(from: item) else { continue }
            rows[item.thscode] = quote
        }
        return rows
    }

    /// The batch's upstream-readiness time, for the whole response rather than
    /// each instrument's last trade. Missing, zero, negative or non-finite means
    /// the batch carries no usable time, and none of it becomes a quote rather
    /// than being stamped `now` and read as fresh.
    static func batchTimestamp(data: Data, scope: Scope) throws -> Date {
        let payload = try decodePayload(SnapshotPayload.self, from: data, endpoint: "snapshot")
        guard let timestamp = batchTimestamp(payload.timestamp) else {
            throw ProviderError.badResponse("fuyao snapshot: no usable timestamp for \(scope.codes.joined(separator: ","))")
        }
        return timestamp
    }

    static func batchTimestamp(_ raw: Double?) -> Date? {
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        let seconds = raw / 1000
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A row with no price, no previous close, or a non-finite value in any
    /// field is not a quote: a NaN or infinity must never reach a portfolio cache.
    private static func quote(from item: SnapshotItem) -> Quote? {
        guard let price = positive(item.lastPrice),
              let prevClose = positive(item.prevPrice) else { return nil }
        return Quote(
            // Replaced by the caller with the identity the batch was planned for.
            symbol: SymbolID(market: .sh, code: item.thscode),
            price: price,
            previousClose: prevClose,
            open: positive(item.openPrice),
            high: positive(item.highPrice),
            low: positive(item.lowPrice),
            volume: nonNegative(item.volume),
            turnover: nonNegative(item.turnover),
            currencyCode: nil,
            // Replaced by the batch timestamp; never left as a claim of its own.
            timestamp: .distantPast
        )
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func nonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func parseCandles(data: Data) throws -> [Candle] {
        let payload = try decodePayload(HistoricalPayload.self, from: data, endpoint: "historical")
        return (payload.item ?? []).compactMap { bar -> Candle? in
            guard bar.dateMs.isFinite, bar.dateMs > 0,
                  let open = positive(bar.openPrice), let high = positive(bar.highPrice),
                  let low = positive(bar.lowPrice), let close = positive(bar.closePrice),
                  high >= max(open, close), low <= min(open, close) else { return nil }
            return Candle(
                time: Date(timeIntervalSince1970: bar.dateMs / 1000),
                open: open,
                high: high,
                low: low,
                close: close,
                volume: nonNegative(bar.volume)
            )
        }
        .sorted { $0.time < $1.time }
    }

    static let metaTTL: TimeInterval = 24 * 60 * 60
    /// How long a symbol the source has no exact answer for stays unresolved.
    static let metaFailureTTL: TimeInterval = 60
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
