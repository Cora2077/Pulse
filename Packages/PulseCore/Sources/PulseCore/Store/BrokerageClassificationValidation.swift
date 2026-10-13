import Foundation

/// Value-only ownership checks. No live store state or persistence is published
/// by this component; the store passes before/after candidates then commits once.
@MainActor
enum BrokerageClassificationValidation {
    /// Freezes the leaving ledger into every plan reference a selected fill
    /// carries, so classification cannot silently re-interpret old data.
    ///
    /// Exactly one shape is touched: a fill that already has a `planExecution`
    /// and no recorded source gets the ledger it is leaving. A fill that has no
    /// `planExecution` is returned unchanged — it has no fill-time snapshot to
    /// preserve, and manufacturing one from the plan's current configuration
    /// would attribute to the trade a plan it was never recorded against.
    static func freezingPlanSource(
        _ transactions: [PositionTransaction],
        to source: BrokerageAccountID
    ) -> [PositionTransaction] {
        transactions.map { transaction in
            guard var execution = transaction.planExecution, execution.sourceAccountID == nil else {
                return transaction
            }
            execution.sourceAccountID = source
            var frozen = transaction
            frozen.planExecution = execution
            return frozen
        }
    }

    /// Prepares the fills a selection is moving: each one now lives in
    /// `destination`, so its own `brokerageAccountID` follows it there, and its
    /// plan source is frozen to the ledger it is leaving when it never named one.
    ///
    /// Only those two references change. The id, price, quantity, date, fee,
    /// funding source and the captured plan configuration are the trade's
    /// history and travel unchanged — a move re-files a record, it does not
    /// re-price it. A fill that already names a source keeps it: the fill's
    /// statement about which ledger owned the plan is a fact recorded at fill
    /// time, and re-interpreting it here would be exactly the silent rewrite the
    /// source field exists to prevent.
    ///
    /// A fill with no `planExecution` is returned otherwise untouched. It has no
    /// fill-time snapshot to preserve, and manufacturing one from the plan's
    /// current configuration would attribute to the trade a plan it was never
    /// recorded against.
    static func repointingMovedFills(
        _ transactions: [PositionTransaction],
        to destination: BrokerageAccountID,
        leaving source: BrokerageAccountID
    ) -> [PositionTransaction] {
        freezingPlanSource(transactions, to: source).map { transaction in
            guard transaction.brokerageAccountID != destination else { return transaction }
            var moved = transaction
            moved.brokerageAccountID = destination
            return moved
        }
    }

    /// Builds the snapshot a candidate classification *would* produce and
    /// validates it as a whole, named accounts included. Nothing is written; the
    /// caller commits only after this returns. Every account in `candidate` is
    /// carried over, so a re-pointed fill in an account the caller never named
    /// is validated rather than dropped.
    ///
    /// This is the structural half of the commit check only. It says the bytes
    /// encode; whether the plan links still mean what they meant is a separate
    /// question, asked by `planProgressIsPreserved`.
    static func validatedClassificationSnapshot(
        candidate: [BrokerageAccountID: BrokerageAccountPortfolio]
    ) -> WatchlistSyncSnapshot? {
        guard let unassigned = candidate[.unassigned] else { return nil }
        let snapshot = WatchlistSyncSnapshot(
            items: unassigned.items,
            groups: unassigned.groups,
            retainedHistoryItems: unassigned.retainedHistoryItems,
            brokerageAccounts: BrokerageAccountID.allCases
                .filter { $0 != .unassigned }
                .compactMap { candidate[$0] },
            accountSettings: unassigned.settings
        )
        guard (try? WatchlistSyncWireCodec.encode(deviceID: "classification-check", snapshot: snapshot)) != nil,
              (try? LocalBackupStore.validateSnapshot(snapshot)) != nil else { return nil }
        return snapshot
    }

