import Foundation

/// Aggregates the journal's filtered transaction history by trade month and
/// the symbol's own currency. Realized results always come from the full ledger.
public struct TradeJournalMonthlySummary: Sendable, Hashable, Identifiable {
    public var month: Date
    public var currencyCode: String
    public var realizedPnL: Double?
    public var fees: Double?
    public var missingFeeCount: Int
    public var followedPlanYesCount: Int
    public var followedPlanNoCount: Int

    public var id: String { "\(month.timeIntervalSince1970):\(currencyCode)" }
    public var reviewedCount: Int { followedPlanYesCount + followedPlanNoCount }
    public var followedPlanPercent: Double? {
        guard reviewedCount > 0 else { return nil }
        return Double(followedPlanYesCount) / Double(reviewedCount) * 100
    }

    public static func make(
        from items: [WatchItem],
        query: String = "",
        selectedMonth: Date? = nil,
        calendar: Calendar = .current
    ) -> [Self] {
        struct Key: Hashable {
            var month: Date
            var currencyCode: String
        }
        struct Totals {
            var realizedPnL = 0.0
            var hasInvalidRealizedPnL = false
            var fees = 0.0
            var hasInvalidFees = false
            var missingFeeCount = 0
            var followedPlanYesCount = 0
            var followedPlanNoCount = 0
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var totals: [Key: Totals] = [:]
        for item in items where needle.isEmpty
            || item.symbol.displayCode.localizedCaseInsensitiveContains(needle)
            || item.resolvedDisplayName.localizedCaseInsensitiveContains(needle) {
            let realizedByTransaction = Dictionary(uniqueKeysWithValues: (item.ledger?.entries ?? []).map {
                ($0.transaction.id, $0.realizedPnL)
            })
            for transaction in item.transactions {
                guard let month = calendar.dateInterval(of: .month, for: transaction.date)?.start,
                      selectedMonth.map({ calendar.isDate(transaction.date, equalTo: $0, toGranularity: .month) }) ?? true else {
                    continue
                }
                let key = Key(month: month, currencyCode: item.symbol.currencyCode)
                var value = totals[key, default: Totals()]

                if transaction.kind != .adjustment {
                    if let fee = transaction.fee, fee.isFinite {
                        let sum = value.fees + fee
                        if sum.isFinite { value.fees = sum } else { value.hasInvalidFees = true }
                    } else {
                        value.missingFeeCount += 1
                    }
                    switch transaction.review?.followedPlan {
                    case .some(true): value.followedPlanYesCount += 1
                    case .some(false): value.followedPlanNoCount += 1
                    case .none: break
                    }
                }

                if let realized = realizedByTransaction[transaction.id] ?? nil {
                    if realized.isFinite {
                        let sum = value.realizedPnL + realized
                        if sum.isFinite { value.realizedPnL = sum } else { value.hasInvalidRealizedPnL = true }
                    } else {
                        value.hasInvalidRealizedPnL = true
                    }
                }
                totals[key] = value
            }
        }

        return totals.map { key, value in
            Self(
                month: key.month,
                currencyCode: key.currencyCode,
                realizedPnL: value.hasInvalidRealizedPnL ? nil : value.realizedPnL,
                fees: value.hasInvalidFees ? nil : value.fees,
                missingFeeCount: value.missingFeeCount,
                followedPlanYesCount: value.followedPlanYesCount,
                followedPlanNoCount: value.followedPlanNoCount
            )
        }.sorted {
            if $0.month != $1.month { return $0.month > $1.month }
            return $0.currencyCode < $1.currencyCode
        }
    }
}
