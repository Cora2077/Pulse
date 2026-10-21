import Foundation
import Testing
@testable import PulseCore

// MARK: - Controllable clock

/// A hand-driven clock for the refresh engine: the scheduler reads `now()` and
/// sleeps against `sleep`, both injected. Nothing here touches a real time or network.
@MainActor
final class ManualRefreshClock {
    private(set) var date = Date(timeIntervalSince1970: 1_792_461_600)
    private var waiters: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = [:]

    func now() -> Date { date }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let seconds = TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
        let deadline = date.addingTimeInterval(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = (deadline, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Moves time forward and releases every sleep that is now due.
    func advance(by seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
        for (id, waiter) in waiters where waiter.deadline <= date {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    /// Releases every pending sleep without moving time (a wake).
    func wakeAll() {
        for (id, waiter) in waiters {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    var isIdle: Bool { waiters.isEmpty }
}

// MARK: - Synthesized sources

/// A source that answers quotes from its own price script and counts every call.
/// An actor, like the real network-backed sources, so CompositeProvider's calls
/// are exactly as delayed against it as against them.
actor ScriptedQuoteSource: QuoteProvider {
    nonisolated let id: String
    nonisolated let markets: Set<Market>
    let descriptor: ProviderDescriptor

    private var nextPrice: Double
    private var nextCallError: (any Error)?
    private var quoteDelay: TimeInterval?
    private var wrapsCancellation = false
    private(set) var quoteCalls = 0

    init(id: String, price: Double = 100, markets: Set<Market> = [.sh]) {
        self.id = id
        self.markets = markets
        self.nextPrice = price
        descriptor = ProviderDescriptor(
            id: id,
            name: id,
            markets: markets,
            capabilities: [.quotes, .candles],
            candlePeriods: [.day],
            delay: Dictionary(uniqueKeysWithValues: markets.map { ($0, 0) }),
            suggestedPollInterval: 15
        )
    }

    func setDelay(_ delay: TimeInterval?) { quoteDelay = delay }
    func wrapCancellation() { wrapsCancellation = true }

    func failNextQuote(with error: any Error) { nextCallError = error }

    func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
        quoteCalls += 1
        if let error = nextCallError {
            nextCallError = nil
            throw error
        }
        let price = nextPrice
        nextPrice += 1
        if let quoteDelay {
            do { try await Task.sleep(for: .seconds(quoteDelay)) }
            catch {
                if wrapsCancellation { throw ProviderError.network(underlying: "cancelled") }
                throw error
            }
        }
        try Task.checkCancellation()
        return symbols.map { Quote(symbol: $0, price: price, previousClose: price - 1) }
    }

    func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        [Candle(time: Date(timeIntervalSince1970: 1_760_000_000), open: 1, high: 1, low: 1, close: 1)]
    }

    func search(_ query: String) async throws -> [SymbolInfo] { [] }
}

/// Quote calls are slow (4s) and candle calls slower still (2s), so a test can see
/// one still in flight while faster sources keep starting rounds.
final class SlowWorkSource: QuoteProvider {
    let id: String
    private let state = SlowWorkState()

    init(id: String) { self.id = id }

    var quoteCalls: Int { get async { await state.quoteCalls } }
    var candleCalls: Int { get async { await state.candleCalls } }
    var isInFlight: Bool { get async { await state.inFlight } }

    nonisolated var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            name: id,
            markets: [.sz],
            capabilities: [.quotes, .candles]
        )
    }

    func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
        await state.beginQuote()
        defer { Task { await state.endQuote() } }
        try await Task.sleep(for: .seconds(4))
        try Task.checkCancellation()
        return symbols.map { Quote(symbol: $0, price: 3, previousClose: 2) }
    }

    func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        await state.beginCandle()
        try await Task.sleep(for: .seconds(2))
        try Task.checkCancellation()
        return [Candle(time: .now, open: 1, high: 1, low: 1, close: 1)]
    }

    func search(_ query: String) async throws -> [SymbolInfo] { [] }
}

private actor SlowWorkState {
    private(set) var quoteCalls = 0
    private(set) var candleCalls = 0
    private(set) var inFlight = false
    func beginQuote() { quoteCalls += 1; inFlight = true }
    func endQuote() { inFlight = false }
    func beginCandle() { candleCalls += 1 }
}