    /// The semantic half of the commit check: every plan that existed before the
    /// move still exists under the name it should have afterwards, and still
    /// counts the same fills.
    ///
    /// The plan's identity here is symbol + plan id + the ledger that should hold
    /// it — a whole move carries the classified ledger's plans to `destination`,
    /// while every other plan keeps the ledger it already had. So this asks two
    /// things at once: did the plans land where the ownership rules say they
    /// should, and did the linked fills come with them. A structurally valid
    /// snapshot is not enough on its own: a re-pointed reference can encode
    /// perfectly while silently detaching a plan from its fills, and the user
    /// only finds out when the plan reads as unfilled.
    ///
    /// Progress is read with the same query the plan rows use, before and after,
    /// so the two sides can only differ because the records differ. Completion is
    /// deliberately not compared: the plan's own status is the user's mark and
    /// this check never rewrites it, so a plan closed at the same fill count
    /// stays closed.
    ///
    /// A plan that was already gone is not judged; a plan that vanished during
    /// the move fails here rather than being quietly accepted.
    static func planProgressIsPreserved(
        before: [BrokerageAccountID: BrokerageAccountPortfolio],
        in candidate: [BrokerageAccountID: BrokerageAccountPortfolio],
        sourceAccount: BrokerageAccountID,
        destination: BrokerageAccountID,
        symbol: SymbolID,
        movesWholeLedger: Bool
    ) -> Bool {
        // The ledger a plan should be found in after the move: a whole move
        // takes the classified ledger's plans with it, and leaves every other
        // plan exactly where it was.
        func expectedOwner(of account: BrokerageAccountID) -> BrokerageAccountID {
            movesWholeLedger && account == sourceAccount ? destination : account
        }
        // The pre-move read comes from the live store — `candidate` is built from
        // it and only the accounts this move touches differ — and the post-move
        // read from the candidate, so both sides are asked with the same query
        // and can only differ because the records did.
        let ledgerNow = { (account: BrokerageAccountID) in
            (before[account]?.items ?? []) + (before[account]?.retainedHistoryItems ?? [])
        }
        let ledgerAfter = { (account: BrokerageAccountID) in
            (candidate[account]?.items ?? []) + (candidate[account]?.retainedHistoryItems ?? [])
        }
        var pairs: [(before: BrokerageOwnership.ProgressRead, after: BrokerageOwnership.ProgressRead)] = []
        for account in BrokerageAccountID.allCases {
            let plans = ledgerNow(account).filter { $0.symbol == symbol }.flatMap(\.plans)
            for plan in plans {
                // An active bound sale must keep its live card. Progress alone
                // cannot detect a partial move that leaves its binding behind.
                if plan.status == .active, plan.positionPortionID != nil,
                   let previousItem = ledgerNow(account).first(where: { $0.symbol == symbol }),
                   previousItem.salePlanSource(for: plan) != nil {
                    guard let nextItem = ledgerAfter(expectedOwner(of: account)).first(where: { $0.symbol == symbol }),
                          let nextPlan = nextItem.plans.first(where: { $0.id == plan.id }),
                          nextItem.salePlanSource(for: nextPlan) != nil else { return false }
                }
                // Both readings are built from the same plan found in the same
                // ledger, and the *pair* is what carries the ownership question:
                // `after` is read from the ledger ownership says should hold the
                // plan once the move is done. Keeping the two readings of one
                // plan adjacent is what stops a namesake plan that reuses the
                // same UUID in another ledger from being paired with this one's
                // progress — the model-side comparison has only symbol and id to
                // work with, so the caller has to hand it the pairs it means.
                guard let before = Self.progressRead(account: account, symbol: symbol, plan: plan,
                                                     ledgers: ledgerNow),
                      let after = Self.progressRead(account: expectedOwner(of: account), symbol: symbol,
                                                    plan: plan, ledgers: ledgerAfter)
                else { return false }
                pairs.append((before, after))
            }
        }
        // Compared pair by pair, each side consumed once, so two namesakes in
        // two ledgers stay two separate comparisons.
        return BrokerageOwnership.planProgressIsPreserved(
            pairs: pairs.map { (before: $0.before, after: $0.after) })
    }

    /// Reads one ledger's copy of a plan into the value the classification
    /// validation compares, using the same plan-link query the plan rows use.
    ///
    /// `nil` means "this ledger has no such plan", never "no progress": the
    /// lookup is by symbol and plan id, and a ledger that does not hold the plan
    /// is a missing placement the caller has to explain.
    static func progressRead(
        account: BrokerageAccountID,
        symbol: SymbolID,
        plan: TradePlan,
        ledgers: (BrokerageAccountID) -> [WatchItem]
    ) -> BrokerageOwnership.ProgressRead? {
        guard let item = ledgers(account).first(where: { $0.symbol == symbol }),
              item.plans.contains(where: { $0.id == plan.id }) else { return nil }
        let progress = TradePlanExecutionProgress(
            plan: plan,
            transactions: WatchlistStore.transactions(
                in: BrokerageAccountID.allCases.map { (account: $0, items: ledgers($0)) },
                symbol: symbol, planID: plan.id, owningPlan: plan, source: account)
        )
        guard progress.filledQuantity.isFinite else { return nil }
        return BrokerageOwnership.ProgressRead(
            account: account, symbol: symbol, planID: plan.id,
            filledQuantity: progress.filledQuantity
        )
    }

}
