import Foundation

/// Provider-independent identity of a Tonghuashun (同花顺) industry board index.
///
/// These boards are the sector benchmarks Chinese traders actually quote
/// (`881155` 银行, `881273` 白酒, `881121` 半导体). They are not exchange
/// tickers: no exchange lists them, so an exchange symbol (`600519.SH`) cannot
/// address one, and every exchange source in Pulse answers `sh881155` with a
/// miss. The identity is therefore owned here, the way `MarketIndexID` and
/// `PreciousMetalID` already own indices and metals whose wire name differs per
/// vendor, and `ThsSectorProvider` maps it to the one wire form that has it.
///
/// A board carries the A-share market for its currency and session, not a claim
/// about a listing venue — the constituents are Shanghai and Shenzhen shares
/// together, and the board itself closes on the mainland calendar.
public struct SectorIndexID: Hashable, Sendable {
    /// Tonghuashun's own board code, e.g. `881155`. This is the wire code.
    public let code: String
    /// The board's name as Tonghuashun publishes it, e.g. `银行`.
    public let name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    // Names are reference data, not identity: a rename must not invalidate a
    // watchlist key, candle cache entry, or sync merge.
    public static func == (lhs: SectorIndexID, rhs: SectorIndexID) -> Bool {
        lhs.code == rhs.code
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(code)
    }

    /// Safe to interpolate into a THS board path, including a future catalog entry.
    var isValidWireCode: Bool {
        code.utf8.count == 6 && code.hasPrefix("88")
            && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    public var displayCode: String { code }

    /// Provider-independent name used everywhere Pulse presents the board. The
    /// name is the catalog's, so a source's spelling can never rename a saved row.
    public var displayName: String { name }

    /// The market whose currency and trading session the board follows.
    public var market: Market { .sh }

    /// Listing venue shown beside search results, the way an exchange name is.
    public static let exchangeName = "同花顺"

    /// Recognizes a board code Pulse itself may hand back. Only codes in the
    /// catalog resolve: a prefix rule would be cheaper, but it would also claim
    /// any future BSE ticker in the `88xxxx` range, so membership is exact.
    static func resolve(market: Market, code rawCode: String) -> SectorIndexID? {
        switch market {
        case .sh, .sz:
            // Either A-share board accepts the code; the catalog decides.
            return SectorIndexCatalog.board(code: rawCode)
        case .us, .hk, .crypto, .metal, .metalCN, .jp, .kr, .kq:
            return nil
        }
    }
}

extension SectorIndexID: Codable {
    private enum CodingKeys: String, CodingKey {
        case code
        case name
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let code = try values.decode(String.self, forKey: .code)
        guard SectorIndexID(code: code, name: code).isValidWireCode else {
            throw DecodingError.dataCorruptedError(
                forKey: .code, in: values, debugDescription: "Invalid THS board code"
            )
        }
        // A board written by a newer build may not be in this catalog. Keeping
        // its stored name shows the row instead of failing the whole snapshot.
        if let known = SectorIndexCatalog.board(code: code) {
            self = known
            return
        }
        self.init(code: code, name: try values.decodeIfPresent(String.self, forKey: .name) ?? code)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(code, forKey: .code)
        try values.encode(name, forKey: .name)
    }
}

/// Pulse's own index of Tonghuashun's industry boards.
///
/// Tonghuashun publishes no search API for them — `iwencai` answers 403 and the
/// quote pages are a script shell — so the only way "银行" can find `881155` is a
/// catalog the app carries itself, exactly as `PreciousMetalCatalog` does for the
/// international metals channel. Names and codes come from the live board
/// endpoint; `SectorIndexCatalogData` holds the list and this type decides what
/// matches a query.
public enum SectorIndexCatalog {
    /// One board's searchable surface: its code, its published name, and the
    /// extra words a user may type for it.
    struct Entry {
        let code: String
        let name: String
        var aliases: [String] = []
    }

    private static let boardsByCode: [String: SectorIndexID] = {
        var boards: [String: SectorIndexID] = [:]
        for entry in entries {
            boards[entry.code] = SectorIndexID(code: entry.code, name: entry.name)
        }
        return boards
    }()

