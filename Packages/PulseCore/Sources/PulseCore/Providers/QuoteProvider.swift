import Foundation

public enum ProviderError: Error, Sendable {
    case network(underlying: String)
    case rateLimited
    /// 4xx (except 429): a problem with the request itself (e.g. the source doesn't support the query), not a source failure
    case clientError(status: Int, detail: String)
    /// 5xx / decode failures etc.: an error on the data source side
    case badResponse(String)
    case unsupported(Capability)
    case symbolNotFound(SymbolID)

    /// Whether this error should trip the circuit breaker (temporarily take the data source offline).
    /// Request-level problems (4xx, symbol not found, unsupported capability) must not trip it — otherwise a single 400 from a Chinese search would wrongly kill the whole source.
    public var shouldTripCircuit: Bool {
        switch self {
        case .network, .rateLimited, .badResponse: true
        case .clientError, .unsupported, .symbolNotFound: false
        }
    }

    public static func shouldTrip(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let providerError = error as? ProviderError else { return true }
        return providerError.shouldTripCircuit
    }
}

/// Unified protocol for all data sources (built-in / future Manifest plugins / JS plugins).
/// A Provider is only responsible for HOW to fetch data, never WHEN — scheduling, throttling, and caching all live in RefreshEngine.
public protocol QuoteProvider: Sendable {
    var descriptor: ProviderDescriptor { get }

    /// Searches for instruments (by code / name)
    func search(_ query: String) async throws -> [SymbolInfo]

    /// Resolves canonical localized names for already-known symbols.
    func securityNames(for symbols: [SymbolID]) async throws -> [SecurityName]

    /// What the instrument is: business summary and classification. `nil` means
    /// the source covers the symbol but has nothing to say about it (an index,
    /// a crypto pair), which is an answer — unlike throwing, it is not retried
    /// against the next source.
    func profile(for symbol: SymbolID) async throws -> SecurityProfile?

    /// Batch quote snapshots
    func quotes(for symbols: [SymbolID]) async throws -> [Quote]

    /// Candles / intraday data; returns the most recent `count` bars in ascending time order
    func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle]

    /// An explicit price basis must never silently fall back to a different one.
    func candles(for symbol: SymbolID, period: CandlePeriod, count: Int, adjustment: CandleAdjustment) async throws -> [Candle]

    /// Real-time streaming (optional capability)
    func quoteStream(for symbols: [SymbolID]) -> AsyncThrowingStream<Quote, any Error>?

    /// Whether this source can address the instrument at all, independent of the
    /// market it belongs to.
    ///
    /// Routing is otherwise market-only, which assumes any source that declares a
    /// market can be handed anything in it. Sector boards break that assumption:
    /// they live in the A-share market but no exchange source knows them, so an
    /// ordinary `.sh` dispatch would ask Longbridge, Fuyao, Tencent and Yahoo for
    /// a code none of them can price. Their failures are the kind that trip the
    /// circuit breaker, and the breaker is shared with real stocks — so a single
    /// board symbol could take away the user's quotes for 600519.
    ///
    /// This is a protocol *requirement*, not just an extension method, and that is
    /// load-bearing: a member declared only in an extension is dispatched
    /// statically, so a call through `any QuoteProvider` would always run the
    /// default and silently ignore a source's own answer. Routing holds these as
    /// existentials, so the requirement is what makes the override take effect.
    func covers(_ symbol: SymbolID) -> Bool
}

public extension QuoteProvider {
    func candles(for symbol: SymbolID, period: CandlePeriod, count: Int, adjustment: CandleAdjustment) async throws -> [Candle] {
        guard adjustment == .none else { throw ProviderError.unsupported(.candles) }
        return try await candles(for: symbol, period: period, count: count)
    }

    func securityNames(for symbols: [SymbolID]) async throws -> [SecurityName] {
        throw ProviderError.unsupported(.referenceData)
    }

    func profile(for symbol: SymbolID) async throws -> SecurityProfile? {
        throw ProviderError.unsupported(.profile)
    }

    func quoteStream(for symbols: [SymbolID]) -> AsyncThrowingStream<Quote, any Error>? { nil }

    /// The default answers for every source that existed before boards did: it
    /// covers everything except a board. A source that carries boards overrides
    /// this, and nothing else has to change.
    func covers(_ symbol: SymbolID) -> Bool { symbol.sectorIndex == nil }
}
