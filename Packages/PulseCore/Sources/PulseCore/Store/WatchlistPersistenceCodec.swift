import Foundation

/// Local on-disk schema, validation and duplicate normalization. The store owns
/// actual UserDefaults writes and sync hooks; this type only returns values.
enum WatchlistPersistenceCodec {
    struct Snapshot: Codable {
        var items: [WatchItem]
        var groups: [WatchlistGroup]
        var selectedGroupID: UUID?
        /// Optional so snapshots written before removed-history retention still decode.
        var retainedHistoryItems: [WatchItem]?
    }

    struct AccountStored: Codable {
        var version: Int = 1
        var snapshot: WatchlistSyncSnapshot
        var activeAccountID: BrokerageAccountID
        var selectedGroupIDs: [String: UUID]
    }


    static func decodeAccounts(_ data: Data) throws -> AccountStored {
        let stored = try JSONDecoder().decode(AccountStored.self, from: data)
        guard (1...2).contains(stored.version), stored.snapshot.brokerageAccounts != nil else {
            throw TradeMutationError.invalidCandidate
        }
        _ = try WatchlistSyncWireCodec.encode(deviceID: "load-check", snapshot: stored.snapshot)
        return stored
    }

    static func encodeAccounts(_ snapshot: WatchlistSyncSnapshot, activeAccountID: BrokerageAccountID,
                               selectedGroupIDs: [String: UUID]) throws -> Data {
        _ = try WatchlistSyncWireCodec.encode(deviceID: "save-check", snapshot: snapshot)
        return try JSONEncoder().encode(AccountStored(version: snapshot.hasAccountSettings ? 2 : 1,
            snapshot: snapshot, activeAccountID: activeAccountID, selectedGroupIDs: selectedGroupIDs))
    }

    private static func nonemptyText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func shouldAcceptDisplayName(_ candidate: DisplayNameSource, over current: DisplayNameSource?) -> Bool {
        guard let current else { return true }
        return candidate.priority < current.priority
    }

    private static func shouldAcceptInstrumentType(_ candidate: InstrumentType?, over current: InstrumentType?) -> Bool {
        guard let candidate, candidate != .other else { return false }
        return current == nil || current == .other
    }