/// Every quote attempt fails with a retryable server error.
final class AlwaysFailingSource: QuoteProvider {
    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: FuyaoProvider.providerID,
            name: "fuyao",
            markets: [.sh],
            capabilities: [.quotes]
        )
    }
    private let counter = CallCounter()

    var calls: Int { get async { await counter.value } }

    func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
        await counter.increment()
        throw ProviderError.badResponse("HTTP 502")
    }

    func search(_ query: String) async throws -> [SymbolInfo] { [] }

    func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] { [] }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

// MARK: - Harness

@MainActor
private struct EngineHarness {
    let suiteName: String
    let defaults: UserDefaults
    let watchlist: WatchlistStore
    let store: MarketStore
    let clock: ManualRefreshClock

    static func make() throws -> EngineHarness {
        let suiteName = "FastRefreshTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return EngineHarness(
            suiteName: suiteName,
            defaults: defaults,
            watchlist: WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist"),
            store: MarketStore(),
            clock: ManualRefreshClock()
        )
    }

    func engine(
        providers: [any QuoteProvider],
        overrides: [String: TimeInterval] = [:]
    ) -> RefreshEngine {
        let composite = CompositeProvider(providers: providers, cooldown: 0)
        return RefreshEngine(
            provider: composite,
            store: store,
            watchlist: watchlist,
            pollOverrides: overrides,
            now: { [clock] in clock.now() },
            sleep: { [clock] duration in try await clock.sleep(for: duration) }
        )
    }

    func add(_ symbol: SymbolID) {
        let name = watchlist.item(for: symbol)?.resolvedDisplayName ?? symbol.displayCode
        watchlist.add(SymbolInfo(symbol: symbol, name: name))
    }

    /// A-share symbols route only to A-share sources, keeping each test's routing exact.
    func addShanghai(_ codes: [String] = ["600519"]) {
        codes.forEach { add(SymbolID(market: .sh, code: $0)) }
    }

    /// Lets MainActor turns run until `condition` holds (or the timeout passes).
    @discardableResult
    func wait(until timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    /// Runs the scheduler to a rest point: its first round, that round's sleep, a
    /// wake, then the round planned once in-flight work had a chance to settle.
    func settle(_ engine: RefreshEngine) async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(15))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

// MARK: - Composite: explicit refresh and candle priority

@Suite("Composite explicit quote refresh")
struct CompositeRefreshTests {
    @Test("A scheduled refresh is not held back by the 12s consumer cache")
    func explicitRefreshBypassesQuoteCache() async throws {
        let source = ScriptedQuoteSource(id: "fuyao", price: 10)
        let composite = CompositeProvider(providers: [source])
        let maotai = SymbolID(market: .sh, code: "600519")

        let first = try #require(try await composite.quotes(for: [maotai]).first)
        // Within the 12s cache window, ordinary consumers still share the answer.
        let cached = try #require(try await composite.quotes(for: [maotai]).first)
        #expect(cached.price == first.price)
        #expect(await source.quoteCalls == 1)

        let refreshed = try #require(try await composite.refreshQuotes(for: [maotai]).first)
        #expect(refreshed.price == first.price + 1)
        #expect(await source.quoteCalls == 2)

        // The refresh replaced the cache entry; consumers share the newest answer
        // without a third request.
        let shared = try #require(try await composite.quotes(for: [maotai]).first)
        #expect(shared.price == refreshed.price)
        #expect(await source.quoteCalls == 2)

        // An explicit maximum age of zero is a hard refresh as well.
        let again = try #require(try await composite.quotes(for: [maotai], maximumCacheAge: 0).first)
        #expect(again.price == refreshed.price + 1)
        #expect(await source.quoteCalls == 3)
    }

