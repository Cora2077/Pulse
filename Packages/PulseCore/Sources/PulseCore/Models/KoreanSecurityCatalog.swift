import Foundation

/// Chinese presentation names and search aliases for a small, explicit set of
/// Korean listings. This is reference data, not a new instrument identity: the
/// exchange and six-character code remain the watchlist/cache/persistence key.
public enum KoreanSecurityCatalog {
    private struct Entry: Sendable {
        let symbol: SymbolID
        let name: String
        let aliases: [String]
        let type: InstrumentType
    }

    private static let entries: [Entry] = [
        Entry(
            symbol: SymbolID(market: .kr, code: "005930"), name: "三星电子",
            aliases: ["三星", "三星电子", "三星電子", "SAMSUNG", "SAMSUNG ELECTRONICS", "삼성", "삼성전자"],
            type: .equity
        ),
        Entry(
            symbol: SymbolID(market: .kr, code: "000660"), name: "SK海力士",
            aliases: ["海力士", "SK海力士", "SK HYNIX", "HYNIX", "SK하이닉스", "하이닉스"],
            type: .equity
        ),
        Entry(
            symbol: SymbolID(index: .kospi), name: MarketIndexID.kospi.displayName,
            aliases: ["韩国指数", "韩国股指", "韩国大盘", "韩国综合指数", "韓國綜合指數", "KOSPI", "코스피"],
            type: .index
        ),
    ]

    /// Exact market + code matching prevents the Shenzhen `000660`, Samsung's
    /// preferred share `005935`, or an unrelated ETF from being relabelled.
    public static func displayName(for symbol: SymbolID) -> String? {
        entries.first { $0.symbol == symbol }?.name
    }

    public static func search(_ rawQuery: String) -> [SymbolInfo] {
        let query = normalized(rawQuery)
        guard !query.isEmpty, query.count > 1 || !query.allSatisfy(\.isASCII) else { return [] }
        let matches = entries.enumerated().compactMap { index, entry -> (Int, Int, Entry)? in
            let terms = [entry.name, entry.symbol.code, entry.symbol.description] + entry.aliases
            let score = terms.compactMap { value -> Int? in
                let term = normalized(value)
                if term == query { return 0 }
                if term.hasPrefix(query) { return 1 }
                if term.contains(query) { return 2 }
                return nil
            }.min()
            guard let score else { return nil }
            return (score, index, entry)
        }
        return matches.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { _, _, entry in
            SymbolInfo(
                symbol: entry.symbol, name: entry.name,
                exchangeName: "KRX · KOSPI", type: entry.type
            )
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().filter { !$0.isWhitespace }
    }
}