    static func normalizedItems(_ storedItems: [WatchItem], migrate: (WatchItem) -> WatchItem) -> [WatchItem] {
        var normalizedItems: [WatchItem] = []
        var itemIndexBySymbol: [SymbolID: Int] = [:]
        for var item in storedItems {
            item.instrumentType = WatchItem.normalizedInstrumentType(
                item.instrumentType,
                for: item.symbol
            )
            // Storage, rendering, and the merge all read one order
            // (`TradePlan.ordered`); normalizing on every load keeps a peer's
            // snapshot from looking different purely because of sequence.
            item.plans = TradePlan.ordered(item.plans)
            item.drawings = ChartDrawingMerge.collapsed(item.drawings)
            if let profile = item.tradingProfile, !profile.isValid {
                item.tradingProfile = nil
            } else if var profile = item.tradingProfile {
                profile.sector = nonemptyText(profile.sector)
                item.tradingProfile = profile.sector == nil && profile.stopPrice == nil && profile.targetPrice == nil
                    ? nil
                    : profile
            }
            item.events = InstrumentEventMerge.collapsed(item.events)
            if let existingIndex = itemIndexBySymbol[item.symbol] {
                var existingLotIDs = Set(normalizedItems[existingIndex].lots.map(\.id))
                normalizedItems[existingIndex].lots.append(
                    contentsOf: item.lots.filter { existingLotIDs.insert($0.id).inserted }
                )
                var transactions: [PositionTransaction] = []
                var transactionIndexByID: [UUID: Int] = [:]
                for transaction in normalizedItems[existingIndex].transactions + item.transactions {
                    if let index = transactionIndexByID[transaction.id] {
                        transactions[index] = TradeLedgerMutation.preservingTransactionMetadata(
                            transactions[index],
                            from: transaction
                        )
                    } else {
                        transactionIndexByID[transaction.id] = transactions.count
                        transactions.append(transaction)
                    }
                }
                normalizedItems[existingIndex].transactions = PositionLedger.replayOrdered(transactions)
                normalizedItems[existingIndex].addedAt = min(
                    normalizedItems[existingIndex].addedAt,
                    item.addedAt
                )
                if let source = item.displayNameSource,
                   shouldAcceptDisplayName(
                       source,
                       over: normalizedItems[existingIndex].displayNameSource
                   ) {
                    normalizedItems[existingIndex].displayName = item.displayName
                    normalizedItems[existingIndex].displayNameSource = source
                }
                if shouldAcceptInstrumentType(
                    item.instrumentType,
                    over: normalizedItems[existingIndex].instrumentType
                ) {
                    normalizedItems[existingIndex].instrumentType = item.instrumentType
                }
                // A thesis only exists because someone typed it, so a merged
                // duplicate keeps the longer one instead of discarding work.
                if let incoming = item.thesis,
                   incoming.count > (normalizedItems[existingIndex].thesis?.count ?? 0) {
                    normalizedItems[existingIndex].thesis = incoming
                }
                if let incoming = item.tradingProfile {
                    let existing = normalizedItems[existingIndex].tradingProfile
                    normalizedItems[existingIndex].tradingProfile = TradingProfile(
                        sector: existing?.sector ?? incoming.sector,
                        stopPrice: existing?.stopPrice ?? incoming.stopPrice,
                        targetPrice: existing?.targetPrice ?? incoming.targetPrice
                    )
                }
                normalizedItems[existingIndex].events = InstrumentEventMerge.merge(
                    base: [],
                    local: normalizedItems[existingIndex].events,
                    remote: item.events
                )
                if normalizedItems[existingIndex].positionAllocation == nil {
                    normalizedItems[existingIndex].positionAllocation = item.positionAllocation
                } else if let incoming = item.positionAllocation,
                          normalizedItems[existingIndex].positionAllocation != incoming,
                          var selected = normalizedItems[existingIndex].positionAllocation {
                    // Duplicate canonical symbols have no safe field-wise pool
                    // merge. This holds even when both copies carry brokerage
                    // account labels: two cards for one symbol in two accounts
                    // are exactly the case a concatenation would fabricate, so
                    // the deliberate fingerprint break forces reconciliation
                    // rather than inventing an attribution.
                    let fingerprint = PositionAllocation.basisFingerprint(for: normalizedItems[existingIndex])
                    selected.basisFingerprint = fingerprint == String(repeating: "0", count: 64)
                        ? String(repeating: "1", count: 64)
                        : String(repeating: "0", count: 64)
                    normalizedItems[existingIndex].positionAllocation = selected
                }
                // Plans carry stable ids, so duplicates from two spellings of
                // the same symbol union by id rather than picking a winner.
                var existingPlanIDs = Set(normalizedItems[existingIndex].plans.map(\.id))
                normalizedItems[existingIndex].plans = TradePlan.ordered(
                    normalizedItems[existingIndex].plans + item.plans.filter {
                        existingPlanIDs.insert($0.id).inserted
                    }
                )
                normalizedItems[existingIndex].drawings = ChartDrawingMerge.merge(
                    base: [],
                    local: normalizedItems[existingIndex].drawings,
                    remote: item.drawings
                )
            } else {
                itemIndexBySymbol[item.symbol] = normalizedItems.count
                normalizedItems.append(item)
            }
        }
        // The retired observation purpose is migrated only now, after duplicate
        // canonical symbols have been collapsed into one entry. Migrating inside
        // the loop would run it twice for a duplicate pair — appending a second
        // audit change and, worse, a second revision to the same plan — and the
        // surviving copy would depend on which spelling happened to be last.
        return normalizedItems.map(migrate)
    }

}