    @Test("A refresh re-runs routing so a recovered preferred source wins again")
    func refreshReroutesAfterFallbackRecovers() async throws {
        let longbridge = ScriptedQuoteSource(id: LongbridgeProvider.providerID, price: 100)
        let tencent = ScriptedQuoteSource(id: "tencent", price: 200)
        let composite = CompositeProvider(providers: [longbridge, tencent], cooldown: 0.3)
        let maotai = SymbolID(market: .sh, code: "600519")

        await longbridge.failNextQuote(with: ProviderError.network(underlying: "offline"))
        let fallback = try #require(try await composite.refreshQuotes(for: [maotai]).first)
        #expect(fallback.sourceID == "tencent")
        #expect(await composite.healthReport()[LongbridgeProvider.providerID]?.hasPrefix("cooling") == true)

        // The circuit recovers on its own; the next scheduled round must go back
        // to the preferred source instead of being served the cached fallback.
        try await Task.sleep(for: .milliseconds(350))
        let recovered = try #require(try await composite.refreshQuotes(for: [maotai]).first)
        #expect(recovered.sourceID == LongbridgeProvider.providerID)
        #expect(recovered.price == 100)
        #expect(await composite.healthReport()[LongbridgeProvider.providerID] == "healthy")
    }

    @Test("A board's daily bars reach Fuyao before Ths; minute bars stay with Ths")
    func boardCandlesFollowQuotePriority() async throws {
        let daily = Candle(time: .now, open: 2, high: 2, low: 2, close: 2)
        let fuyao = MockProvider(
            id: FuyaoProvider.providerID,
            candleResult: [daily],
            candlePeriods: [.day], coversBoards: true
        )
        let ths = MockProvider(id: ThsSectorProvider.providerID, candleResult: [
            Candle(time: .now, open: 3, high: 3, low: 3, close: 3)
        ], coversBoards: true)
        // Ths registered last: without ordering, a board's daily history would
        // fall through both sources in registration order and still hit Ths first.
        let composite = CompositeProvider(providers: [ths, fuyao])
        let board = SymbolID(market: .sh, code: "881155")

        #expect(try await composite.candles(for: board, period: .day, count: 60).first?.close == 2)
        // Fuyao has no minute capability, so the board's minute bars come from Ths.
        #expect(try await composite.candles(for: board, period: .minute1, count: 10).first?.close == 3)
    }

    @Test("Daily stock history keeps Longbridge first and its single-bar fallback")
    func dailyStockKeepsPriorityAndFallback() async throws {
        let today = Candle(time: .now, open: 10, high: 10, low: 10, close: 10)
        let yesterday = Candle(time: today.time.addingTimeInterval(-86_400), open: 9, high: 9, low: 9, close: 9)
        let longbridge = MockProvider(id: LongbridgeProvider.providerID, candleResult: [today])
        let fuyao = MockProvider(id: FuyaoProvider.providerID, candleResult: [yesterday, today])
        let composite = CompositeProvider(providers: [fuyao, longbridge])

        // Longbridge's single-bar snapshot is not final: Fuyao's full history wins.
        #expect(try await composite.candles(for: SymbolID(market: .sh, code: "600519"), period: .day, count: 250)
            == [yesterday, today])
    }
}

// MARK: - Refresh engine

@Suite("Refresh engine cadence and isolation", .serialized)
@MainActor
struct FastRefreshTests {
    @Test("Cadence: override → suggestion → 15s default, always at least one second")
    func cadenceResolution() throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        let engine = harness.engine(providers: [ScriptedQuoteSource(id: "fuyao")])

