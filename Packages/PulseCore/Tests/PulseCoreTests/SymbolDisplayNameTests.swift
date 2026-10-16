import Foundation
import Testing
@testable import PulseCore

@Suite("Provider-independent symbol names")
struct SymbolDisplayNameTests {
    private struct RenamingQuoteProvider: QuoteProvider {
        var descriptor: ProviderDescriptor {
            ProviderDescriptor(
                id: "renaming",
                name: "Renaming",
                markets: [.us],
                capabilities: [.quotes]
            )
        }

        func search(_ query: String) async throws -> [SymbolInfo] {
            throw ProviderError.unsupported(.search)
        }

        func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
            symbols.map {
                Quote(
                    symbol: $0,
                    name: "PDD Holdings Inc.",
                    price: 120,
                    previousClose: 118
                )
            }
        }

        func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
            []
        }
    }

    @Test("Ordinary securities retain the name captured when added")
    func securityNameIsStable() {
        let pdd = SymbolID(market: .us, code: "PDD")
        let searchResult = SymbolInfo(symbol: pdd, name: "拼多多")
        let item = WatchItem(symbol: pdd, displayName: searchResult.resolvedDisplayName)

        #expect(searchResult.resolvedDisplayName == "拼多多")
        #expect(item.resolvedDisplayName == "拼多多")
    }

    @Test("Known indices ignore provider-specific spellings")
    func indexNamesComeFromCanonicalCatalog() {
        let symbol = SymbolID(index: .sp500)
        let yahoo = SymbolInfo(symbol: symbol, name: "S&P 500")
        let tencent = WatchItem(symbol: symbol, displayName: "标普500")

        #expect(yahoo.resolvedDisplayName == MarketIndexID.sp500.displayName)
        #expect(tencent.resolvedDisplayName == MarketIndexID.sp500.displayName)
    }

    @Test("Every canonical index has a real display name")
    func indexCatalogIsComplete() {
        for index in MarketIndexID.allCases {
            #expect(!index.displayName.isEmpty)
            #expect(!index.displayName.hasPrefix("index."))
            #expect(index.displayName != index.displayCode)
        }
    }

    @MainActor
    @Test("Quote refresh cannot overwrite a saved security name")
    func quoteRefreshDoesNotRenameWatchItem() async throws {
        let suiteName = "SymbolDisplayNameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pdd = SymbolID(market: .us, code: "PDD")
        let watchlist = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        watchlist.add(SymbolInfo(symbol: pdd, name: "拼多多"))
        let market = MarketStore()
        let composite = CompositeProvider(providers: [RenamingQuoteProvider()])
        let engine = RefreshEngine(provider: composite, store: market, watchlist: watchlist)
        engine.start()
        defer { engine.stop() }

        for _ in 0..<20 where market.quote(for: pdd) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(market.quote(for: pdd)?.name == "PDD Holdings Inc.")
        #expect(watchlist.item(for: pdd)?.displayName == "拼多多")
        #expect(watchlist.item(for: pdd)?.resolvedDisplayName == "拼多多")
    }

    @MainActor
    @Test("A name in the interface language wins; provider priority decides inside one language")
    func displayNameSourceOnlyUpgrades() throws {
        let suiteName = "SymbolNamePriorityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The interface ships Simplified Chinese, so "zh-Hans" is the locale that
        // leads. `outranks` is two keys in order: interface-language match first,
        // provider priority second.
        let pdd = SymbolID(market: .us, code: "PDD")
        let yahoo = DisplayNameSource(providerID: "yahoo", priority: 1, localeIdentifier: "en")
        let tencent = DisplayNameSource(providerID: "tencent", priority: 2, localeIdentifier: "zh-Hans")
        let longbridge = DisplayNameSource(
            providerID: LongbridgeProvider.providerID,
            priority: 0,
            localeIdentifier: "en"
        )
        let watchlist = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        watchlist.add(SymbolInfo(
            symbol: pdd,
            name: "PDD Holdings Inc.",
            displayNameSource: yahoo
        ))

        // The Chinese name is in the interface language and now outranks the
        // English one, even though Yahoo carries the better provider rank.
        #expect(watchlist.upgradeDisplayName(for: pdd, to: "拼多多", source: tencent))
        #expect(watchlist.item(for: pdd)?.displayName == "拼多多")

        // A better provider rank in the WRONG language no longer wins: Longbridge
        // is priority 0 but names US instruments in English.
        #expect(!watchlist.upgradeDisplayName(
            for: pdd,
            to: "PDD",
            source: longbridge,
            allowSameProviderRefresh: true
        ))
        #expect(watchlist.item(for: pdd)?.displayName == "拼多多")

        // Same language, same offer: the stored stamp must survive a reload.
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        #expect(reloaded.item(for: pdd)?.displayName == "拼多多")
        #expect(reloaded.item(for: pdd)?.displayNameSource == tencent)
    }

    @MainActor
    @Test("Locale match leads, then provider priority decides inside one language")
    func displayNameOutranksKeysInOrder() throws {
        let suiteName = "SymbolNameRankTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let aapl = SymbolID(market: .us, code: "AAPL")
        let yahoo = DisplayNameSource(providerID: "yahoo", priority: 1, localeIdentifier: "en")
        let longbridge = DisplayNameSource(
            providerID: LongbridgeProvider.providerID,
            priority: 0,
            localeIdentifier: "en"
        )
        let tencent = DisplayNameSource(providerID: "tencent", priority: 2, localeIdentifier: "zh-Hans")

        // Key 1 — a locale match beats a better provider priority, in both directions.
        #expect(tencent.outranks(yahoo))
        #expect(!yahoo.outranks(tencent))
        #expect(tencent.outranks(longbridge))
        #expect(!longbridge.outranks(tencent))

        // Key 2 — two names in the same language fall back to pure provider order.
        #expect(longbridge.outranks(yahoo))
        #expect(!yahoo.outranks(longbridge))
        #expect(!yahoo.outranks(yahoo))

        // A nil watermark is always replaceable.
        #expect(tencent.outranks(nil))

        // Same two keys once persisted: a same-language offer from a higher-priority
        // source still replaces, while a lower-priority one is refused.
        let watchlist = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        watchlist.add(SymbolInfo(symbol: aapl, name: "Apple Inc.", displayNameSource: yahoo))
        #expect(watchlist.upgradeDisplayName(
            for: aapl,
            to: "Apple",
            source: longbridge,
            allowSameProviderRefresh: true
        ))
        #expect(watchlist.item(for: aapl)?.displayNameSource == longbridge)
        // Then a locale-matching offer replaces even the better-ranked English one.
        #expect(watchlist.upgradeDisplayName(for: aapl, to: "苹果", source: tencent))
        #expect(watchlist.item(for: aapl)?.displayName == "苹果")
        #expect(watchlist.item(for: aapl)?.displayNameSource == tencent)

        // And the English fallback can no longer take the name back.
        #expect(!watchlist.upgradeDisplayName(for: aapl, to: "Apple Inc.", source: yahoo))
        #expect(watchlist.item(for: aapl)?.displayName == "苹果")
    }
}
