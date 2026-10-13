import Foundation

/// Pure ledger cache and metadata construction, shared by checked mutations,
/// imports and persistence normalization. Publication belongs to WatchlistStore.
enum TradeLedgerMutation {
    static func applyingTransactions(_ transactions: [PositionTransaction], to item: WatchItem) -> WatchItem {
        var updated = item
        updated.transactions = PositionLedger.replayOrdered(transactions)
        let ledger = PositionLedger(transactions: updated.transactions)
        // The cache lot's identity is derived from the symbol rather than
        // random, so it matches the lot a merged peer snapshot derives for the
        // same position. A random id here would differ from the merge result and
        // make every local trade force one extra sync round trip.
        updated.lots = ledger.hasOpenPosition
            ? [CostLot(
                id: WatchlistSyncMerge.derivedLedgerLotID(for: item.symbol),
                price: ledger.averageCost,
                quantity: ledger.quantity,
                date: nil
            )]
            : []
        return updated
    }

    /// Duplicate canonical symbols can carry the same transaction ID from
    /// separate legacy records. Keep the first trade values while filling any
    /// execution reason or review fields that record still lacks.
    ///
    /// `fundingSource` is filled the same way and for the same reason: a copy
    /// that never learned the field must not erase what another copy recorded.
    /// An explicit `.unmarked` is a value, so it is only ever filled, never
    /// overwritten by a fallback that happens to have something else.
    ///
    /// The review's forward-looking checkpoint follows the same rule field by
    /// field, so a duplicate record that never learned `nextReviewDate` cannot
    /// erase one the other copy holds, while the two are still separate fields
    /// (`nextReviewDate`, `nextReviewNote`) that fill independently.
    static func preservingTransactionMetadata(
        _ preferred: PositionTransaction,
        from fallback: PositionTransaction
    ) -> PositionTransaction {
        var result = preferred
        if result.note == nil { result.note = fallback.note }
        if result.planExecution == nil { result.planExecution = fallback.planExecution }
        else { result.planExecution = result.planExecution?.preservingSourceAccount(from: fallback.planExecution) }
        if result.fundingSource == nil { result.fundingSource = fallback.fundingSource }
        if result.brokerageAccountID == nil { result.brokerageAccountID = fallback.brokerageAccountID }
        if result.review == nil {
            result.review = fallback.review
        } else if let fallbackReview = fallback.review {
            if var review = result.review {
                if review.followedPlan == nil { review.followedPlan = fallbackReview.followedPlan }
                if review.retrospective == nil { review.retrospective = fallbackReview.retrospective }
                if review.strategy == nil { review.strategy = fallbackReview.strategy }
                if review.nextReviewDate == nil { review.nextReviewDate = fallbackReview.nextReviewDate }
                if review.nextReviewNote == nil { review.nextReviewNote = fallbackReview.nextReviewNote }
                result.review = review
            }
        }
        return result
    }

}