        // The scripted descriptor suggests 15s, which is also the default.
        #expect(engine.pollInterval(for: "fuyao") == 15)
        engine.setPollOverride(1, for: "fuyao")
        #expect(engine.pollInterval(for: "fuyao") == 1)
        engine.setPollOverride(0.25, for: "fuyao")
        #expect(engine.pollInterval(for: "fuyao") == 1)
        engine.setPollOverride(0, for: "fuyao")
        #expect(engine.pollInterval(for: "fuyao") == 15) // falls back to the suggestion
        engine.setPollOverride(.infinity, for: "fuyao")
        #expect(engine.pollInterval(for: "fuyao") == 15)
        engine.setPollOverride(.nan, for: "fuyao")
        #expect(engine.pollInterval(for: "fuyao") == 15)
        engine.setPollOverride(-3, for: "fuyao")
        #expect(engine.pollInterval(for: "fuyao") == 15)
        engine.setPollOverride(30, for: "fuyao")
        #expect(engine.pollInterval(for: "fuyao") == 30)
        engine.setPollOverride(nil, for: "fuyao")
        #expect(engine.pollInterval(for: "fuyao") == 15)
    }

    @Test("A one-second source starts its next round while slow candles and a slow source are busy")
    func fastSourceIsNotBlockedBySlowWork() async throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        harness.add(SymbolID(market: .sz, code: "000001"))
        harness.addShanghai(["600519", "601318", "600036", "601988"])

        let fuyao = ScriptedQuoteSource(id: FuyaoProvider.providerID, price: 10)
        await fuyao.setDelay(0.05)
        // Name sorts before "fuyao", so the slow source's quote round starts first.
        let slow = SlowWorkSource(id: "calm")
        let engine = harness.engine(
            providers: [slow, fuyao],
            overrides: [FuyaoProvider.providerID: 1, "calm": 10]
        )
        let maotai = SymbolID(market: .sh, code: "600519")

        engine.start()
        defer { engine.stop() }
        await harness.settle(engine)

        _ = await harness.wait(until: .seconds(1)) {
            let quoteCalls = await slow.quoteCalls
            let candleCalls = await slow.candleCalls
            return quoteCalls == 1 && candleCalls == 1 && harness.store.quote(for: maotai)?.price == 10
        }

        // First round: the slow source holds its quote, the fast one answered, and
        // the sparkline pass is now fetching minute bars (2s each).
        #expect(await slow.quoteCalls == 1)
        #expect(await slow.isInFlight)
        #expect(await slow.candleCalls == 1)
        #expect(await fuyao.quoteCalls == 1)
        #expect(harness.store.quote(for: maotai)?.price == 10)

        // One second later the fast source starts its second round and lands it,
        // while both slow tracks are still in flight.
        harness.clock.advance(by: 1.0)
        try? await Task.sleep(for: .milliseconds(5))
        let secondRound = await harness.wait(until: .seconds(1)) {
            await fuyao.quoteCalls == 2 && harness.store.quote(for: maotai)?.price == 11
        }
        #expect(secondRound)
        #expect(await slow.isInFlight)
        #expect(await slow.quoteCalls == 1)

        // One source never overlaps itself: during ~1.05s of its 50ms requests
        // the second round cannot have started a third.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await fuyao.quoteCalls == 2)

        // A source whose interval is longer than a second is not pulled faster by
        // the one-second tick.
        harness.clock.advance(by: 4.0)
        _ = await harness.wait(until: .seconds(1)) { await fuyao.quoteCalls >= 3 }
        #expect(await fuyao.quoteCalls >= 3)
        #expect(await slow.quoteCalls == 1)
    }

    @Test("A slow source never runs two quote rounds at once")
    func noOverlapPerSource() async throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        harness.addShanghai()
        let slow = ScriptedQuoteSource(id: "slow", price: 5)
        await slow.setDelay(3)
        let engine = harness.engine(providers: [slow], overrides: ["slow": 1])

        engine.start()
        defer { engine.stop() }
        await harness.settle(engine)
        #expect(await slow.quoteCalls == 1)

        harness.clock.advance(by: 2.9)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await slow.quoteCalls == 1)
        #expect(harness.store.quote(for: SymbolID(market: .sh, code: "600519")) == nil)
    }

    @Test("Stop discards an in-flight round, errors included")
    func stopDiscardsInFlightRound() async throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        harness.addShanghai()
        let source = ScriptedQuoteSource(id: "fuyao", price: 42)
        await source.setDelay(0.2)
        let engine = harness.engine(providers: [source], overrides: ["fuyao": 1])
        let maotai = SymbolID(market: .sh, code: "600519")

        engine.start()
        await harness.settle(engine)
        #expect(await source.quoteCalls == 1)
        engine.stop()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(harness.store.quote(for: maotai) == nil)
        #expect(harness.store.lastError == nil)
        #expect(!engine.isRunning)
    }

    @Test("A held round is dropped without spinning, then caught up right after release")
    func holdDropsAndCatchesUp() async throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        harness.addShanghai()
        let source = ScriptedQuoteSource(id: "fuyao", price: 77)
        await source.setDelay(0.1)
        let engine = harness.engine(providers: [source], overrides: ["fuyao": 15])
        let maotai = SymbolID(market: .sh, code: "600519")

        engine.start()
        defer { engine.stop() }
        await harness.settle(engine)
        #expect(await source.quoteCalls == 1)

        engine.writesHeld = true
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.store.quote(for: maotai) == nil) // held result discarded

        // No empty spinning while held: no new request and no store write.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await source.quoteCalls == 1)

        engine.writesHeld = false
        let caughtUp = await harness.wait(until: .seconds(1)) {
            await source.quoteCalls == 2 && harness.store.quote(for: maotai) != nil
        }
        #expect(caughtUp)
        #expect(harness.store.quote(for: maotai)?.price == 78)
    }

    @Test("Poke re-polls immediately and only the new generation applies")
    func pokeRestartsCleanly() async throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        harness.addShanghai()
        let source = ScriptedQuoteSource(id: "fuyao", price: 1)
        await source.setDelay(0.1)
        let engine = harness.engine(providers: [source], overrides: ["fuyao": 60])
        let maotai = SymbolID(market: .sh, code: "600519")

        engine.start()
        defer { engine.stop() }
        await harness.settle(engine)
        #expect(await source.quoteCalls == 1)

        engine.poke()
        try? await Task.sleep(for: .milliseconds(20))
        _ = await harness.wait(until: .seconds(1)) { await source.quoteCalls == 2 }
        #expect(await source.quoteCalls == 2)
        _ = await harness.wait(until: .seconds(1)) { harness.store.quote(for: maotai) != nil }
        // The old generation's answer never lands; exactly the new one does.
        #expect(harness.store.quote(for: maotai)?.price == 2)
    }

    @Test("A cancelled network request is not reported as a source error")
    func cancellationIsNotAnError() async throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        harness.addShanghai()
        // HTTPClient wraps a cancelled URLSession call as .network; reproduce that.
        let source = ScriptedQuoteSource(id: "fuyao")
        await source.setDelay(0.5)
        await source.wrapCancellation()
        let engine = harness.engine(providers: [source], overrides: ["fuyao": 15])

        engine.start()
        defer { engine.stop() }
        await harness.settle(engine)
        engine.stop()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.store.lastError == nil)
    }

    @Test("A failing source retries no faster than its cadence")
    func failuresDoNotStorm() async throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        harness.addShanghai()
        let source = AlwaysFailingSource()
        let engine = harness.engine(providers: [source], overrides: ["fuyao": 2])

        engine.start()
        defer { engine.stop() }
        await harness.settle(engine)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await source.calls == 1)

        harness.clock.advance(by: 1.0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await source.calls == 1)
        harness.clock.advance(by: 0.9)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await source.calls == 1)
        harness.clock.advance(by: 0.15)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await source.calls == 2)
    }

    @Test("The one-second tick does not speed up a source with a longer cadence")
    func otherSourcesKeepCadence() async throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        harness.addShanghai()
        // Two markets, two preferred sources: Fuyao owns Shanghai, "slow" Shenzhen.
        let fast = ScriptedQuoteSource(id: FuyaoProvider.providerID, markets: [.sh])
        let slow = ScriptedQuoteSource(id: "slow", markets: [.sz])
        harness.add(SymbolID(market: .sz, code: "000001"))
        let engine = harness.engine(
            providers: [fast, slow],
            overrides: [FuyaoProvider.providerID: 1, "slow": 15]
        )

        engine.start()
        defer { engine.stop() }
        await harness.settle(engine)
        #expect(await fast.quoteCalls == 1)
        #expect(await slow.quoteCalls == 1)

        // Five one-second rounds of the fast source; the slow one keeps its own pace.
        harness.clock.advance(by: 5)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await fast.quoteCalls >= 2)
        #expect(await slow.quoteCalls == 1)
    }

    @Test("Provider changes and manual refresh replace cached quotes after the close")
    func explicitRefreshWorksWhenClosed() async throws {
        let harness = try EngineHarness.make()
        defer { harness.cleanUp() }
        harness.clock.advance(by: 6 * 3_600) // 16:00 Shanghai, beyond closing grace
        harness.addShanghai()
        let symbol = SymbolID(market: .sh, code: "600519")
        harness.store.apply(quotes: [Quote(symbol: symbol, price: 1, previousClose: 1)])
        let source = ScriptedQuoteSource(id: "fuyao")
        let engine = harness.engine(providers: [source], overrides: ["fuyao": 1])
        engine.start()
        defer { engine.stop() }
        _ = await harness.wait(until: .seconds(1)) { harness.store.quote(for: symbol)?.price == 100 }
        #expect(harness.store.quote(for: symbol)?.price == 100)
        harness.clock.advance(by: 1)
        await harness.settle(engine)
        #expect(await source.quoteCalls == 1) // off-hours stay quiet
        engine.poke()
        _ = await harness.wait(until: .seconds(1)) { harness.store.quote(for: symbol)?.price == 101 }
        #expect(harness.store.quote(for: symbol)?.price == 101)
    }
}

