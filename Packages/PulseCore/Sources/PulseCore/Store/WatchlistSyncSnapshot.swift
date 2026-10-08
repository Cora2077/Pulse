import Foundation
import CryptoKit

/// Provider-independent, full-fidelity watchlist state for synchronization.
/// Selection is intentionally local to each installation.
public struct WatchlistSyncSnapshot: Codable, Sendable, Equatable {
    public var items: [WatchItem]
    public var groups: [WatchlistGroup]
    public var retainedHistoryItems: [WatchItem]
    /// Named accounts only. Nil means a pre-account snapshot; top-level fields
    /// always represent unassigned data, never the currently selected account.
    public var brokerageAccounts: [BrokerageAccountPortfolio]?
    public var accountSettings: BrokerageAccountSettings?

    public init(
        items: [WatchItem],
        groups: [WatchlistGroup],
        retainedHistoryItems: [WatchItem] = [],
        brokerageAccounts: [BrokerageAccountPortfolio]? = nil,
        accountSettings: BrokerageAccountSettings? = nil
    ) {
        self.items = items
        self.groups = groups
        self.retainedHistoryItems = retainedHistoryItems
        self.brokerageAccounts = brokerageAccounts
        self.accountSettings = accountSettings
    }

    public var allAccountItems: [WatchItem] {
        items + retainedHistoryItems + (brokerageAccounts ?? []).flatMap { $0.items + $0.retainedHistoryItems }
    }

    public var hasAccountSettings: Bool {
        accountSettings != nil || (brokerageAccounts ?? []).contains { $0.settings != nil }
    }
}

/// Deterministic three-way merge for snapshots from two devices and their last
/// common snapshot. Transaction edits that cannot be reconciled are reported.
public enum WatchlistSyncMerge {
    public struct PositionAllocationConflict: Sendable, Equatable, Identifiable {
        public var symbol: SymbolID
        public var base: PositionAllocation?
        public var local: PositionAllocation?
        public var remote: PositionAllocation?
        public var id: String { symbol.description }

        public init(symbol: SymbolID, base: PositionAllocation?, local: PositionAllocation?, remote: PositionAllocation?) {
            self.symbol = symbol
            self.base = base
            self.local = local
            self.remote = remote
        }
    }

    public struct TransactionConflict: Sendable, Equatable, Identifiable {
        public var symbol: SymbolID
        public var transactionID: UUID
        public var base: PositionTransaction?
        public var local: PositionTransaction?
        public var remote: PositionTransaction?

        public var id: String { "\(symbol.description):\(transactionID.uuidString)" }

        public init(
            symbol: SymbolID,
            transactionID: UUID,
            base: PositionTransaction?,
            local: PositionTransaction?,
            remote: PositionTransaction?
        ) {
            self.symbol = symbol
            self.transactionID = transactionID
            self.base = base
            self.local = local
            self.remote = remote
        }
    }

    /// Account assignment can move history between portfolios. Conflicting
    /// assignments require one complete side, so a trade cannot exist twice.
    public struct BrokerageConflict: Sendable, Equatable {
        public var accountIDs: [BrokerageAccountID]
        public var local: WatchlistSyncSnapshot
        public var remote: WatchlistSyncSnapshot
    }

    public struct Result: Sendable, Equatable {
        /// Includes all non-conflicting changes. A conflicting transaction uses
        /// the local version provisionally; callers should resolve conflicts
        /// before applying this snapshot or advancing their common base.
        public var snapshot: WatchlistSyncSnapshot
        public var conflicts: [TransactionConflict]
        public var positionAllocationConflicts: [PositionAllocationConflict]
        public var brokerageConflict: BrokerageConflict? = nil
        fileprivate var transactionOrderSources: [SymbolID: [[PositionTransaction]]]

        public var isConflictFree: Bool { conflicts.isEmpty && positionAllocationConflicts.isEmpty && brokerageConflict == nil }

        public init(
            snapshot: WatchlistSyncSnapshot,
            conflicts: [TransactionConflict],
            positionAllocationConflicts: [PositionAllocationConflict] = []
        ) {
            self.snapshot = snapshot
            self.conflicts = conflicts
            self.positionAllocationConflicts = positionAllocationConflicts
            self.transactionOrderSources = [:]
        }

        fileprivate init(
            snapshot: WatchlistSyncSnapshot,
            conflicts: [TransactionConflict],
            positionAllocationConflicts: [PositionAllocationConflict],
            transactionOrderSources: [SymbolID: [[PositionTransaction]]]
        ) {
            self.snapshot = snapshot
            self.conflicts = conflicts
            self.positionAllocationConflicts = positionAllocationConflicts
            self.transactionOrderSources = transactionOrderSources
        }
    }

    public enum ConflictResolution: Sendable, Equatable {
        case local
        case remote
    }

    /// A conflict choice applies to every conflicting transaction in this merge.
    /// Choosing a missing value means the chosen device deleted that transaction.
    public static func resolve(
        _ result: Result,
        choosing resolution: ConflictResolution
    ) -> WatchlistSyncSnapshot {
        if let conflict = result.brokerageConflict {
            return resolution == .local ? conflict.local : conflict.remote
        }
        var snapshot = result.snapshot
        for conflict in result.conflicts {
            var selected = resolution == .local ? conflict.local : conflict.remote
            if selected?.planExecution == nil {
                selected?.planExecution = conflict.local?.planExecution ?? conflict.remote?.planExecution ?? conflict.base?.planExecution
            }
            for candidate in [conflict.local, conflict.remote, conflict.base] {
                let execution = selected?.planExecution?.preservingSourceAccount(from: candidate?.planExecution)
                selected?.planExecution = execution
            }
            if selected?.brokerageAccountID == nil {
                selected?.brokerageAccountID = conflict.local?.brokerageAccountID
                    ?? conflict.remote?.brokerageAccountID ?? conflict.base?.brokerageAccountID
            }
            if selected?.fundingSource == nil {
                selected?.fundingSource = conflict.local?.fundingSource
                    ?? conflict.remote?.fundingSource
                    ?? conflict.base?.fundingSource
            }
            // Resolving a conflict means picking one device's trade, so its
            // review travels with it unchanged. A nil review on the chosen side
            // is either "never learned" or "the user cleared it", and filling
            // from the side they just rejected would override their pick.
            replaceTransaction(
                selected,
                id: conflict.transactionID,
                symbol: conflict.symbol,
                preservingOrderFrom: result.transactionOrderSources[conflict.symbol] ?? [],
                in: &snapshot
            )
        }
        for conflict in result.positionAllocationConflicts {
            replacePositionAllocation(
                resolution == .local ? conflict.local : conflict.remote,
                for: conflict.symbol,
                in: &snapshot
            )
        }
        snapshot.retainedHistoryItems.removeAll {
            $0.materializedTransactions().isEmpty && $0.drawings.isEmpty
                && $0.tradingProfile == nil && $0.events.isEmpty && $0.positionAllocation == nil
                && $0.thesis == nil && $0.plans.isEmpty
        }
        return snapshot
    }

