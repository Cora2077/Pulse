import Foundation
import PulseCore

/// Shares quote subscriptions and in-flight candle loads between detail views.
@MainActor
final class DetailMarketDataController {
    private struct Subscription {
        var id: UUID
        var referenceCount: Int
        var pollingTask: Task<Void, Never>?
    }

    private struct CandleRequestKey: Hashable {
        var symbol: SymbolID
        var period: CandlePeriod
        var count: Int
    }

    private struct CandleRequest {
        var id: UUID
        var task: Task<[Candle], Never>
    }

    private let provider: CompositeProvider
    private let engine: RefreshEngine
    private let market: MarketStore
    private let watchlist: WatchlistStore
    private let isDemo: Bool
    private let onQuote: (Quote) -> Void
    private let onInterestsChanged: (Set<SymbolID>) -> Void
    private var subscriptions: [SymbolID: Subscription] = [:]
    private var candleRequests: [CandleRequestKey: CandleRequest] = [:]

    init(
        provider: CompositeProvider,
        engine: RefreshEngine,
        market: MarketStore,
        watchlist: WatchlistStore,
        isDemo: Bool = false,
        onQuote: @escaping (Quote) -> Void,
        onInterestsChanged: @escaping (Set<SymbolID>) -> Void
    ) {
        self.provider = provider
        self.engine = engine
        self.market = market
        self.watchlist = watchlist
        self.isDemo = isDemo
        self.onQuote = onQuote
        self.onInterestsChanged = onInterestsChanged
    }

    /// Keeps one shared subscription alive until this caller's task is cancelled.
    public func run(symbol: SymbolID) async {
        guard !Task.isCancelled else { return }
        if isDemo {
            await waitUntilCancelled()
            return
        }
        acquire(symbol)
        defer { release(symbol) }

        await waitUntilCancelled()
    }

    private func waitUntilCancelled() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                break
            }
        }
    }

    /// Coalesces identical requests. The unstructured shared task is not
    /// cancelled when one detail view leaves while another still awaits it.
    public func loadCandles(symbol: SymbolID, period: CandlePeriod, count: Int) async -> [Candle] {
        if isDemo {
            return market.cachedCandles(
                for: CandleCacheKey(symbol: symbol, period: period),
                maxAge: .infinity
            ) ?? []
        }
        let key = CandleRequestKey(symbol: symbol, period: period, count: count)
        if let request = candleRequests[key] {
            return await request.task.value
        }

        let id = UUID()
        let task = Task { [engine] in
            await engine.loadCandles(for: symbol, period: period, count: count)
        }
        candleRequests[key] = CandleRequest(id: id, task: task)
        let candles = await task.value
        if candleRequests[key]?.id == id {
            candleRequests[key] = nil
        }
        return candles
    }

    private func acquire(_ symbol: SymbolID) {
        if var subscription = subscriptions[symbol] {
            subscription.referenceCount += 1
            subscriptions[symbol] = subscription
            return
        }

        let id = UUID()
        var subscription = Subscription(
            id: id,
            referenceCount: 1,
            pollingTask: nil
        )

        // The engine owns polling for watchlist members. Detail-only symbols
        // (including group-less active items) get this 15 second fallback; the
        // task rechecks membership so adding one hands polling to the engine.
        subscription.pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.subscriptions[symbol]?.id == id else { return }
                if !self.watchlist.symbols.contains(symbol),
                   let quotes = try? await self.provider.quotes(for: [symbol]),
                   !Task.isCancelled,
                   self.subscriptions[symbol]?.id == id,
                   !self.watchlist.symbols.contains(symbol) {
                    for quote in quotes where quote.symbol == symbol {
                        self.onQuote(quote)
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
            }
        }

        subscriptions[symbol] = subscription
        onInterestsChanged(Set(subscriptions.keys))
    }

    private func release(_ symbol: SymbolID) {
        guard var subscription = subscriptions[symbol] else { return }
        subscription.referenceCount -= 1
        guard subscription.referenceCount <= 0 else {
            subscriptions[symbol] = subscription
            return
        }
        subscription.pollingTask?.cancel()
        subscriptions[symbol] = nil
        onInterestsChanged(Set(subscriptions.keys))
    }
}
