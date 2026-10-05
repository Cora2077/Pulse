import Foundation
import Testing
@testable import PulseCore

struct TradingQuoteHealthTests {
    @Test func rejectsBadAndClosedQuotesHonorsDeclaredDelay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var quote = Quote(symbol: .init(market: .us, code: "AAPL"), price: 10, previousClose: 9, timestamp: now)
        #expect(TradingQuoteHealth.isCurrent(quote, now: now))
        quote.timestamp = now.addingTimeInterval(-901)
        #expect(!TradingQuoteHealth.isCurrent(quote, now: now))
        quote.sourceDelay = 900
        #expect(TradingQuoteHealth.isCurrent(quote, now: now))
        quote.marketState = .closed
        #expect(!TradingQuoteHealth.isCurrent(quote, now: now))
        quote.marketState = .regular
        quote.timestamp = now.addingTimeInterval(31)
        #expect(!TradingQuoteHealth.isCurrent(quote, now: now))
        quote.timestamp = now
        quote.price = .infinity
        #expect(!TradingQuoteHealth.isCurrent(quote, now: now))
    }
}