    public static func merge(
        base: WatchlistSyncSnapshot,
        local: WatchlistSyncSnapshot,
        remote: WatchlistSyncSnapshot
    ) -> Result {
        var local = local
        var remote = remote
        func inheritSettings(_ snapshot: inout WatchlistSyncSnapshot) {
            if snapshot.accountSettings == nil { snapshot.accountSettings = base.accountSettings }
            if snapshot.brokerageAccounts != nil {
                for index in snapshot.brokerageAccounts!.indices {
                    if snapshot.brokerageAccounts![index].settings == nil {
                        let id = snapshot.brokerageAccounts![index].accountID
                        snapshot.brokerageAccounts![index].settings = base.brokerageAccounts?.first { $0.accountID == id }?.settings
                    }
                }
            }
        }
        inheritSettings(&local)
        inheritSettings(&remote)
        var conflicts: [TransactionConflict] = []
        var allocationConflicts: [PositionAllocationConflict] = []
        let mergedGroups = mergeGroups(base: base.groups, local: local.groups, remote: remote.groups)
        let baseItems = itemMap(base)
        let localItems = itemMap(local)
        let remoteItems = itemMap(remote)
        let symbols = Set(baseItems.keys).union(localItems.keys).union(remoteItems.keys)

        var mergedBySymbol: [SymbolID: WatchItem] = [:]
        for symbol in symbols.sorted(by: symbolLessThan) {
            let merged = mergeItem(
                symbol: symbol,
                base: baseItems[symbol],
                local: localItems[symbol],
                remote: remoteItems[symbol],
                conflicts: &conflicts,
                allocationConflicts: &allocationConflicts
            )
            if let merged { mergedBySymbol[symbol] = merged }
        }
        let conflictedSymbols = Set(conflicts.map(\.symbol))
            .union(allocationConflicts.map(\.symbol))

        let survivingSymbols = Set(mergedBySymbol.keys)
        var groups = mergedGroups
        for index in groups.indices {
            groups[index].symbols = groups[index].symbols.filter { survivingSymbols.contains($0) }
            if let order = groups[index].manualOrder {
                groups[index].manualOrder = order.filter { survivingSymbols.contains($0) }
            }
            let members = Set(groups[index].symbols)
            groups[index].pinnedSymbols = groups[index].pinnedSymbols.filter { members.contains($0) }
        }

        let groupedSymbols = Set(groups.flatMap(\.symbols))
        let baseActive = Set(base.items.map(\.symbol))
        let localActive = Set(local.items.map(\.symbol))
        let remoteActive = Set(remote.items.map(\.symbol))
        let baseMembership = Set(base.groups.flatMap(\.symbols))
        let localMembership = Set(local.groups.flatMap(\.symbols))
        let remoteMembership = Set(remote.groups.flatMap(\.symbols))
        let baseRetained = Set(base.retainedHistoryItems.map(\.symbol))
        let localRetained = Set(local.retainedHistoryItems.map(\.symbol))
        let remoteRetained = Set(remote.retainedHistoryItems.map(\.symbol))

        var active: [SymbolID: WatchItem] = [:]
        var retained: [SymbolID: WatchItem] = [:]
        for (symbol, item) in mergedBySymbol {
            if groupedSymbols.contains(symbol) {
                active[symbol] = item
            } else if baseMembership.contains(symbol)
                        || localMembership.contains(symbol)
                        || remoteMembership.contains(symbol) {
                // The symbol was a list member on at least one input, but the
                // merged membership says it was removed. A concurrently added
                // trade survives as dormant history; it must not be normalized
                // back into the default group as a group-less active item.
                if !item.materializedTransactions().isEmpty
                    || !item.drawings.isEmpty
                    || item.tradingProfile != nil || !item.events.isEmpty
                    || item.positionAllocation != nil || item.thesis != nil || !item.plans.isEmpty
                    || conflictedSymbols.contains(symbol) {
                    retained[symbol] = item
                }
            } else if localRetained.contains(symbol) || remoteRetained.contains(symbol) || baseRetained.contains(symbol) {
                retained[symbol] = item
            } else if localActive.contains(symbol) || remoteActive.contains(symbol) || baseActive.contains(symbol) {
                // Group-less active items are supported by WatchlistStore for detail pages.
                active[symbol] = item
            } else if !item.materializedTransactions().isEmpty
                        || item.tradingProfile != nil || !item.events.isEmpty
                        || item.positionAllocation != nil || item.thesis != nil || !item.plans.isEmpty {
                retained[symbol] = item
            }
        }

        let itemOrder = mergeOrder(
            base: base.items.map(\.symbol),
            local: local.items.map(\.symbol),
            remote: remote.items.map(\.symbol),
            allowed: Set(active.keys)
        )
        let retainedOrder = mergeOrder(
            base: base.retainedHistoryItems.map(\.symbol),
            local: local.retainedHistoryItems.map(\.symbol),
            remote: remote.retainedHistoryItems.map(\.symbol),
            allowed: Set(retained.keys)
        )
        let groupOrder = mergeOrder(
            base: base.groups.map(\.id),
            local: local.groups.map(\.id),
            remote: remote.groups.map(\.id),
            allowed: Set(groups.map(\.id))
        )
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })

        conflicts.sort {
            if $0.symbol != $1.symbol { return symbolLessThan($0.symbol, $1.symbol) }
            return $0.transactionID.uuidString < $1.transactionID.uuidString
        }
        allocationConflicts.sort { symbolLessThan($0.symbol, $1.symbol) }
        let transactionOrderSources = Dictionary(uniqueKeysWithValues: conflictedSymbols.map { symbol in
            (symbol, [
                baseItems[symbol]?.transactions ?? [],
                localItems[symbol]?.transactions ?? [],
                remoteItems[symbol]?.transactions ?? []
            ])
        })
        var result = Result(snapshot: WatchlistSyncSnapshot(
            items: itemOrder.compactMap { active[$0] },
            groups: groupOrder.compactMap { groupsByID[$0] },
            retainedHistoryItems: retainedOrder.compactMap { retained[$0] }
        ), conflicts: conflicts, positionAllocationConflicts: allocationConflicts,
            transactionOrderSources: transactionOrderSources)
        let settingsDisputed: Bool
        if local.accountSettings == remote.accountSettings {
            result.snapshot.accountSettings = local.accountSettings; settingsDisputed = false
        } else if local.accountSettings == base.accountSettings {
            result.snapshot.accountSettings = remote.accountSettings; settingsDisputed = false
        } else if remote.accountSettings == base.accountSettings {
            result.snapshot.accountSettings = local.accountSettings; settingsDisputed = false
        } else {
            result.snapshot.accountSettings = local.accountSettings; settingsDisputed = true
        }
        if base.brokerageAccounts != nil || local.brokerageAccounts != nil || remote.brokerageAccounts != nil || settingsDisputed {
            let b = Dictionary(uniqueKeysWithValues: (base.brokerageAccounts ?? []).map { ($0.accountID, $0) })
            let l = Dictionary(uniqueKeysWithValues: (local.brokerageAccounts ?? base.brokerageAccounts ?? []).map { ($0.accountID, $0) })
            let r = Dictionary(uniqueKeysWithValues: (remote.brokerageAccounts ?? base.brokerageAccounts ?? []).map { ($0.accountID, $0) })
            var merged: [BrokerageAccountPortfolio] = []
            var disputed: [BrokerageAccountID] = settingsDisputed ? [.unassigned] : []
            for id in BrokerageAccountID.allCases where id != .unassigned {
                let chosen: BrokerageAccountPortfolio?
                if l[id] == r[id] { chosen = l[id] }
                else if l[id] == b[id] { chosen = r[id] }
                else if r[id] == b[id] { chosen = l[id] }
                else { chosen = l[id]; disputed.append(id) }
                if var chosen {
                    // Whole-portfolio conflict policy still preserves fields an
                    // older peer never learned on surviving transactions.
                    func preserveAnnotations(_ items: inout [WatchItem]) {
                        for itemIndex in items.indices {
                            let symbol = items[itemIndex].symbol
                            let candidates = [l[id], r[id], b[id]].compactMap { $0 }
                                .flatMap { $0.items + $0.retainedHistoryItems }
                                .filter { $0.symbol == symbol }.flatMap(\.transactions)
                            for transactionIndex in items[itemIndex].transactions.indices {
                                var transaction = items[itemIndex].transactions[transactionIndex]
                                for candidate in candidates where candidate.id == transaction.id {
                                    if transaction.planExecution == nil { transaction.planExecution = candidate.planExecution }
                                    else { transaction.planExecution = transaction.planExecution?.preservingSourceAccount(from: candidate.planExecution) }
                                    if transaction.brokerageAccountID == nil { transaction.brokerageAccountID = candidate.brokerageAccountID }
                                    if transaction.fundingSource == nil { transaction.fundingSource = candidate.fundingSource }
                                }
                                items[itemIndex].transactions[transactionIndex] = transaction
                            }
                        }
                    }
                    preserveAnnotations(&chosen.items)
                    preserveAnnotations(&chosen.retainedHistoryItems)
                    merged.append(chosen)
                }
            }
            result.snapshot.brokerageAccounts = merged
            // Two devices can assign the same legacy trade to different accounts.
            // Never let an otherwise conflict-free merge duplicate that history.
            var tradeIDs = Set<UUID>()
            let duplicated = result.snapshot.allAccountItems.flatMap(\.transactions).contains {
                !tradeIDs.insert($0.id).inserted
            }
            if !disputed.isEmpty || duplicated {
                result.brokerageConflict = BrokerageConflict(
                    accountIDs: duplicated ? BrokerageAccountID.allCases : disputed,
                    local: local, remote: remote
                )
                result.snapshot = local
                result.conflicts = []
                result.positionAllocationConflicts = []
            }
        }
        return result
    }

    private static func itemMap(_ snapshot: WatchlistSyncSnapshot) -> [SymbolID: WatchItem] {
        var result: [SymbolID: WatchItem] = [:]
        // Active wins on duplicate malformed payloads; store normalization will
        // also canonicalize IDs before snapshots are normally exported.
        for item in snapshot.retainedHistoryItems { result[item.symbol] = item }
        for item in snapshot.items { result[item.symbol] = item }
        return result
    }

    private static func mergeItem(
        symbol: SymbolID,
        base: WatchItem?,
        local: WatchItem?,
        remote: WatchItem?,
        conflicts: inout [TransactionConflict],
        allocationConflicts: inout [PositionAllocationConflict]
    ) -> WatchItem? {
        let initialConflictCount = conflicts.count
        let baseTransactions = transactionMap(base?.transactions ?? [])
        let localTransactions = transactionMap(local?.transactions ?? [])
        let remoteTransactions = transactionMap(remote?.transactions ?? [])
        let transactionIDs = Set(baseTransactions.keys)
            .union(localTransactions.keys)
            .union(remoteTransactions.keys)
        var transactions: [PositionTransaction] = []

        for id in transactionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let b = baseTransactions[id]
            let l = localTransactions[id]
            let r = remoteTransactions[id]
            let chosen: PositionTransaction?
            if l == r {
                chosen = l
            } else if l == b {
                chosen = r
            } else if r == b {
                chosen = l
            } else {
                conflicts.append(TransactionConflict(
                    symbol: symbol,
                    transactionID: id,
                    base: b,
                    local: l,
                    remote: r
                ))
                chosen = l
            }
            if var chosen {
                if chosen.planExecution == nil {
                    chosen.planExecution = l?.planExecution ?? r?.planExecution ?? b?.planExecution
                }
                for candidate in [l, r, b] {
                    chosen.planExecution = chosen.planExecution?.preservingSourceAccount(from: candidate?.planExecution)
                }
                // A transaction that reached this device without the funding
                // field must not erase one another device recorded. `nil` means
                // "never learned", so it is the only value that gets filled;
                // an explicit `.unmarked` is a real decision and stays put.
                if chosen.fundingSource == nil {
                    chosen.fundingSource = l?.fundingSource ?? r?.fundingSource ?? b?.fundingSource
                }
                if chosen.brokerageAccountID == nil {
                    chosen.brokerageAccountID = l?.brokerageAccountID ?? r?.brokerageAccountID ?? b?.brokerageAccountID
                }
                // The review's checkpoint fields fill the same way, one field at
                // a time, so a peer that never learned `nextReviewDate` does not
                // drop the one this copy holds while keeping its own note. A
                // wholly missing review is only adopted from the peer that
                // changed it when this copy is the untouched base — `nil` on a
                // copy that changed can be an explicit clearing, and undoing
                // that would resurrect a review the user deleted.
                chosen.review = mergedTransactionReview(
                    chosen: chosen,
                    base: b,
                    local: l,
                    remote: r
                )
                transactions.append(chosen)
            }
        }

        let mergedLots = mergeLots(base: base?.lots ?? [], local: local?.lots ?? [], remote: remote?.lots ?? [])
        let allocation = mergePositionAllocation(
            symbol: symbol,
            base: base?.positionAllocation,
            local: local?.positionAllocation,
            remote: remote?.positionAllocation,
            conflicts: &allocationConflicts
        )
        let value = mergeOptionalItemPresence(base: base, local: local, remote: remote)
        guard let seed = value else {
            // A separately added transaction is meaningful even when a device
            // removed the instrument itself; keep its history available. The
            // surviving copy supplies the display metadata. Keep an empty
            // retained placeholder for a conflict too: the user's eventual
            // remote choice must have somewhere to place the edited trade
            // without restoring the deleted watchlist membership.
            let hasTransactionConflict = conflicts.count > initialConflictCount
            let hasAllocationConflict = allocationConflicts.contains { $0.symbol == symbol }
            let drawings = ChartDrawingMerge.merge(
                base: base?.drawings ?? [],
                local: local?.drawings ?? [],
                remote: remote?.drawings ?? []
            )
            let tradingProfile = mergeTradingProfile(
                base: base?.tradingProfile,
                local: local?.tradingProfile,
                remote: remote?.tradingProfile
            )
            let events = InstrumentEventMerge.merge(
                base: base?.events ?? [],
                local: local?.events ?? [],
                remote: remote?.events ?? []
            )
            guard !transactions.isEmpty || hasTransactionConflict || !drawings.isEmpty
                    || tradingProfile != nil || !events.isEmpty || allocation != nil
                    || hasAllocationConflict || !(base?.plans.isEmpty ?? true)
                    || !(local?.plans.isEmpty ?? true) || !(remote?.plans.isEmpty ?? true)
                    || base?.thesis != nil || local?.thesis != nil || remote?.thesis != nil else { return nil }
            let source = local ?? remote ?? base
            return WatchItem(
                symbol: symbol,
                displayName: source?.displayName ?? symbol.displayCode,
                displayNameSource: source?.displayNameSource,
                instrumentType: source?.instrumentType,
                addedAt: source?.addedAt ?? .now,
                lots: [],
                transactions: replay(transactions, preservingOrderFrom: [
                    base?.transactions ?? [], local?.transactions ?? [], remote?.transactions ?? []
                ]),
                // Plans and drawings follow durable user-authored history into
                // the retained item rather than vanishing with membership.
                thesis: threeWay(base?.thesis, local?.thesis, remote?.thesis),
                plans: mergePlans(base: base?.plans ?? [], local: local?.plans ?? [], remote: remote?.plans ?? []),
                drawings: drawings,
                tradingProfile: tradingProfile,
                events: events,
                positionAllocation: allocation
            )
        }

        var result = seed
        result.symbol = symbol
        result.displayName = threeWay(
            base?.displayName,
            local?.displayName,
            remote?.displayName,
            fallback: symbol.displayCode
        ) ?? symbol.displayCode
        result.displayNameSource = threeWay(base?.displayNameSource, local?.displayNameSource, remote?.displayNameSource)
        result.instrumentType = threeWay(base?.instrumentType, local?.instrumentType, remote?.instrumentType)
        result.addedAt = threeWay(base?.addedAt, local?.addedAt, remote?.addedAt, fallback: seed.addedAt) ?? seed.addedAt
        result.thesis = threeWay(base?.thesis, local?.thesis, remote?.thesis)
        result.tradingProfile = mergeTradingProfile(
            base: base?.tradingProfile,
            local: local?.tradingProfile,
            remote: remote?.tradingProfile
        )
        result.plans = mergePlans(
            base: base?.plans ?? [],
            local: local?.plans ?? [],
            remote: remote?.plans ?? []
        )
        result.drawings = ChartDrawingMerge.merge(
            base: base?.drawings ?? [],
            local: local?.drawings ?? [],
            remote: remote?.drawings ?? []
        )
        result.events = InstrumentEventMerge.merge(
            base: base?.events ?? [],
            local: local?.events ?? [],
            remote: remote?.events ?? []
        )
        result.positionAllocation = allocation
        result.transactions = replay(transactions, preservingOrderFrom: [
            base?.transactions ?? [], local?.transactions ?? [], remote?.transactions ?? []
        ])
        if result.transactions.isEmpty {
            let hadTransactionHistory = [base, local, remote].contains { item in
                !(item?.transactions.isEmpty ?? true)
            }
            result.lots = hadTransactionHistory ? [] : mergedLots
        } else {
            let ledger = PositionLedger(transactions: result.transactions)
            result.lots = ledger.hasOpenPosition
                ? [derivedLedgerLot(symbol: symbol, ledger: ledger)]
                : []
        }
        return result
    }

    /// If the user deleted an item on one device and the other has only its
    /// unchanged copy, the deletion wins. New transactions are still retained.
    private static func mergeOptionalItemPresence(
        base: WatchItem?, local: WatchItem?, remote: WatchItem?
    ) -> WatchItem? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        if local == nil || remote == nil { return nil }
        return canonicalChoice(local!, remote!)
    }

    /// Three-way merge for trade plans, by id.
    ///
    /// A plan both devices changed is settled by `updatedAt` rather than
    /// reported as a conflict. The conflict channel and its UI are the trade
    /// channel — a trade is worth interrupting someone over because it is real
    /// money, while a plan is a note to self that costs nothing to redo. Asking
    /// would also mean extending the conflict enum and its resolution UI for a
    /// case nobody needs.
    ///
    /// `updatedAt` rather than `canonicalChoice`: the latter picks by encoded
    /// byte order, which for hand-written content is the same as picking at
    /// random. Older clock skew on one device degrades that to a coin flip, but
    /// still a deterministic, converging one.
    private static func mergePlans(
        base: [TradePlan], local: [TradePlan], remote: [TradePlan]
    ) -> [TradePlan] {
        let b = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let l = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let r = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [TradePlan] = []
        for id in Set(b.keys).union(l.keys).union(r.keys) {
            let basePlan = b[id]
            let localPlan = l[id]
            let remotePlan = r[id]
            let chosen: TradePlan?
            if localPlan == remotePlan {
                chosen = localPlan
            } else if localPlan == basePlan {
                chosen = remotePlan
            } else if remotePlan == basePlan {
                chosen = localPlan
            } else {
                chosen = newer(localPlan, remotePlan)
            }
            if var chosen {
                chosen.conditions = chosen.conditions ?? localPlan?.conditions ?? remotePlan?.conditions ?? basePlan?.conditions
                chosen.conditions = filledConditionEventReferences(
                    chosen.conditions,
                    localPlan?.conditions,
                    remotePlan?.conditions,
                    basePlan?.conditions
                )
                // Same rule as transactions: a missing annotation is filled
                // from a peer that has one, and an explicit `.unmarked` wins
                // for itself rather than being treated as absent.
                if chosen.fundingSource == nil {
                    chosen.fundingSource = localPlan?.fundingSource
                        ?? remotePlan?.fundingSource
                        ?? basePlan?.fundingSource
                }
                let revisions = (chosen.history ?? []) + (localPlan?.history ?? []) + (remotePlan?.history ?? []) + (basePlan?.history ?? [])
                if !revisions.isEmpty {
                    chosen.history = Dictionary(revisions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        .values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
                }
                merged.append(chosen)
            }
        }
        return TradePlan.ordered(merged)
    }

    /// Fills the review's forward-looking checkpoint from whichever side holds
    /// one, field by field, keeping the chosen review's own values.
    ///
    /// Fill missing fields only when the common base did not know them.
    /// A nil field previously present in the base is an explicit clearing.
    private static func mergedReview(
        _ chosen: PositionTransactionReview,
        _ local: PositionTransactionReview?,
        _ remote: PositionTransactionReview?,
        _ base: PositionTransactionReview?
    ) -> PositionTransactionReview {
        var result = chosen
        if result.nextReviewDate == nil, base?.nextReviewDate == nil {
            result.nextReviewDate = local?.nextReviewDate ?? remote?.nextReviewDate ?? base?.nextReviewDate
        }
        if result.nextReviewNote == nil, base?.nextReviewNote == nil {
            result.nextReviewNote = local?.nextReviewNote ?? remote?.nextReviewNote ?? base?.nextReviewNote
        }
        return result
    }

    /// Picks and completes the review of the transaction the merge chose.
    ///
    /// Within a review the checkpoint fields fill in independently. A wholly
    /// missing review is only adopted from the other side when the chosen copy
    /// is the untouched base, because `nil` on a copy that changed is
    /// indistinguishable from the user clearing it — and resurrecting a
    /// deliberately deleted review is worse than leaving it absent. When the
    /// chosen copy already holds a review, the missing checkpoint fields are
    /// still filled from the peers.
    private static func mergedTransactionReview(
        chosen: PositionTransaction,
        base: PositionTransaction?,
        local: PositionTransaction?,
        remote: PositionTransaction?
    ) -> PositionTransactionReview? {
        if let review = chosen.review {
            return mergedReview(review, local?.review, remote?.review, base?.review)
        }
        guard chosen == base, let adopted = local?.review ?? remote?.review ?? base?.review else {
            return nil
        }
        return mergedReview(adopted, local?.review, remote?.review, base?.review)
    }

    /// Fills a plan condition's linked event snapshot from a peer that has one.
    ///
    /// A plan's conditions are merged as a whole (`chosen.conditions`), so a
    /// copy that predates the event-reference field would otherwise let the
    /// link disappear. Conditions are matched by id and only a `nil` reference
    /// is filled — an existing snapshot is the user's link and is never
    /// replaced by a lookalike from another device.
    private static func filledConditionEventReferences(
        _ conditions: [TradePlanCondition]?,
        _ local: [TradePlanCondition]?,
        _ remote: [TradePlanCondition]?,
        _ base: [TradePlanCondition]?
    ) -> [TradePlanCondition]? {
        guard var conditions else { return nil }
        var sources: [UUID: InstrumentEvent] = [:]
        for list in [base, local, remote] {
            for condition in list ?? [] {
                guard let reference = condition.eventReference, sources[condition.id] == nil else { continue }
                sources[condition.id] = reference
            }
        }
        guard !sources.isEmpty else { return conditions }
        for index in conditions.indices where conditions[index].eventReference == nil {
            // If the common base knew this link, absence is an unlink edit.
            guard base?.first(where: { $0.id == conditions[index].id })?.eventReference == nil else { continue }
            if let reference = sources[conditions[index].id] {
                conditions[index].eventReference = reference
            }
        }
        return conditions
    }

    private static func mergeTradingProfile(
        base: TradingProfile?, local: TradingProfile?, remote: TradingProfile?
    ) -> TradingProfile? {
        let merged = TradingProfile(
            sector: threeWay(base?.sector, local?.sector, remote?.sector),
            stopPrice: threeWay(base?.stopPrice, local?.stopPrice, remote?.stopPrice),
            targetPrice: threeWay(base?.targetPrice, local?.targetPrice, remote?.targetPrice)
        )
        return merged.sector == nil && merged.stopPrice == nil && merged.targetPrice == nil ? nil : merged
    }

    private static func mergePositionAllocation(
        symbol: SymbolID,
        base: PositionAllocation?,
        local: PositionAllocation?,
        remote: PositionAllocation?,
        conflicts: inout [PositionAllocationConflict]
    ) -> PositionAllocation? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        conflicts.append(PositionAllocationConflict(
            symbol: symbol,
            base: base,
            local: local,
            remote: remote
        ))
        return local
    }

    private static func newer(_ local: TradePlan?, _ remote: TradePlan?) -> TradePlan? {
        switch (local, remote) {
        case (nil, let remote): return remote
        case (let local, nil): return local
        case (let local?, let remote?):
            if local.updatedAt != remote.updatedAt {
                return local.updatedAt > remote.updatedAt ? local : remote
            }
            // Same timestamp — two devices editing within one clock tick. Fall
            // back to the encoding order so both of them land on the same one.
            return canonicalChoice(local, remote)
        }
    }

    private static func mergeLots(base: [CostLot], local: [CostLot], remote: [CostLot]) -> [CostLot] {
        let b = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let l = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let r = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let values = Set(b.keys).union(l.keys).union(r.keys).sorted { $0.uuidString < $1.uuidString }
        return values.compactMap { id in
            let localValue = l[id]
            let remoteValue = r[id]
            if localValue == remoteValue { return localValue }
            if localValue == b[id] { return remoteValue }
            if remoteValue == b[id] { return localValue }
            return canonicalChoice(localValue, remoteValue)
        }
    }

    private static func transactionMap(_ transactions: [PositionTransaction]) -> [UUID: PositionTransaction] {
        var result: [UUID: PositionTransaction] = [:]
        for transaction in transactions { result[transaction.id] = transaction }
        return result
    }

    private struct ReplayOrderKey: Hashable {
        var day: CalendarDay
        var createdAt: Date

        init(_ transaction: PositionTransaction) {
            day = CalendarDay(transaction.date, in: .current)
            createdAt = transaction.createdAt
        }
    }

    private static func replay(
        _ transactions: [PositionTransaction],
        preservingOrderFrom sources: [[PositionTransaction]]
    ) -> [PositionTransaction] {
        let valuesByID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        var groups: [ReplayOrderKey: Set<UUID>] = [:]
        for transaction in transactions {
            groups[ReplayOrderKey(transaction), default: []].insert(transaction.id)
        }
        guard groups.values.contains(where: { $0.count > 1 }) else {
            return PositionLedger.replayOrdered(transactions)
        }

        let sourceOrders = sources.map { source in
            var groups: [ReplayOrderKey: [UUID]] = [:]
            for transaction in source {
                groups[ReplayOrderKey(transaction), default: []].append(transaction.id)
            }
            return groups
        }
        var ordered: [PositionTransaction] = []
        for (key, ids) in groups {
            if ids.count == 1 {
                ordered.append(valuesByID[ids.first!]!)
                continue
            }
            var outgoing: [UUID: Set<UUID>] = [:]
            var indegree = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
            for source in sourceOrders {
                var previous: UUID?
                for id in source[key] ?? [] where ids.contains(id) {
                    guard previous != id else { continue }
                    if let previous, outgoing[previous, default: []].insert(id).inserted {
                        indegree[id, default: 0] += 1
                    }
                    previous = id
                }
            }

            var remaining = ids
            while !remaining.isEmpty {
                let ready = remaining.filter { indegree[$0, default: 0] == 0 }
                // UUID order only breaks ties among unrelated additions, or an
                // incompatible cycle left by older divergent transaction orders.
                let next = (ready.isEmpty ? remaining : ready).min { $0.uuidString < $1.uuidString }!
                ordered.append(valuesByID[next]!)
                remaining.remove(next)
                for target in outgoing[next, default: []] where remaining.contains(target) {
                    indegree[target, default: 0] -= 1
                }
            }
        }
        return PositionLedger.replayOrdered(ordered)
    }

    private static func mergeGroups(
        base: [WatchlistGroup], local: [WatchlistGroup], remote: [WatchlistGroup]
    ) -> [WatchlistGroup] {
        let baseByID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        var rows: [(id: UUID, base: WatchlistGroup?, local: WatchlistGroup?, remote: WatchlistGroup?)] = []
        var usedLocal = Set<UUID>()
        var usedRemote = Set<UUID>()

        for group in base {
            let l = localByID[group.id]
            let r = remoteByID[group.id]
            if l != nil { usedLocal.insert(group.id) }
            if r != nil { usedRemote.insert(group.id) }
            rows.append((group.id, group, l, r))
        }

        let unmatchedLocal = local.filter { !usedLocal.contains($0.id) }
        let baseIDs = Set(baseByID.keys)
        for localGroup in unmatchedLocal {
            let matchingRemote = remote.first {
                $0.id == localGroup.id && !usedRemote.contains($0.id)
            } ?? remote.first {
                !usedRemote.contains($0.id)
                    && !baseIDs.contains($0.id)
                    && normalizedGroupName($0.name) == normalizedGroupName(localGroup.name)
            }
            usedLocal.insert(localGroup.id)
            if let matchingRemote {
                usedRemote.insert(matchingRemote.id)
                let canonicalID = min(localGroup.id.uuidString, matchingRemote.id.uuidString)
                    == localGroup.id.uuidString ? localGroup.id : matchingRemote.id
                rows.append((canonicalID, nil, localGroup, matchingRemote))
            } else {
                rows.append((localGroup.id, nil, localGroup, nil))
            }
        }
        for remoteGroup in remote where !usedRemote.contains(remoteGroup.id) {
            rows.append((remoteGroup.id, nil, nil, remoteGroup))
        }

        var result: [UUID: WatchlistGroup] = [:]
        for row in rows {
            let b = row.base
            let l = row.local
            let r = row.remote
            let chosen: WatchlistGroup?
            if l == r {
                chosen = l
            } else if l == b {
                chosen = r
            } else if r == b {
                chosen = l
            } else if l == nil || r == nil {
                // Deleting a group against a stale but changed copy keeps the
                // changed copy. Unchanged stale groups were handled above.
                chosen = l ?? r
            } else {
                chosen = mergeGroup(base: b, local: l!, remote: r!, id: row.id)
            }
            if let chosen { result[row.id] = chosen }
        }

        let rowsByID = Dictionary(uniqueKeysWithValues: result.map { ($0.key, $0.value) })
        let baseOrder = base.map(\.id).filter { rowsByID[$0] != nil }
        let localOrder = local.map { canonicalGroupID(for: $0, rows: rows) }.filter { rowsByID[$0] != nil }
        let remoteOrder = remote.map { canonicalGroupID(for: $0, rows: rows) }.filter { rowsByID[$0] != nil }
        // Base IDs coalesced by name may have been replaced by a canonical ID.
        let canonicalBaseOrder = baseOrder.map { id in rows.first(where: { $0.base?.id == id })?.id ?? id }
        let orderedIDs = mergeOrder(
            base: canonicalBaseOrder,
            local: localOrder,
            remote: remoteOrder,
            allowed: Set(result.keys)
        )
        return orderedIDs.compactMap { result[$0] }
    }

    private static func canonicalGroupID(for group: WatchlistGroup, rows: [(id: UUID, base: WatchlistGroup?, local: WatchlistGroup?, remote: WatchlistGroup?)]) -> UUID {
        rows.first(where: { $0.local?.id == group.id || $0.remote?.id == group.id })?.id ?? group.id
    }

    private static func mergeGroup(
        base: WatchlistGroup?, local: WatchlistGroup, remote: WatchlistGroup, id: UUID
    ) -> WatchlistGroup {
        let baseSymbols = base?.symbols ?? []
        let members = mergeMembership(base: baseSymbols, local: local.symbols, remote: remote.symbols)
        let symbolOrder = mergeOrder(
            base: baseSymbols,
            local: local.symbols,
            remote: remote.symbols,
            allowed: members
        )

        let basePins = base?.pinnedSymbols ?? []
        let pins = mergeMembership(base: basePins, local: local.pinnedSymbols, remote: remote.pinnedSymbols)
            .intersection(members)
        let pinOrder = mergeOrder(
            base: basePins,
            local: local.pinnedSymbols,
            remote: remote.pinnedSymbols,
            allowed: pins
        )
        let baseManual = base?.manualOrder
        let manual = mergeOptionalOrder(
            base: baseManual,
            local: local.manualOrder,
            remote: remote.manualOrder,
            allowed: members
        )
        return WatchlistGroup(
            id: id,
            name: threeWay(base?.name, local.name, remote.name, fallback: local.name) ?? local.name,
            symbols: symbolOrder,
            manualOrder: manual,
            pinnedSymbols: pinOrder
        )
    }

    private static func mergeMembership<Element: Hashable & Encodable>(
        base: [Element], local: [Element], remote: [Element]
    ) -> Set<Element> {
        let b = Set(base)
        let l = Set(local)
        let r = Set(remote)
        let all = b.union(l).union(r)
        return Set(all.filter { value in
            let bv = b.contains(value)
            let lv = l.contains(value)
            let rv = r.contains(value)
            if lv == rv { return lv }
            if lv == bv { return rv }
            if rv == bv { return lv }
            return canonicalChoice(lv, rv) ?? lv
        })
    }

    private static func mergeOptionalOrder<Element: Hashable & Encodable>(
        base: [Element]?, local: [Element]?, remote: [Element]?, allowed: Set<Element>
    ) -> [Element]? {
        if local == remote { return local.map { $0.filter { allowed.contains($0) }.uniqued() } }
        if local == base { return remote.map { $0.filter { allowed.contains($0) }.uniqued() } }
        if remote == base { return local.map { $0.filter { allowed.contains($0) }.uniqued() } }
        if let local, let remote {
            return mergeOrder(base: base ?? [], local: local, remote: remote, allowed: allowed)
        }
        return canonicalChoice(local, remote).map { $0.filter { allowed.contains($0) }.uniqued() }
    }

    /// Three-way sequence merge: pairwise order follows the side that changed
    /// it relative to base; independent insertions from both sides are retained.
    private static func mergeOrder<Element: Hashable & Encodable>(
        base: [Element], local: [Element], remote: [Element], allowed: Set<Element>
    ) -> [Element] {
        let b = base.filter { allowed.contains($0) }.uniqued()
        let l = local.filter { allowed.contains($0) }.uniqued()
        let r = remote.filter { allowed.contains($0) }.uniqued()
        let elements = allowed.sorted { stableLessThan($0, $1) }
        guard elements.count > 1 else { return elements }

        var outgoing: [Element: Set<Element>] = [:]
        var indegree = Dictionary(uniqueKeysWithValues: elements.map { ($0, 0) })
        for leftIndex in elements.indices {
            for rightIndex in elements.indices where rightIndex > leftIndex {
                let left = elements[leftIndex]
                let right = elements[rightIndex]
                let lp = precedes(left, right, in: l)
                let rp = precedes(left, right, in: r)
                let bp = precedes(left, right, in: b)
                let leftBefore: Bool
                if let lp, let rp {
                    if lp == rp { leftBefore = lp }
                    else if let bp, lp == bp { leftBefore = rp }
                    else if let bp, rp == bp { leftBefore = lp }
                    else { leftBefore = stableLessThan(left, right) }
                } else if let lp { leftBefore = lp }
                else if let rp { leftBefore = rp }
                else if let bp { leftBefore = bp }
                else { leftBefore = stableLessThan(left, right) }
                let from = leftBefore ? left : right
                let to = leftBefore ? right : left
                if outgoing[from, default: []].insert(to).inserted {
                    indegree[to, default: 0] += 1
                }
            }
        }

        var remaining = Set(elements)
        var ordered: [Element] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { indegree[$0, default: 0] == 0 }
            // Conflicting concurrent moves can make pairwise preferences cyclic.
            // Stable encoding breaks only that cycle, keeping results identical
            // on both devices.
            let next = (ready.isEmpty ? remaining : ready).min { stableLessThan($0, $1) }!
            ordered.append(next)
            remaining.remove(next)
            for target in outgoing[next, default: []] where remaining.contains(target) {
                indegree[target, default: 0] -= 1
            }
        }
        return ordered
    }

    private static func precedes<Element: Equatable>(_ lhs: Element, _ rhs: Element, in order: [Element]) -> Bool? {
        guard let l = order.firstIndex(of: lhs), let r = order.firstIndex(of: rhs) else { return nil }
        return l < r
    }

    private static func threeWay<Value: Equatable & Encodable>(
        _ base: Value?, _ local: Value?, _ remote: Value?, fallback: Value? = nil
    ) -> Value? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        return canonicalChoice(local, remote) ?? fallback
    }

    private static func canonicalChoice<Value: Encodable>(_ local: Value?, _ remote: Value?) -> Value? {
        guard let local else { return remote }
        guard let remote else { return local }
        return encoded(local).lexicographicallyPrecedes(encoded(remote)) ? local : remote
    }

    private static func stableLessThan<Value: Encodable>(_ lhs: Value, _ rhs: Value) -> Bool {
        encoded(lhs).lexicographicallyPrecedes(encoded(rhs))
    }

    private static func derivedLedgerLot(symbol: SymbolID, ledger: PositionLedger) -> CostLot {
        CostLot(
            id: derivedLedgerLotID(for: symbol),
            price: ledger.averageCost,
            quantity: ledger.quantity
        )
    }

    /// Ledger lots are a compatibility cache rather than independent data.
    /// Their identity must be the same on every device and merge pass so a
    /// replayed snapshot remains equal to the one that produced it. The local
    /// store derives its cache lot with this too: a trade recorded here and the
    /// same trade arriving from a peer then share one identity instead of
    /// alternating between two, which would write the file once more per edit.
    static func derivedLedgerLotID(for symbol: SymbolID) -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let symbolData = (try? encoder.encode(symbol)) ?? Data("\(symbol.market.rawValue):\(symbol.code)".utf8)
        let digest = SHA256.hash(data: Data("PulseCore.ledger-cache.v1\0".utf8) + symbolData)
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func encoded<Value: Encodable>(_ value: Value) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map(Array.init) ?? []
    }

    private static func normalizedGroupName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func symbolLessThan(_ lhs: SymbolID, _ rhs: SymbolID) -> Bool {
        let l = "\(lhs.market):\(lhs.code)"
        let r = "\(rhs.market):\(rhs.code)"
        return l < r
    }

    private static func replaceTransaction(
        _ replacement: PositionTransaction?,
        id: UUID,
        symbol: SymbolID,
        preservingOrderFrom sources: [[PositionTransaction]],
        in snapshot: inout WatchlistSyncSnapshot
    ) {
        func patch(_ items: inout [WatchItem]) {
            guard let index = items.firstIndex(where: { $0.symbol == symbol }) else { return }
            let existingOrder = items[index].transactions
            items[index].transactions.removeAll { $0.id == id }
            if let replacement { items[index].transactions.append(replacement) }
            items[index].transactions = replay(
                items[index].transactions,
                preservingOrderFrom: [existingOrder] + sources
            )
            let ledger = PositionLedger(transactions: items[index].transactions)
            if items[index].transactions.isEmpty {
                // Conflict resolution applies to a transaction-backed item;
                // a legacy lot-only item cannot be the target of this patch.
                items[index].lots = []
            } else {
                items[index].lots = ledger.hasOpenPosition
                    ? [derivedLedgerLot(symbol: symbol, ledger: ledger)]
                    : []
            }
        }
        patch(&snapshot.items)
        patch(&snapshot.retainedHistoryItems)
    }

    private static func replacePositionAllocation(
        _ allocation: PositionAllocation?,
        for symbol: SymbolID,
        in snapshot: inout WatchlistSyncSnapshot
    ) {
        if let index = snapshot.items.firstIndex(where: { $0.symbol == symbol }) {
            snapshot.items[index].positionAllocation = allocation
        } else if let index = snapshot.retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }) {
            snapshot.retainedHistoryItems[index].positionAllocation = allocation
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
