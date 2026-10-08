import Foundation
import PulseCore

/// Read-only account/currency totals. Never replay two accounts as one ledger.
struct BrokerageAccountOverviewRow: Identifiable {
    let accountID: BrokerageAccountID
    let currencyCode: String
    var holdingsCount = 0
    var pricedHoldingsCount = 0
    var holdingValue: Double = 0
    var missingQuotes = 0
    var staleQuotes = 0
    var cash: CashBalance?
    var planCount = 0
    var plannedBuy: Double = 0
    var plannedSell: Double = 0
    var marginBuy: Double = 0
    var ownBuy: Double = 0
    var unmarkedBuy: Double = 0
    var hasOverflow = false
    var id: String { "\(accountID.rawValue)|\(currencyCode)" }
    var hasActivity: Bool { holdingsCount > 0 || planCount > 0 || cash != nil }
    /// Gross recorded capital; no debt/credit data exists to claim net assets.
    var recordedFunds: Double? {
        guard !hasOverflow, missingQuotes == 0, let cash else { return nil }
        let value = holdingValue + cash.amount
        return value.isFinite ? value : nil
    }
}

@MainActor
enum BrokerageAccountOverviewReader {
    static func rows(store: WatchlistStore, market: MarketStore, budgets: PoolBudgetSettings) -> [BrokerageAccountOverviewRow] {
        // Read every ledger once. A portion on an item can be labelled with a
        // different account than the ledger it sits in, so holdings are
        // attributed per portion while plans stay with their enclosing ledger.
        let records = BrokerageBoardReader.records(store: store)

        // target account -> currency -> symbol -> summed attributed quantity.
        // Summed across every source ledger before a quote is looked up, so one
        // symbol held in two ledgers is counted and priced once.
        var attributed: [BrokerageAccountID: [String: [SymbolID: Double]]] = [:]
        // Symbols that had to be abandoned because a quantity, or the running
        // sum for that symbol, was not finite. Keyed per target account and
        // currency so a poisoned symbol can be counted as one holding and one
        // missing valuation without inflating a currency's counts. A poisoned
        // symbol stays poisoned: a later ledger holding the same symbol must not
        // restart a finite running sum and claim a priced partial amount.
        var poisonedSymbols: [BrokerageAccountID: [String: Set<SymbolID>]] = [:]
        for record in records {
            let quantities = record.item.positionAccountQuantities(enclosingAccountID: record.accountID)
            let currency = record.item.symbol.currencyCode.uppercased()
            let symbol = record.item.symbol
            for (target, quantity) in quantities {
                // Every record for an already poisoned symbol is skipped, so
                // only the first nonfinite quantity counts as the trigger.
                guard poisonedSymbols[target]?[currency]?.contains(symbol) != true else { continue }
                guard quantity.isFinite else {
                    poisonedSymbols[target, default: [:]][currency, default: []].insert(symbol)
                    attributed[target]?[currency]?.removeValue(forKey: symbol)
                    continue
                }
                guard quantity != 0 else { continue }
                let running = attributed[target]?[currency]?[symbol] ?? 0
                let sum = running + quantity
                guard sum.isFinite else {
                    poisonedSymbols[target, default: [:]][currency, default: []].insert(symbol)
                    attributed[target]?[currency]?.removeValue(forKey: symbol)
                    continue
                }
                attributed[target, default: [:]][currency, default: [:]][symbol] = sum
            }
        }

        // Plans and items stay with the ledger that owns them: the portfolio of
        // the target account, read once, not the attributed quantities above.
        var enclosingItems: [BrokerageAccountID: [WatchItem]] = [:]
        for record in records {
            enclosingItems[record.accountID, default: []].append(record.item)
        }

        var result: [BrokerageAccountOverviewRow] = []
        for account in BrokerageAccountID.allCases {
            let items = enclosingItems[account] ?? []
            let symbols = attributed[account] ?? [:]
            let cash = budgets.cashBalances(for: account)
            var currencies = Set(symbols.keys)
            currencies.formUnion(items.map { $0.symbol.currencyCode.uppercased() })
            currencies.formUnion(cash.keys)
            currencies.formUnion((poisonedSymbols[account] ?? [:]).keys)
            currencies.insert("CNY")
            for currency in currencies.sorted() {
                var row = BrokerageAccountOverviewRow(accountID: account, currencyCode: currency, cash: cash[currency])
                // A poisoned symbol is still one holding the account carries, and
                // one valuation it is missing: it may have no cash and no valid
                // symbol, and the row must still report activity rather than
                // disappear as an empty row.
                let poisoned = poisonedSymbols[account]?[currency] ?? []
                if !poisoned.isEmpty {
                    row.hasOverflow = true
                    row.holdingsCount = poisoned.count
                    row.missingQuotes = poisoned.count
                }
                // `SymbolID` is not `Comparable`; its `description` is the stable
                // market-qualified identity, so ordering by it is deterministic.
                for (symbol, quantity) in (symbols[currency] ?? [:]).sorted(by: { $0.key.description < $1.key.description }) {
                    guard quantity.isFinite, quantity != 0 else { continue }
                    row.holdingsCount += 1
                    if let quote = market.quote(for: symbol), quote.price.isFinite, quote.price > 0,
                       quote.timestamp.timeIntervalSince1970.isFinite {
                        let value = quantity * quote.price
                        if value.isFinite && (row.holdingValue + value).isFinite {
                            row.holdingValue += value
                            row.pricedHoldingsCount += 1
                            if !TradingQuoteHealth.isCurrent(quote) { row.staleQuotes += 1 }
                        } else { row.hasOverflow = true; row.missingQuotes += 1 }
                    } else { row.missingQuotes += 1 }
                }
                for item in items where item.symbol.currencyCode.uppercased() == currency {
                    for plan in item.plans where plan.status == .active {
                        let remaining = TradePlanExecutionProgress(plan: plan, transactions: store.transactionsForPlan(item.symbol, account: account)).remainingQuantity
                        guard remaining.isFinite, remaining > 0, plan.price.isFinite, plan.price > 0 else { continue }
                        let amount = plan.price * remaining
                        guard amount.isFinite else { row.hasOverflow = true; continue }
                        row.planCount += 1
                        if plan.kind == .buy {
                            row.plannedBuy += amount
                            switch plan.fundingSource {
                            case .own: row.ownBuy += amount
                            case .margin: row.marginBuy += amount
                            case .unmarked, nil: row.unmarkedBuy += amount
                            }
                        } else { row.plannedSell += amount }
                    }
                }
                if ![row.holdingValue, row.plannedBuy, row.plannedSell, row.ownBuy, row.marginBuy, row.unmarkedBuy].allSatisfy(\.isFinite) {
                    row.hasOverflow = true
                }
                result.append(row)
            }
        }
        return result
    }
}