    private static let aliasesByCode: [String: [String]] = {
        var aliases: [String: [String]] = [:]
        for entry in entries { aliases[entry.code] = entry.aliases }
        return aliases
    }()

    /// Every board, in catalog order (alphabetical by name, which is how
    /// Tonghuashun's own industry listing reads).
    public static let all: [SectorIndexID] = entries.compactMap { boardsByCode[$0.code] }

    public static func board(code rawCode: String) -> SectorIndexID? {
        boardsByCode[normalizedCode(rawCode)]
    }

    public static func board(named name: String) -> SectorIndexID? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return all.first { $0.name == target }
    }

    /// The category itself is a search term, and the only way to list the whole
    /// industry set — Tonghuashun ships no browse page Pulse can read.
    private static let categoryAliases: Set<String> = [
        "行业", "板塊", "板块", "行业板块", "行业指数", "同花顺行业", "同花顺板块",
        "INDUSTRY", "INDUSTRIES", "SECTOR", "SECTORS",
    ]

    public static func search(_ rawQuery: String) -> [SymbolInfo] {
        matches(rawQuery).map { board in
            SymbolInfo(
                symbol: SymbolID(sectorIndex: board),
                name: board.displayName,
                exchangeName: SectorIndexID.exchangeName,
                type: .index
            )
        }
    }

    static func matches(_ rawQuery: String) -> [SectorIndexID] {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return [] }
        // A single latin letter matches half the catalog by substring and reads
        // as noise; CJK characters are words, so one is enough to search on.
        guard query.count > 1 || !query.allSatisfy(\.isASCII) else { return [] }

        if categoryAliases.contains(query) { return all }

        // "银行指数" names the same board as "银行": dropping the word for the
        // instrument kind is what lets the everyday phrasing find it. The raw
        // form wins when both match, so an exact real name still ranks first.
        let variants = query == strippedKind(query) ? [query] : [query, strippedKind(query)]

        let ranked = all.enumerated().compactMap { index, board -> (Int, Int, SectorIndexID)? in
            let scores = variants.enumerated().compactMap { variant, text -> Int? in
                guard let score = bestScore(for: board, query: text) else { return nil }
                return score + variant
            }
            guard let score = scores.min() else { return nil }
            return (score, index, board)
        }
        return ranked
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
    }

    private static func bestScore(for board: SectorIndexID, query: String) -> Int? {
        if query.allSatisfy(\.isNumber) {
            if board.code == query { return 0 }
            return board.code.hasPrefix(query) ? 1 : nil
        }
        var scores = [matchScore(board.name, query)]
        scores.append(contentsOf: (aliasesByCode[board.code] ?? []).map { matchScore($0, query) })
        return scores.compactMap { $0 }.min()
    }

    private static func matchScore(_ value: String, _ query: String) -> Int? {
        let candidate = value.uppercased()
        if candidate == query { return 0 }
        if candidate.hasPrefix(query) { return 1 }
        return candidate.contains(query) ? 2 : nil
    }

    /// Reduces what the user typed to the board they named: the `bk_` prefix a
    /// provider URL carries, a pasted `.SH` / `.THS` suffix, and the words for
    /// the instrument kind all come off, so the tables only carry real names.
    private static func normalizedQuery(_ rawQuery: String) -> String {
        var query = normalizedCode(rawQuery)
        query = strippedKind(query)
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippedKind(_ value: String) -> String {
        var query = value
        for suffix in ["行业指数", "行业板块", "指數", "指数", "板块", "行业", "指数板块"] {
            if query.hasSuffix(suffix), query.count > suffix.count {
                query.removeLast(suffix.count)
            }
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedCode(_ rawCode: String) -> String {
        var code = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if code.hasPrefix("BK_") { code.removeFirst(3) }
        // Only recognized suffixes are aliases, never arbitrary path decoration.
        if let suffix = [".SH", ".SS", ".SZ", ".TI", ".THS"].first(where: code.hasSuffix) {
            code.removeLast(suffix.count)
        }
        return code
    }
}
