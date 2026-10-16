import Foundation
import Testing
@testable import PulseCore

@Suite("Chinese names for Korean watchlist listings")
struct KoreanSecurityCatalogTests {
    private let samsung = SymbolID(market: .kr, code: "005930")
    private let hynix = SymbolID(market: .kr, code: "000660")

    @Test("Saved Hangul rows resolve to Chinese without a new identity or destructive migration")
    func savedRowsBecomeChinese() throws {
        let originals = [
            WatchItem(symbol: samsung, displayName: "삼성전자", instrumentType: .equity),
            WatchItem(symbol: hynix, displayName: "SK하이닉스", instrumentType: .equity),
        ]
        let data = try JSONEncoder().encode(originals)
        let decoded = try JSONDecoder().decode([WatchItem].self, from: data)
        #expect(decoded.map(\.resolvedDisplayName) == ["三星电子", "SK海力士"])
        #expect(decoded.map(\.symbol) == [samsung, hynix])
        // No stored user/account data is rewritten just to localize a label.
        #expect(decoded.map(\.displayName) == ["삼성전자", "SK하이닉스"])
        #expect(decoded.allSatisfy { $0.supportsPosition })
        #expect(decoded.allSatisfy { $0.resolvedInstrumentType == .equity })
    }

    @Test("Market and share-class boundaries are exact")
    func unrelatedSymbolsAreNotRenamed() {
        for symbol in [
            SymbolID(market: .sz, code: "000660"),
            SymbolID(market: .sh, code: "005930"),
            SymbolID(market: .kq, code: "005930"),
            SymbolID(market: .kr, code: "005935"),
            SymbolID(market: .us, code: "SK"),
            SymbolID(market: .kr, code: "105560"),
        ] {
            #expect(KoreanSecurityCatalog.displayName(for: symbol) == nil)
            let item = WatchItem(symbol: symbol, displayName: "原名")
            #expect(item.resolvedDisplayName == "原名")
        }
        #expect(KoreanSecurityCatalog.displayName(for: samsung) == "三星电子")
        #expect(KoreanSecurityCatalog.displayName(for: hynix) == "SK海力士")
    }

    @Test("Search and details use the same Chinese label whatever provider supplies the name")
    func providerIndependentDisplay() {
        for name in ["삼성전자", "Samsung Electronics Co., Ltd.", "005930"] {
            let result = SymbolInfo(symbol: samsung, name: name)
            #expect(result.resolvedDisplayName == "三星电子")
            #expect(result.symbol == samsung)
            #expect(result.symbol.currencyCode == "KRW")
            #expect(result.symbol.code == "005930")
        }
        let index = SymbolInfo(symbol: SymbolID(index: .kospi), name: "코스피", type: .index)
        #expect(index.resolvedDisplayName == "韩国综合指数")
    }

    @Test("Chinese English Hangul and exact exchange codes find the right listing")
    func aliases() {
        let cases: [(String, SymbolID)] = [
            ("三星", samsung), ("三星电子", samsung), ("三星電子", samsung),
            ("Samsung", samsung), ("samsung electronics", samsung), ("삼성전자", samsung),
            ("005930", samsung), ("005930.KS", samsung),
            ("海力士", hynix), ("SK海力士", hynix), ("sk hynix", hynix),
            ("SK하이닉스", hynix), ("000660", hynix), ("000660.KS", hynix),
            ("韩国股指", SymbolID(index: .kospi)), ("韩国综合指数", SymbolID(index: .kospi)),
            ("KOSPI", SymbolID(index: .kospi)),
        ]
        for (query, expected) in cases {
            let hits = KoreanSecurityCatalog.search(query)
            #expect(hits.first?.symbol == expected, "Wrong hit for \(query)")
            #expect(hits.allSatisfy { SecurityName.isChineseName($0.resolvedDisplayName) })
        }
        for query in ["", "S", "AAPL", "三星新材", "三星电气", "005935", "000660.SZ", "SKDD"] {
            #expect(KoreanSecurityCatalog.search(query).isEmpty, "Unexpected alias match: \(query)")
        }
    }

    @Test("Naver Chinese alias search never needs a Korean autocomplete request")
    func localSearchDoesNotFetch() async throws {
        let recorder = YahooRequestRecorder.install()
        let provider = NaverProvider(http: YahooRequestRecorder.httpClient(token: recorder.token))
        #expect(try await provider.search("三星").first?.symbol == samsung)
        #expect(try await provider.search("海力士").first?.symbol == hynix)
        #expect(recorder.recorded.isEmpty)
    }

    @Test("The real composite search can find Chinese names even without remote autocomplete")
    func compositeChineseSearch() async throws {
        let recorder = YahooRequestRecorder.install()
        let source = CompositeProvider(providers: [
            NaverProvider(http: YahooRequestRecorder.httpClient(token: recorder.token))
        ])
        let samsungHits = try await source.search("三星")
        let hynixHits = try await source.search("海力士")
        #expect(samsungHits.first?.resolvedDisplayName == "三星电子")
        #expect(hynixHits.first?.resolvedDisplayName == "SK海力士")
        #expect(samsungHits.first?.symbol == samsung)
        #expect(hynixHits.first?.symbol == hynix)
        #expect(recorder.recorded.isEmpty)
    }

    @Test("Quote fields are unchanged while display labels resolve to Chinese")
    func metadataAndPricesRemainSourceData() throws {
        let payload = Data(#"{"datas":[{"itemCode":"005930","stockName":"삼성전자","closePriceRaw":208500,"compareToPreviousClosePriceRaw":-23500,"localTradedAt":"2026-10-15T17:39:21+09:00"},{"itemCode":"000660","stockName":"SK하이닉스","closePriceRaw":1245000,"compareToPreviousClosePriceRaw":-174000,"localTradedAt":"2026-10-15T17:39:21+09:00"}]}"#.utf8)
        let quotes = try NaverProvider.parseQuotes(payload, requested: ["005930": samsung, "000660": hynix])
        #expect(quotes.count == 2)
        #expect(quotes.map(\.name) == ["삼성전자", "SK하이닉스"])
        #expect(quotes.map(\.price) == [208500, 1245000])
        #expect(quotes.map(\.previousClose) == [232000, 1419000])
        #expect(quotes.map { KoreanSecurityCatalog.displayName(for: $0.symbol) } == ["三星电子", "SK海力士"])
    }
}
