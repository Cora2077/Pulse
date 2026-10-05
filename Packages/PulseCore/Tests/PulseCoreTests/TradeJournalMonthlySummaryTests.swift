import Foundation
import Testing
@testable import PulseCore

@Suite("Trade journal monthly summaries")
struct TradeJournalMonthlySummaryTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("Buckets by trade-date month and symbol currency, with month and search filters")
    func monthCurrencyAndFilters() {
        var apple = WatchItem(symbol: SymbolID(market: .us, code: "AAPL"), displayName: "Apple")
        apple.transactions = [
            PositionTransaction(kind: .buy, price: 100, quantity: 1, date: date(2026, 8, 31)),
            PositionTransaction(kind: .sell, price: 110, quantity: 1, date: date(2026, 9, 1)),
        ]
        var toyota = WatchItem(symbol: SymbolID(market: .jp, code: "7203"), displayName: "Toyota")
        toyota.transactions = [PositionTransaction(kind: .buy, price: 2_000, quantity: 1, date: date(2026, 9, 2))]

        let all = TradeJournalMonthlySummary.make(from: [apple, toyota], calendar: calendar)
        #expect(all.count == 3)
        #expect(all.map(\.currencyCode).sorted() == ["JPY", "USD", "USD"])
        let september = TradeJournalMonthlySummary.make(
            from: [apple, toyota], query: "apple", selectedMonth: date(2026, 9, 20), calendar: calendar
        )
        #expect(september.count == 1)
        #expect(september[0].currencyCode == "USD")
        #expect(september[0].realizedPnL == 10)
    }

    @Test("Counts recorded fees and explicit reviews while excluding unset reviews and adjustments")
    func feesAndReviews() {
        var item = WatchItem(symbol: SymbolID(market: .us, code: "AAPL"), displayName: "Apple")
        item.transactions = [
            PositionTransaction(kind: .buy, price: 100, quantity: 1, date: date(2026, 9, 1), fee: 2,
                                review: PositionTransactionReview(followedPlan: true)),
            PositionTransaction(kind: .buy, price: 100, quantity: 1, date: date(2026, 9, 2), fee: nil,
                                review: PositionTransactionReview(followedPlan: false)),
            PositionTransaction(kind: .sell, price: 120, quantity: 1, date: date(2026, 9, 3), fee: .infinity,
                                review: PositionTransactionReview(followedPlan: nil)),
            PositionTransaction(kind: .adjustment, price: 100, quantity: 4, date: date(2026, 9, 4), fee: 50,
                                review: PositionTransactionReview(followedPlan: true)),
        ]
        let summary = TradeJournalMonthlySummary.make(from: [item], calendar: calendar)[0]
        #expect(summary.fees == 2)
        #expect(summary.missingFeeCount == 2)
        #expect(summary.followedPlanYesCount == 1)
        #expect(summary.followedPlanNoCount == 1)
        #expect(summary.followedPlanPercent == 50)
    }

    @Test("Realizes long sales and short covers from basis seeded before the selected month")
    func historicalLongAndShortBasis() {
        var item = WatchItem(symbol: SymbolID(market: .us, code: "AAPL"), displayName: "Apple")
        item.transactions = [
            PositionTransaction(kind: .adjustment, price: 100, quantity: 10, date: date(2026, 8, 1)),
            PositionTransaction(kind: .sell, price: 120, quantity: 2, date: date(2026, 9, 1)),
            PositionTransaction(kind: .adjustment, price: 150, quantity: -10, date: date(2026, 9, 2)),
            PositionTransaction(kind: .buy, price: 100, quantity: 4, date: date(2026, 9, 3)),
        ]
        let summary = TradeJournalMonthlySummary.make(
            from: [item], selectedMonth: date(2026, 9, 15), calendar: calendar
        )[0]
        #expect(summary.realizedPnL == 240)
        #expect(summary.reviewedCount == 0)
        #expect(summary.followedPlanPercent == nil)
    }

    @Test("Empty history is empty and an overflowing fee sum is unavailable")
    func overflowingFeesAreUnavailable() {
        #expect(TradeJournalMonthlySummary.make(from: [], calendar: calendar).isEmpty)
        var item = WatchItem(symbol: SymbolID(market: .us, code: "AAPL"), displayName: "Apple")
        item.transactions = [
            PositionTransaction(kind: .buy, price: 1, quantity: 1, date: date(2026, 9, 1), fee: .greatestFiniteMagnitude),
            PositionTransaction(kind: .buy, price: 1, quantity: 1, date: date(2026, 9, 2), fee: .greatestFiniteMagnitude),
        ]
        let summary = TradeJournalMonthlySummary.make(from: [item], calendar: calendar)[0]
        #expect(summary.fees == nil)
    }

    @Test("An overflowing realized total is unavailable")
    func overflowingRealizedPnLIsUnavailable() {
        var item = WatchItem(symbol: SymbolID(market: .us, code: "AAPL"), displayName: "Apple")
        item.transactions = [
            PositionTransaction(kind: .adjustment, price: 0, quantity: 1, date: date(2026, 9, 1)),
            PositionTransaction(kind: .sell, price: .greatestFiniteMagnitude, quantity: 1, date: date(2026, 9, 2)),
            PositionTransaction(kind: .adjustment, price: 0, quantity: 1, date: date(2026, 9, 3)),
            PositionTransaction(kind: .sell, price: .greatestFiniteMagnitude, quantity: 1, date: date(2026, 9, 4)),
        ]
        let summary = TradeJournalMonthlySummary.make(from: [item], calendar: calendar)[0]
        #expect(summary.realizedPnL == nil)
    }
}
