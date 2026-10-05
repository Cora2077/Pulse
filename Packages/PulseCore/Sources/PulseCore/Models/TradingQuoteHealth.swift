import Foundation

public enum TradingQuoteHealth {
    /// A price suitable for a current intraday attention signal, including declared feed delay.
    public static func isCurrent(_ quote: Quote, now: Date = .now) -> Bool {
        guard quote.price.isFinite, quote.price > 0, quote.timestamp.timeIntervalSince1970.isFinite,
              quote.marketState != .closed else { return false }
        let delay = quote.sourceDelay ?? 0
        guard delay.isFinite, delay >= 0 else { return false }
        return quote.timestamp.timeIntervalSince(now) <= 30
            && now.timeIntervalSince(quote.timestamp) <= delay + 90
    }
}