private actor SparklineRefreshSource: QuoteProvider {
    nonisolated var descriptor: ProviderDescriptor {
        .init(id: "sparkline-test", name: "Synthetic", markets: [.sh], capabilities: [.quotes, .candles],
              candlePeriods: [.minute1], suggestedPollInterval: 3600)
    }
    private(set) var calls: [SymbolID: Int] = [:]
    let onCandle: (@Sendable () async -> Void)?
    init(onCandle: (@Sendable () async -> Void)? = nil) { self.onCandle = onCandle }
    func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
        symbols.map { .init(symbol: $0, price: 100, previousClose: 99) }
    }
    func search(_ query: String) async throws -> [SymbolInfo] { [] }
    func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        calls[symbol, default: 0] += 1
        await onCandle?()
        return [.init(time: Date(timeIntervalSince1970: 1_792_461_600), open: 100, high: 100, low: 100, close: 100)]
    }
    func count(_ symbol: SymbolID) -> Int { calls[symbol, default: 0] }
}

@Suite("Sparkline history freshness", .serialized)
@MainActor
struct SparklineRefreshTests {
    @Test("History wakes at 30 seconds even when quotes are only scheduled hourly")
    func independentDeadline() async throws {
        let harness = try EngineHarness.make(); defer { harness.cleanUp() }
        harness.addShanghai()
        let symbol = SymbolID(market: .sh, code: "600519")
        let source = SparklineRefreshSource()
        let engine = harness.engine(providers: [source]); defer { engine.stop() }
        #expect(engine.sparklineInterval == 30)
        engine.start()
        #expect(await harness.wait { await source.count(symbol) == 1 })
        await harness.settle(engine)
        harness.clock.advance(by: 29)
        await harness.settle(engine)
        #expect(await source.count(symbol) == 1)
        harness.clock.advance(by: 1)
        #expect(await harness.wait { await source.count(symbol) == 2 })
    }

