import Foundation

public extension PositionAllocation {
    /// Checks one card so an unrelated trade correction cannot erase its source.
    func hasMatchingSource(for portion: PositionPortion, item: WatchItem) -> Bool {
        Self.matchingSource(for: portion, entries: PositionLedger(transactions: item.transactions).entries)
    }

    /// A read-only recovery using the latest buy identity recorded for this exact
    /// card. Equal quantities, prices, dates, and account labels are not identities.
    func resolvedBuyOrigins(for item: WatchItem) -> [UUID: PositionPortion.Origin] {
        guard isValid else { return [:] }
        let entries = PositionLedger(transactions: item.transactions).entries
        var resolved: [UUID: PositionPortion.Origin] = [:]
        var recoveredCards = Set<UUID>()
        for portion in portions {
            let source: PositionPortion.Origin?
            switch portion.origin.kind {
            case .buy: source = portion.origin
            case .snapshot:
                source = changes.reversed().lazy.compactMap { change in
                    [change.resultingPortions, change.previousPortions].lazy.compactMap {
                        $0.first { $0.id == portion.id && $0.origin.kind == .buy }?.origin
                    }.first
                }.first
            }
            guard let source, Self.exactBuyOrigin(source, entries: entries) else { continue }
            resolved[portion.id] = source
            if portion.origin.kind == .snapshot { recoveredCards.insert(portion.id) }
        }
        let recoveredTransactions = Set(recoveredCards.compactMap { resolved[$0]?.transactionID })
        for id in recoveredTransactions {
            guard let limit = entries.first(where: { $0.id == id })?.transaction.quantity else { continue }
            let claimed = portions.filter { resolved[$0.id]?.transactionID == id }.reduce(0.0) { $0 + $1.quantity }
            if !claimed.isFinite || claimed - limit > Self.quantityTolerance(claimed, limit) {
                for portionID in recoveredCards where resolved[portionID]?.transactionID == id {
                    resolved.removeValue(forKey: portionID)
                }
            }
        }
        return resolved
    }

    /// Only buys in this ledger with enough unclaimed shares can be selected.
    /// Buys before a calibration or a fully closed position are excluded.
    func availableBuySources(for portionID: UUID, item: WatchItem) -> [PositionTransaction] {
        guard isValid, let portion = portions.first(where: { $0.id == portionID }) else { return [] }
        let entries = PositionLedger(transactions: item.transactions).entries
        let resolved = resolvedBuyOrigins(for: item)
        let claimed = portions.reduce(into: [UUID: Double]()) { totals, other in
            guard other.id != portionID, let id = resolved[other.id]?.transactionID else { return }
            totals[id, default: 0] += other.quantity
        }
        return entries.reversed().compactMap { entry in
            let transaction = entry.transaction
            let origin = PositionPortion.Origin(kind: .buy, transactionID: transaction.id,
                date: transaction.date, price: transaction.price, quantity: transaction.quantity)
            guard Self.exactBuyOrigin(origin, entries: entries) else { return nil }
            let used = claimed[transaction.id] ?? 0
            guard used.isFinite, transaction.quantity - used + Self.quantityTolerance(transaction.quantity, used, portion.quantity) >= portion.quantity else { return nil }
            return transaction
        }
    }

    // Shared with the allocation's global source validation.
    internal static func matchingSource(for portion: PositionPortion, entries: [PositionLedger.Entry]) -> Bool {
        switch portion.origin.kind {
        case .snapshot:
            guard portion.origin.transactionID == nil, portion.origin.price == nil,
                  portion.origin.quantity == nil else { return false }
            guard let date = portion.origin.date else { return true }
            return date.timeIntervalSince1970.isFinite && !entries.contains {
                $0.transaction.kind == .adjustment && $0.transaction.createdAt > date
            }
        case .buy: return exactBuyOrigin(portion.origin, entries: entries)
        }
    }

    private static func exactBuyOrigin(_ origin: PositionPortion.Origin, entries: [PositionLedger.Entry]) -> Bool {
        guard origin.kind == .buy, let id = origin.transactionID,
              let date = origin.date, date.timeIntervalSince1970.isFinite,
              let price = origin.price, price.isFinite, price >= 0,
              let quantity = origin.quantity, quantity.isFinite, quantity > 0,
              let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let transaction = entries[index].transaction
        guard transaction.kind == .buy, transaction.price == price,
              transaction.quantity == quantity, transaction.date == date,
              index == 0 || entries[index - 1].resultingQuantity >= 0 else { return false }
        return !entries.dropFirst(index + 1).contains {
            $0.transaction.kind == .adjustment || $0.resultingQuantity <= 0
        }
    }
}
