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
        var adjustment: CandleAdjustment
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
    public func loadCandles(symbol: SymbolID, period: CandlePeriod, count: Int, adjustment: CandleAdjustment = .none) async -> [Candle] {
        if isDemo {
            return market.cachedCandles(
                for: CandleCacheKey(symbol: symbol, period: period, adjustment: adjustment),
                maxAge: .infinity
            ) ?? []
        }
        let key = CandleRequestKey(symbol: symbol, period: period, count: count, adjustment: adjustment)
        if let request = candleRequests[key] {
            return await request.task.value
        }

        let id = UUID()
        let task = Task { [engine] in
            await engine.loadCandles(for: symbol, period: period, count: count, adjustment: adjustment)
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
        // follow their preferred source's cadence as well; adding a symbol to
        // the watchlist hands polling back to the engine.
        subscription.pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.subscriptions[symbol]?.id == id else { return }
                let startedAt = ContinuousClock.now
                let routing = await self.provider.quoteRouting(for: [symbol])
                let interval = routing.keys.first.map { self.engine.pollInterval(for: $0) } ?? 15
                guard !Task.isCancelled else { return }
                if !self.engine.writesHeld,
                   !self.watchlist.symbols.contains(symbol),
                   let quotes = try? await self.provider.refreshQuotes(for: [symbol]),
                   !Task.isCancelled,
                   !self.engine.writesHeld,
                   self.subscriptions[symbol]?.id == id,
                   !self.watchlist.symbols.contains(symbol) {
                    for quote in quotes where quote.symbol == symbol {
                        self.onQuote(quote)
                    }
                }
                do {
                    let elapsed = startedAt.duration(to: .now)
                    let remaining = Duration.seconds(interval) - elapsed
                    try await Task.sleep(for: max(.milliseconds(100), remaining))
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