    @Test("Manual refresh invalidates the history schedule immediately")
    func manualRefreshIncludesHistory() async throws {
        let harness = try EngineHarness.make(); defer { harness.cleanUp() }
        harness.addShanghai()
        let symbol = SymbolID(market: .sh, code: "600519")
        let source = SparklineRefreshSource()
        let engine = harness.engine(providers: [source]); defer { engine.stop() }
        engine.start()
        #expect(await harness.wait { await source.count(symbol) == 1 })
        await harness.settle(engine)
        engine.poke()
        #expect(await harness.wait { await source.count(symbol) == 2 })
    }

    @Test("The closing grace window still collects the final minute bars")
    func closingGrace() async throws {
        let harness = try EngineHarness.make(); defer { harness.cleanUp() }
        let frame = IntradayTradingSession(market: .sh, referenceDate: harness.clock.now())
        harness.clock.advance(by: frame.close.timeIntervalSince(harness.clock.now()) + 60)
        harness.addShanghai()
        let symbol = SymbolID(market: .sh, code: "600519")
        let source = SparklineRefreshSource()
        let engine = harness.engine(providers: [source]); defer { engine.stop() }
        engine.start()
        #expect(await harness.wait { await source.count(symbol) == 1 })
        await harness.settle(engine)
        harness.clock.advance(by: 30)
        #expect(await harness.wait { await source.count(symbol) == 2 })
    }

    @Test("Slow history rounds cannot permanently starve symbols after the first six")
    func fairHistoryQueue() async throws {
        let harness = try EngineHarness.make(); defer { harness.cleanUp() }
        let codes = (1...8).map { String(format: "600%03d", $0) }
        harness.addShanghai(codes)
        let source = SparklineRefreshSource { await harness.clock.advance(by: 31) }
        let engine = harness.engine(providers: [source]); defer { engine.stop() }
        engine.start()
        let last = SymbolID(market: .sh, code: codes.last!)
        #expect(await harness.wait { await source.count(last) >= 1 })
        let counts = await source.calls
        #expect(codes.allSatisfy { counts[SymbolID(market: .sh, code: $0), default: 0] >= 1 })
    }
}
