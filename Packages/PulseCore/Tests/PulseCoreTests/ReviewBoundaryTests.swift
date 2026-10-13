import Foundation
import Testing
@testable import PulseCore

@Suite("Review boundary regressions")
struct ReviewBoundaryTests {
    @Test("Malformed source times never become current quotes", arguments: ["", "unknown", "20261303112400", "20260230112400", "20260703242400", "202607031124", "20260703112400junk", "2026/7/03 11:24:00"])
    func malformedTencentTimes(raw: String) {
        let symbol = SymbolID(market: .sh, code: "600519")
        let fixture = TencentParserTests.aShareFixture.replacingOccurrences(of: "20260703112400", with: raw)
        #expect(TencentProvider.parseQuotes(text: fixture, mapping: ["sh600519": symbol]).isEmpty)
        #expect(TencentProvider.parseTimestamp(raw, timeZone: symbol.market.timeZone) == nil)
    }

    @Test("A malformed quote does not discard valid quotes in the same batch")
    func mixedTencentBatch() {
        let invalid = TencentParserTests.aShareFixture.replacingOccurrences(of: "20260703112400", with: "unknown")
        let quotes = TencentProvider.parseQuotes(text: invalid + TencentParserTests.hkShareFixture,
            mapping: ["sh600519": .init(market: .sh, code: "600519"), "hk00700": .init(market: .hk, code: "700")])
        #expect(quotes.count == 1 && quotes.first?.symbol.market == .hk)
    }

    @Test("Fully filled raw-active plans never alert, partial fills may still alert")
    func actualProgressControlsAlerts() {
        let symbol = SymbolID(market: .us, code: "QALERT")
        let plan = TradePlan(kind: .buy, price: 100, quantity: 100)
        let now = Date()
        let quote = Quote(symbol: symbol, price: 99, previousClose: 101, timestamp: now)
        let fill = PositionTransaction(kind: .buy, price: 100, quantity: 100,
            planExecution: .init(planID: plan.id, configuration: .init(plan: plan), sourceAccountID: .financing))
        let ledger = PlanAlertLedger()
        let completed = TradePlanEntry(symbol: symbol, plan: plan, transactions: [fill], accountID: .financing)
        #expect(completed.plan.status == .active && completed.displayState == .filled)
        #expect(!ledger.shouldNotify(entry: completed, quote: quote, now: now))
        var partialFill = fill; partialFill.quantity = 80
        #expect(ledger.shouldNotify(plan: plan, quote: quote, transactions: [partialFill], now: now))
        #expect(!ledger.shouldNotify(plan: plan, quote: quote, transactions: [fill], now: now))
        let wrongSymbol = TradePlanEntry(symbol: .init(market: .us, code: "OTHER"), plan: plan)
        #expect(!ledger.shouldNotify(entry: wrongSymbol, quote: quote, now: now))
    }
}
