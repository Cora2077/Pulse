import Foundation
import Testing
@testable import PulseCore

struct PlanAlertLedgerTests {
    @Test func deliverySurvivesRelaunchAndOscillationAndSnoozeExpires() throws {
        let now = Date()
        let symbol = SymbolID(market: .us, code: "AAPL")
        var plan = TradePlan(kind: .buy, price: 100, quantity: 5)
        var quote = Quote(symbol: symbol, price: 99, previousClose: 101, timestamp: now)
        var ledger = PlanAlertLedger()
        #expect(ledger.shouldNotify(plan: plan, quote: quote, now: now))
        ledger.markDelivered(plan)
        ledger = try JSONDecoder().decode(PlanAlertLedger.self, from: JSONEncoder().encode(ledger))
        quote.price = 101
        #expect(!ledger.shouldNotify(plan: plan, quote: quote, now: now))
        quote.price = 99
        #expect(!ledger.shouldNotify(plan: plan, quote: quote, now: now))
        ledger.snooze(plan, until: now.addingTimeInterval(900))
        #expect(!ledger.shouldNotify(plan: plan, quote: quote, now: now))
        quote.timestamp = now.addingTimeInterval(900)
        #expect(ledger.shouldNotify(plan: plan, quote: quote, now: quote.timestamp))
        ledger.markDelivered(plan)
        plan.price = 102
        #expect(ledger.shouldNotify(plan: plan, quote: quote, now: quote.timestamp))
    }

    @Test func inactiveInvalidOrStaleQuotesNeverTrigger() {
        let now = Date()
        let symbol = SymbolID(market: .us, code: "AAPL")
        var plan = TradePlan(kind: .sell, price: 100, quantity: 5)
        var quote = Quote(symbol: symbol, price: 101, previousClose: 100, timestamp: now)
        let ledger = PlanAlertLedger()
        #expect(ledger.shouldNotify(plan: plan, quote: quote, now: now))
        quote.timestamp = now.addingTimeInterval(-300)
        #expect(!ledger.shouldNotify(plan: plan, quote: quote, now: now))
        quote.sourceDelay = 900
        #expect(ledger.shouldNotify(plan: plan, quote: quote, now: now))
        quote.marketState = .closed
        #expect(!ledger.shouldNotify(plan: plan, quote: quote, now: now))
        quote.marketState = .regular
        plan.status = .done
        #expect(!ledger.shouldNotify(plan: plan, quote: quote, now: now))
        plan.status = .active
        quote.price = .infinity
        #expect(!ledger.shouldNotify(plan: plan, quote: quote, now: now))
    }
}
