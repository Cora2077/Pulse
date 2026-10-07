import CryptoKit
import Foundation
import Observation

/// Watchlist instruments plus named tag membership, backed by UserDefaults.
/// Instruments and positions are stored once even when they appear in several groups.
/// Trade history for removed instruments is retained separately until the symbol is added again.
@MainActor
@Observable
public final class WatchlistStore {
    public private(set) var allItems: [WatchItem] = []
    public private(set) var groups: [WatchlistGroup] = []
    public private(set) var selectedGroupID: UUID?
    public private(set) var activeBrokerageAccountID: BrokerageAccountID = .unassigned
    public private(set) var brokerageAccountsEnabled = false
    public private(set) var hasUnreadableBrokerageData = false
    private var accountPortfolios: [BrokerageAccountID: BrokerageAccountPortfolio] = [:]
    private var currentAccountSettings: BrokerageAccountSettings?
    @ObservationIgnored private var accountGroupSelections: [String: UUID] = [:]
    @ObservationIgnored private let accountStorageKey = "pulse.watchlists.v4"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "pulse.watchlists.v3"
    @ObservationIgnored private let previousStorageKey = "pulse.watchlists.v2"
    @ObservationIgnored private let legacyStorageKey = "pulse.watchlist.v1"
    @ObservationIgnored private let legacyManualOrderKey = "pulse.watchlist.manualOrder.v1"
    @ObservationIgnored private let initialGroupName: String
    private var retainedHistoryItems: [WatchItem] = []

    /// Called after a local persistence change that affects synchronized data.
    /// Initial loading, local selection changes, and remote snapshot application
    /// do not invoke this hook.
    @ObservationIgnored public var onLocalSyncChange: ((WatchlistSyncSnapshot) -> Void)?

    public init(defaults: UserDefaults = .standard, defaultGroupName: String? = nil) {
        self.defaults = defaults
        self.initialGroupName = defaultGroupName ?? Self.localizedDefaultGroupName
        load()
    }

    // MARK: - Brokerage accounts

    @discardableResult
    public func enableBrokerageAccounts() -> Bool {
        guard !brokerageAccountsEnabled, !hasUnreadableBrokerageData else { return false }
        brokerageAccountsEnabled = true
        accountPortfolios[.unassigned] = currentPortfolio()
        for id in BrokerageAccountID.allCases where id != .unassigned {
            accountPortfolios[id] = emptyPortfolio(id)
        }
        save()
        return true
    }

    public func brokeragePortfolio(for id: BrokerageAccountID) -> BrokerageAccountPortfolio {
        id == activeBrokerageAccountID ? currentPortfolio() : accountPortfolios[id]
            ?? BrokerageAccountPortfolio(accountID: id)
    }

    public func isBrokerageAccountEmpty(_ id: BrokerageAccountID) -> Bool {
        let value = brokeragePortfolio(for: id)
        return value.items.isEmpty && value.retainedHistoryItems.isEmpty
    }

    public func brokerageSettings(for id: BrokerageAccountID) -> BrokerageAccountSettings? {
        brokeragePortfolio(for: id).settings
    }

    @discardableResult
    public func setBrokerageSettings(_ settings: BrokerageAccountSettings, for id: BrokerageAccountID) -> Bool {
        guard brokerageAccountsEnabled, settings.isValid else { return false }
        guard brokerageSettings(for: id) != settings else { return true }
        if id == activeBrokerageAccountID { currentAccountSettings = settings }
        else {
            guard var portfolio = accountPortfolios[id] else { return false }
            portfolio.settings = settings
            accountPortfolios[id] = portfolio
        }
        save()
        return true
    }

    @discardableResult
    public func selectBrokerageAccount(_ id: BrokerageAccountID) -> Bool {
        guard brokerageAccountsEnabled, id != activeBrokerageAccountID else { return false }
        checkpointAccount()
        adoptAccount(id)
        save(syncRelevant: false)
        return true
    }

    /// Synchronous scopes cannot suspend into another UI operation. Restore the
    /// latest previous portfolio: the operation may have classified data into it.
    public func withBrokerageAccount<T>(_ id: BrokerageAccountID, _ operation: () throws -> T) rethrows -> T {
        precondition(brokerageAccountsEnabled || id == .unassigned)
        guard id != activeBrokerageAccountID else { return try operation() }
        let previous = activeBrokerageAccountID
        let before = syncSnapshot()
        checkpointAccount()
        adoptAccount(id)
        defer {
            let changed = syncSnapshot() != before
            checkpointAccount()
            adoptAccount(previous)
            if changed { save(syncRelevant: false) }
        }
        return try operation()
    }

    private func currentPortfolio() -> BrokerageAccountPortfolio {
        .init(accountID: activeBrokerageAccountID, items: allItems, groups: groups,
              retainedHistoryItems: retainedHistoryItems, settings: currentAccountSettings)
    }

    private func emptyPortfolio(_ id: BrokerageAccountID) -> BrokerageAccountPortfolio {
        .init(accountID: id, groups: [WatchlistGroup(name: initialGroupName)])
    }

    private func checkpointAccount() {
        guard brokerageAccountsEnabled else { return }
        accountPortfolios[activeBrokerageAccountID] = currentPortfolio()
        accountGroupSelections[activeBrokerageAccountID.rawValue] = selectedGroupID
    }

    private func adoptAccount(_ id: BrokerageAccountID) {
        guard let portfolio = accountPortfolios[id] else { return }
        activeBrokerageAccountID = id
        allItems = portfolio.items
        groups = portfolio.groups
        retainedHistoryItems = portfolio.retainedHistoryItems
        currentAccountSettings = portfolio.settings
        let selected = accountGroupSelections[id.rawValue]
        selectedGroupID = groups.contains { $0.id == selected } ? selected : groups.first?.id
    }

    private func installAccountSnapshot(_ snapshot: WatchlistSyncSnapshot, selecting id: BrokerageAccountID) {
        var portfolios = Dictionary(uniqueKeysWithValues: (snapshot.brokerageAccounts ?? []).map { ($0.accountID, $0) })
        portfolios[.unassigned] = .init(accountID: .unassigned, items: snapshot.items, groups: snapshot.groups,
                                     retainedHistoryItems: snapshot.retainedHistoryItems, settings: snapshot.accountSettings)
        for account in BrokerageAccountID.allCases {
            let value = portfolios[account] ?? emptyPortfolio(account)
            activeBrokerageAccountID = account
            allItems = value.items; groups = value.groups; retainedHistoryItems = value.retainedHistoryItems
            currentAccountSettings = value.settings
            normalizeLoadedState()
            portfolios[account] = currentPortfolio()
        }
        accountPortfolios = portfolios
        brokerageAccountsEnabled = true
        adoptAccount(id)
    }

    /// Ownership classification, never a broker transfer. Whole ledgers retain
    /// every original annotation; selected trades retain their immutable payload.
    @discardableResult
    public func assignBrokerageRecords(for symbol: SymbolID, transactionIDs: Set<UUID>?,
                                       to destination: BrokerageAccountID) -> Bool {
        guard brokerageAccountsEnabled, activeBrokerageAccountID == .unassigned,
              destination != .unassigned,
              let source = item(for: symbol) ?? retainedHistoryItem(for: symbol),
              var target = accountPortfolios[destination] else { return false }
        let existing = (target.items + target.retainedHistoryItems).first { $0.symbol == symbol }
        var moved: WatchItem
        var remainder: WatchItem?
        if let ids = transactionIDs {
            if let existing,
               existing.thesis != nil || !existing.plans.isEmpty || !existing.events.isEmpty
                || existing.tradingProfile != nil || !existing.drawings.isEmpty { return false }
            let trades = source.materializedTransactions()
            guard !ids.isEmpty, ids.isSubset(of: Set(trades.map(\.id))),
                  !source.positionAllocationNeedsReconciliation else { return false }
            let selected = trades.filter { ids.contains($0.id) }
            let staying = trades.filter { !ids.contains($0.id) }
            let prior = existing?.materializedTransactions() ?? []
            guard Set(prior.map(\.id)).isDisjoint(with: ids) else { return false }
            var sourceAfter = Self.applyingTransactions(staying, to: source)
            // An empty trade array must also clear the legacy lot cache.
            if staying.isEmpty { sourceAfter.lots = [] }
            let template = existing ?? WatchItem(symbol: symbol, displayName: source.displayName,
                displayNameSource: source.displayNameSource, instrumentType: source.instrumentType, addedAt: source.addedAt)
            moved = Self.applyingTransactions(prior + selected, to: template)
            let sourceLedger = PositionLedger(transactions: trades)
            let targetLedger = PositionLedger(transactions: prior)
            let afterSource = PositionLedger(transactions: staying)
            let afterTarget = PositionLedger(transactions: prior + selected)
            guard Self.validAccountLedger(afterSource), Self.validAccountLedger(afterTarget),
                  abs(afterSource.quantity + afterTarget.quantity - sourceLedger.quantity - targetLedger.quantity)
                    <= PositionAllocation.quantityTolerance(afterSource.quantity + afterTarget.quantity,
                                                           sourceLedger.quantity + targetLedger.quantity),
                  sourceLedger.entries.contains(where: { $0.resultingQuantity < 0 })
                    || afterSource.entries.allSatisfy({ $0.resultingQuantity >= 0 }),
                  targetLedger.entries.contains(where: { $0.resultingQuantity < 0 })
                    || afterTarget.entries.allSatisfy({ $0.resultingQuantity >= 0 }) else { return false }
            // When buy-origin cards exactly cover the split, move those actual
            // cards. Otherwise the existing reconciliation guards stay in force.
            if let allocation = source.positionAllocation {
                let movingCards = allocation.portions.filter { $0.origin.transactionID.map(ids.contains) == true }
                let stayingCards = allocation.portions.filter { $0.origin.transactionID.map(ids.contains) != true }
                let targetCards = (existing?.positionAllocation?.portions ?? []) + movingCards
                if !movingCards.isEmpty,
                   abs(stayingCards.reduce(0) { $0 + $1.quantity } - afterSource.quantity)
                       <= PositionAllocation.quantityTolerance(afterSource.quantity, 0),
                   abs(targetCards.reduce(0) { $0 + $1.quantity } - afterTarget.quantity)
                       <= PositionAllocation.quantityTolerance(afterTarget.quantity, 0) {
                    sourceAfter.positionAllocation = changedAllocation(allocation, portions: stayingCards,
                        item: sourceAfter, kind: .reconcile, reason: "Account ownership classified")
                    let oldTarget = existing?.positionAllocation ?? PositionAllocation(
                        basisFingerprint: PositionAllocation.basisFingerprint(for: moved), portions: [])
                    moved.positionAllocation = changedAllocation(oldTarget, portions: targetCards,
                        item: moved, kind: .reconcile, reason: "Account ownership classified")
                }
            }
            if moved.positionAllocation == nil { _ = initializePositionAllocation(&moved) }
            remainder = sourceAfter
        } else {
            if let existing,
               existing.hasPositionHistory || existing.thesis != nil || !existing.plans.isEmpty
                || !existing.events.isEmpty || existing.tradingProfile != nil
                || existing.positionAllocation != nil || !existing.drawings.isEmpty { return false }
            moved = source
        }
        target.retainedHistoryItems.removeAll { $0.symbol == symbol }
        target.items.removeAll { $0.symbol == symbol }
        // Make assigned holdings visible, including a previously dormant ledger.
        target.items.append(moved)
        let sourceGroupName = groups.first { $0.symbols.contains(symbol) }?.name ?? initialGroupName
        if let index = target.groups.firstIndex(where: { $0.name == sourceGroupName }) {
            if !target.groups[index].symbols.contains(symbol) { target.groups[index].symbols.append(symbol) }
        } else { target.groups.append(WatchlistGroup(name: sourceGroupName, symbols: [symbol])) }
        var sourcePortfolio = currentPortfolio()
        if let remainder {
            if let index = sourcePortfolio.items.firstIndex(where: { $0.symbol == symbol }) {
                sourcePortfolio.items[index] = remainder
            } else if let index = sourcePortfolio.retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }) {
                sourcePortfolio.retainedHistoryItems[index] = remainder
            }
        } else {
            sourcePortfolio.items.removeAll { $0.symbol == symbol }
            sourcePortfolio.retainedHistoryItems.removeAll { $0.symbol == symbol }
            for index in sourcePortfolio.groups.indices {
                sourcePortfolio.groups[index].symbols.removeAll { $0 == symbol }
                sourcePortfolio.groups[index].pinnedSymbols.removeAll { $0 == symbol }
                sourcePortfolio.groups[index].manualOrder?.removeAll { $0 == symbol }
            }
        }
        var proposed = syncSnapshot()
        proposed.items = sourcePortfolio.items; proposed.groups = sourcePortfolio.groups
        proposed.retainedHistoryItems = sourcePortfolio.retainedHistoryItems
        proposed.brokerageAccounts = BrokerageAccountID.allCases.filter { $0 != .unassigned }.compactMap {
            $0 == destination ? target : accountPortfolios[$0]
        }
        guard (try? WatchlistSyncWireCodec.encode(deviceID: "classification-check", snapshot: proposed)) != nil,
              (try? LocalBackupStore.validateSnapshot(proposed)) != nil else { return false }
        accountPortfolios[destination] = target
        accountPortfolios[.unassigned] = sourcePortfolio
        adoptAccount(.unassigned)
        save()
        return true
    }

    private static func validAccountLedger(_ ledger: PositionLedger) -> Bool {
        [ledger.quantity, ledger.averageCost, ledger.costBasis, ledger.realizedPnL, ledger.totalFees, ledger.dilutedCost]
            .allSatisfy(\.isFinite)
            && ledger.entries.allSatisfy { $0.resultingQuantity.isFinite && $0.resultingAverageCost.isFinite }
    }

    /// Items in the selected group, in that group's current presentation order.
    public var items: [WatchItem] {
        guard let group = selectedGroup else { return [] }
        let bySymbol = Dictionary(uniqueKeysWithValues: allItems.map { ($0.symbol, $0) })
        return group.symbols.compactMap { bySymbol[$0] }
    }

    /// Every followed instrument, de-duplicated across groups. Refresh and streaming use this union.
    public var symbols: [SymbolID] { allItems.map(\.symbol) }

    /// Market data is shared: keep inactive accounts' holdings and open plans
    /// refreshed as well, without changing the currently selected ledger.
    public var quoteSymbols: [SymbolID] {
        guard brokerageAccountsEnabled else { return symbols }
        var seen: Set<SymbolID> = []
        return BrokerageAccountID.allCases.flatMap { account in
            let portfolio = brokeragePortfolio(for: account)
            return portfolio.items + portfolio.retainedHistoryItems.filter {
                $0.hasPosition || $0.plans.contains { $0.status == .active }
            }
        }.map(\.symbol).filter { seen.insert($0).inserted }
    }

    /// Every item with transaction history, including symbols removed from all
    /// watchlist groups but kept for their ledger.
    public var tradeHistoryItems: [WatchItem] {
        (allItems + retainedHistoryItems).filter { !$0.transactions.isEmpty }
    }

    public var isEmpty: Bool { allItems.isEmpty }

    public var selectedGroup: WatchlistGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    public func items(in groupID: UUID?) -> [WatchItem] {
        guard let group = group(for: groupID) else { return [] }
        let bySymbol = Dictionary(uniqueKeysWithValues: allItems.map { ($0.symbol, $0) })
        return group.symbols.compactMap { bySymbol[$0] }
    }

    public func group(for id: UUID?) -> WatchlistGroup? {
        guard let id else { return groups.first }
        return groups.first { $0.id == id }
    }

    public func selectGroup(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }), selectedGroupID != id else { return }
        selectedGroupID = id
        save(syncRelevant: false)
    }

    /// Reorders a tag relative to another tag while preserving the selected tag and memberships.
    /// Moving right places the source after the destination; moving left places it before.
    public func moveGroup(_ sourceID: UUID, relativeTo destinationID: UUID) {
        guard sourceID != destinationID,
              let sourceIndex = groups.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = groups.firstIndex(where: { $0.id == destinationID }) else { return }

        let moving = groups.remove(at: sourceIndex)
        guard let updatedDestinationIndex = groups.firstIndex(where: { $0.id == destinationID }) else { return }
        let insertionIndex = sourceIndex < destinationIndex
            ? updatedDestinationIndex + 1
            : updatedDestinationIndex
        groups.insert(moving, at: insertionIndex)
        save()
    }

    /// Replaces tag-bar order. `orderedIDs` must be a permutation of the current group ids;
    /// selection and memberships are unchanged.
    @discardableResult
    public func reorderGroups(_ orderedIDs: [UUID]) -> Bool {
        let currentIDs = groups.map(\.id)
        guard orderedIDs.count == currentIDs.count,
              Set(orderedIDs) == Set(currentIDs),
              orderedIDs.uniqued().count == orderedIDs.count else {
            return false
        }
        guard orderedIDs != currentIDs else { return true }
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        groups = orderedIDs.compactMap { byID[$0] }
        save()
        return true
    }

    @discardableResult
    public func createGroup(named rawName: String) -> UUID? {
        let name = normalizedName(rawName)
        guard !name.isEmpty, !hasGroup(named: name) else { return nil }
        let group = WatchlistGroup(name: name)
        groups.append(group)
        selectedGroupID = group.id
        save()
        return group.id
    }

    @discardableResult
    public func renameGroup(_ id: UUID, to rawName: String) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        let name = normalizedName(rawName)
        guard !name.isEmpty, !hasGroup(named: name, excluding: id) else { return false }
        groups[index].name = name
        save()
        return true
    }

    /// Deletes only the tag. Instruments that would otherwise become orphaned move to a remaining group.
    @discardableResult
    public func deleteGroup(_ id: UUID) -> Bool {
        guard groups.count > 1, let removedIndex = groups.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let removed = groups.remove(at: removedIndex)
        let fallbackIndex = groups.firstIndex(where: { $0.id == selectedGroupID }) ?? 0
        let stillAssigned = Set(groups.flatMap(\.symbols))
        let orphaned = removed.symbols.filter { !stillAssigned.contains($0) }
        for symbol in orphaned where !groups[fallbackIndex].symbols.contains(symbol) {
            groups[fallbackIndex].symbols.append(symbol)
            if groups[fallbackIndex].manualOrder != nil {
                groups[fallbackIndex].manualOrder?.append(symbol)
            }
        }
        if selectedGroupID == id || group(for: selectedGroupID) == nil {
            selectedGroupID = groups[fallbackIndex].id
        }
        save()
        return true
    }

    public func contains(_ symbol: SymbolID, in groupID: UUID? = nil) -> Bool {
        group(for: groupID ?? selectedGroupID)?.symbols.contains(symbol) == true
    }

    public func item(for symbol: SymbolID) -> WatchItem? {
        allItems.first { $0.symbol == symbol }
    }

    /// Read-only access to dormant instrument history. `materializeItem(_:)`
    /// restores the item without adding it to a list; chart drawing mutations
    /// can also update this retained record in place.
    public func retainedHistoryItem(for symbol: SymbolID) -> WatchItem? {
        retainedHistoryItems.first { $0.symbol == symbol }
    }

    /// Adds to the selected group by default. An existing instrument only gains another tag.
    public func add(_ info: SymbolInfo, to groupID: UUID? = nil) {
        guard let targetID = group(for: groupID ?? selectedGroupID)?.id,
              let groupIndex = groups.firstIndex(where: { $0.id == targetID }) else { return }
        materializedItem(for: info)
        if !groups[groupIndex].symbols.contains(info.symbol) {
            insertAtTopOfUnpinned(info.symbol, inGroupAt: groupIndex)
        }
        save()
    }

    /// Ensures an item exists for the instrument without adding it to any group:
    /// dormant trade history is restored, and a never-seen instrument gets a
    /// fresh item. Groupless items keep their position ledger and quotes
    /// reachable from the detail page while staying out of every list.
    @discardableResult
    public func materializeItem(_ info: SymbolInfo) -> WatchItem {
        let item = materializedItem(for: info)
        save()
        return item
    }

    @discardableResult
    private func materializedItem(for info: SymbolInfo) -> WatchItem {
        restoreRetainedHistory(for: info.symbol)
        if let itemIndex = allItems.firstIndex(where: { $0.symbol == info.symbol }) {
            if let source = info.displayNameSource,
               shouldAcceptDisplayName(source, over: allItems[itemIndex].displayNameSource) {
                allItems[itemIndex].displayName = info.resolvedDisplayName
                allItems[itemIndex].displayNameSource = source
            }
            let candidateType = WatchItem.normalizedInstrumentType(info.type, for: info.symbol)
            if shouldAcceptInstrumentType(
                candidateType,
                over: allItems[itemIndex].instrumentType
            ) {
                allItems[itemIndex].instrumentType = candidateType
            }
            return allItems[itemIndex]
        }
        let item = WatchItem(
            symbol: info.symbol,
            displayName: info.resolvedDisplayName,
            displayNameSource: info.displayNameSource,
            instrumentType: info.type
        )
        allItems.append(item)
        return item
    }

    public func setMembership(_ symbol: SymbolID, in groupID: UUID, included: Bool) {
        guard item(for: symbol) != nil,
              let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if included {
            guard !groups[groupIndex].symbols.contains(symbol) else { return }
            insertAtTopOfUnpinned(symbol, inGroupAt: groupIndex)
        } else {
            guard groups[groupIndex].symbols.contains(symbol) else { return }
            groups[groupIndex].symbols.removeAll { $0 == symbol }
            groups[groupIndex].manualOrder?.removeAll { $0 == symbol }
            groups[groupIndex].pinnedSymbols.removeAll { $0 == symbol }
            if !groups.contains(where: { $0.symbols.contains(symbol) }) {
                if let itemIndex = allItems.firstIndex(where: { $0.symbol == symbol }) {
                    retainHistoryIfNeeded(from: allItems.remove(at: itemIndex))
                }
            }
        }
        save()
    }

    /// Removes an instrument from the selected group. The active item survives in another tag;
    /// after the final removal, its position and drawing history remain dormant until re-added.
    public func remove(_ symbol: SymbolID) {
        guard let id = selectedGroup?.id else { return }
        setMembership(symbol, in: id, included: false)
    }


    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let current = selectedGroup?.symbols else { return }
        let validOffsets = source.filter { current.indices.contains($0) }
        let moving = validOffsets.sorted().map { current[$0] }
        guard !moving.isEmpty else { return }
        let adjusted = destination - validOffsets.filter { $0 < destination }.count
        var orderedSymbols = current
        orderedSymbols.removeAll { moving.contains($0) }
        orderedSymbols.insert(
            contentsOf: moving,
            at: min(max(adjusted, 0), orderedSymbols.count)
        )
        _ = commitManualMove(orderedSymbols: orderedSymbols, movingSymbols: moving)
    }

    /// Atomically commits the final order produced by SwiftUI's native collection move.
    /// Crossing the pinned boundary changes pin membership so the native drop location
    /// and the persisted presentation remain identical.
    @discardableResult
    public func commitManualMove(
        orderedSymbols: [SymbolID],
        movingSymbols: [SymbolID]
    ) -> Bool {
        guard let id = selectedGroup?.id,
              let groupIndex = groups.firstIndex(where: { $0.id == id }) else { return false }

        let currentGroup = groups[groupIndex]
        let currentSet = Set(currentGroup.symbols)
        guard orderedSymbols.count == currentGroup.symbols.count,
              Set(orderedSymbols) == currentSet else { return false }

        let moving = movingSymbols.filter { currentSet.contains($0) }.uniqued()
        let movingSet = Set(moving)
        guard !moving.isEmpty,
              let insertionIndex = orderedSymbols.firstIndex(where: { movingSet.contains($0) }) else {
            return false
        }

        let originalPinned = Set(currentGroup.pinnedSymbols)
        let movingPinnedCount = moving.reduce(into: 0) { count, symbol in
            if originalPinned.contains(symbol) { count += 1 }
        }
        // SwiftUI List currently moves one contiguous selection. Refuse a mixed
        // pinned/unpinned batch rather than committing an invalid interleaved section.
        guard movingPinnedCount == 0 || movingPinnedCount == moving.count else { return false }

        let remainingPinnedCount = originalPinned.count - movingPinnedCount
        var updatedPinned = originalPinned
        if movingPinnedCount == moving.count {
            if insertionIndex > remainingPinnedCount {
                updatedPinned.subtract(movingSet)
            }
        } else if insertionIndex < remainingPinnedCount {
            updatedPinned.formUnion(movingSet)
        }

        var updatedGroup = currentGroup
        updatedGroup.symbols = orderedSymbols
        updatedGroup.pinnedSymbols = orderedSymbols.filter { updatedPinned.contains($0) }
        updatedGroup.manualOrder = manualOrderPreservingPinnedPositions(
            visibleOrder: orderedSymbols,
            pinned: updatedPinned,
            storedOrder: currentGroup.manualOrder
        )
        groups[groupIndex] = updatedGroup
        save()
        return true
    }

    public func reorder(_ orderedSymbols: [SymbolID]) {
        guard let id = selectedGroup?.id,
              let groupIndex = groups.firstIndex(where: { $0.id == id }) else { return }
        let existing = groups[groupIndex].symbols
        let existingSet = Set(existing)
        let ordered = orderedSymbols.filter { existingSet.contains($0) }.uniqued()
        let orderedSet = Set(ordered)
        groups[groupIndex].symbols = ordered + existing.filter { !orderedSet.contains($0) }
        save()
    }

    /// Sets Custom Order for a specific group without changing the selected tag.
    ///
    /// `orderedSymbols` must be a permutation of the group's members. Pin membership is
    /// preserved; the visible list is coerced to pinned-first using the relative order of
    /// each section from the request. Updates `manualOrder` so restoring Custom Order matches.
    @discardableResult
    public func applyCustomOrder(_ orderedSymbols: [SymbolID], in groupID: UUID) -> Bool {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let currentGroup = groups[groupIndex]
        let ordered = orderedSymbols.uniqued()
        guard ordered.count == currentGroup.symbols.count,
              Set(ordered) == Set(currentGroup.symbols) else {
            return false
        }

        let pinned = Set(currentGroup.pinnedSymbols)
        let pinnedOrdered = ordered.filter { pinned.contains($0) }
        let unpinnedOrdered = ordered.filter { !pinned.contains($0) }
        let visible = pinnedOrdered + unpinnedOrdered

        var updatedGroup = currentGroup
        updatedGroup.symbols = visible
        updatedGroup.pinnedSymbols = pinnedOrdered
        updatedGroup.manualOrder = manualOrderPreservingPinnedPositions(
            visibleOrder: visible,
            pinned: pinned,
            storedOrder: currentGroup.manualOrder
        )
        groups[groupIndex] = updatedGroup
        save()
        return true
    }

    public func isPinned(_ symbol: SymbolID, in groupID: UUID? = nil) -> Bool {
        group(for: groupID ?? selectedGroupID)?.pinnedSymbols.contains(symbol) == true
    }

    /// Updates only pin membership. The caller decides whether the visible list
    /// should be automatically sorted or manually moved to the top.
    @discardableResult
    public func setPinned(_ symbol: SymbolID, in groupID: UUID? = nil, pinned: Bool) -> Bool {
        guard let targetID = group(for: groupID ?? selectedGroupID)?.id,
              let groupIndex = groups.firstIndex(where: { $0.id == targetID }),
              groups[groupIndex].symbols.contains(symbol) else {
            return false
        }

        let wasPinned = groups[groupIndex].pinnedSymbols.contains(symbol)
        guard wasPinned != pinned else { return false }
        if pinned {
            groups[groupIndex].pinnedSymbols.insert(symbol, at: 0)
        } else {
            groups[groupIndex].pinnedSymbols.removeAll { $0 == symbol }
        }
        save()
        return true
    }

    public func rememberManualOrder() {
        guard let id = selectedGroup?.id,
              let groupIndex = groups.firstIndex(where: { $0.id == id }) else { return }
        var updatedGroup = groups[groupIndex]
        let pinned = Set(updatedGroup.pinnedSymbols)
        updatedGroup.manualOrder = manualOrderPreservingPinnedPositions(
            visibleOrder: updatedGroup.symbols,
            pinned: pinned,
            storedOrder: updatedGroup.manualOrder
        )
        updatedGroup.pinnedSymbols = updatedGroup.symbols
            .filter { pinned.contains($0) }
            .uniqued()
        groups[groupIndex] = updatedGroup
        save()
    }

    @discardableResult
    public func restoreManualOrder() -> Bool {
        guard let id = selectedGroup?.id,
              let groupIndex = groups.firstIndex(where: { $0.id == id }),
              let manualOrder = groups[groupIndex].manualOrder,
              !manualOrder.isEmpty else { return false }
        let existing = groups[groupIndex].symbols
        let existingSet = Set(existing)
        let ordered = manualOrder.filter { existingSet.contains($0) }.uniqued()
        let orderedSet = Set(ordered)
        groups[groupIndex].symbols = ordered + existing.filter { !orderedSet.contains($0) }
        save()
        return true
    }

    /// Records the user's own reason for holding this instrument. Free text;
    /// an empty string clears it rather than storing whitespace.
    public func setThesis(_ thesis: String?, for symbol: SymbolID) {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }) else { return }
        let trimmed = thesis?.trimmingCharacters(in: .whitespacesAndNewlines)
        allItems[index].thesis = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    // MARK: - Trade plans

    /// Every plan the user can still act on, in group order.
    ///
    /// Instruments that survive only as dormant history are left out: the
    /// symbol is not in any group any more, so its plan has no list to
    /// trigger against and nothing to open. Membership is walked rather than
    /// `allItems`, and a symbol tagged into two groups contributes once.
    ///
    /// Order is group order followed by each item's own storage order, which is
    /// already `TradePlan.ordered`. The overview re-sorts by price distance on
    /// top of this; that pass is display-only and never written back.
    ///
    /// The symbol lookup is built once rather than calling `item(for:)` per
    /// membership: the home chip recomputes this on every quote tick, and a
    /// linear scan per symbol would make it quadratic in the watchlist size for
    /// no reason. Same shape as `items`.
    public var tradePlanEntries: [TradePlanEntry] {
        let bySymbol = Dictionary(uniqueKeysWithValues: allItems.map { ($0.symbol, $0) })
        var seen = Set<SymbolID>()
        var entries: [TradePlanEntry] = []
        for group in groups {
            for symbol in group.symbols where seen.insert(symbol).inserted {
                guard let item = bySymbol[symbol] else { continue }
                entries.append(contentsOf: item.plans.map {
                    TradePlanEntry(symbol: symbol, plan: $0, transactions: item.transactions)
                })
            }
        }
        return entries
    }

    /// Creates or replaces one plan on an instrument.
    ///
    /// The plan keeps its identity by `id`: an edit preserves the original
    /// `createdAt` and refreshes `updatedAt`, which is what the sync merge reads
    /// when both devices changed the same plan. The caller assembles the plan,
    /// exactly as `addTransaction` takes an assembled transaction.
    ///
    /// An incoming plan still naming the retired observation purpose is
    /// migrated before it is stored: it becomes `unassigned`, gains the pending
    /// review condition, and keeps the retired configuration as a revision so
    /// the intent it used to carry is still readable. This runs on the incoming
    /// value rather than only on the stored one because an older build or a peer
    /// can present a legacy plan at any time, and there is no separate import
    /// path every caller can be trusted to take.
    @discardableResult
    public func setTradePlan(_ plan: TradePlan, for symbol: SymbolID) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }),
              allItems[index].supportsPosition else { return false }

        var plans = allItems[index].plans
        // The stored plan is migrated first, so a legacy record already on disk
        // is repaired whatever the caller sends. `old` is the pre-migration
        // value purely so its configuration can be preserved as a revision.
        let existing = plans.firstIndex { $0.id == plan.id }
        let stored = existing.map { plans[$0] }
        let old = stored.map { Self.migratedPlan($0) }

        var incoming = Self.migratedPlan(plan)
        incoming.note = Self.normalizedPlanNote(plan.note)
        if let conditions = incoming.conditions {
            let normalized = conditions.compactMap { $0.normalized() }
            guard normalized.count == conditions.count,
                  Set(normalized.map(\.id)).count == normalized.count else { return false }
            incoming.conditions = normalized
        }
        guard incoming.hasValidPayload else { return false }

        if let existing, let stored, let old {
            incoming.createdAt = old.createdAt
            incoming.filledTransactionID = incoming.filledTransactionID ?? old.filledTransactionID
            incoming.conditions = incoming.conditions ?? old.conditions
            incoming.history = old.history
            let oldConfiguration = TradePlanConfiguration(plan: old)
            let newConfiguration = TradePlanConfiguration(plan: incoming)
            let configurationChanged = oldConfiguration != newConfiguration
            let legacyLinkChanged = incoming.filledTransactionID != old.filledTransactionID
            // A stored plan the migration just repaired is a real change even
            // when the caller sent the same legacy value back unchanged, so a
            // peer's observation plan cannot sit unmigrated because it happened
            // to compare equal.
            let storedMigrated = stored != old
            guard configurationChanged || legacyLinkChanged || storedMigrated else { return true }
            if configurationChanged {
                incoming.history = (old.history ?? []) + [TradePlanRevision(configuration: oldConfiguration)]
            }
            incoming.updatedAt = .now
            plans[existing] = incoming
        } else {
            incoming.history = plan.positionPool == .observation ? incoming.history.map { Array($0.suffix(1)) } : nil
            incoming.updatedAt = .now
            plans.append(incoming)
        }
        allItems[index].plans = TradePlan.ordered(plans)
        save()
        return true
    }

    @discardableResult
    public func deleteTradePlan(_ id: UUID, for symbol: SymbolID) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }) else { return false }
        let count = allItems[index].plans.count
        allItems[index].plans.removeAll { $0.id == id }
        guard allItems[index].plans.count != count else { return false }
        save()
        return true
    }

    private static func normalizedPlanNote(_ note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    @discardableResult
    public func setTradingProfile(_ profile: TradingProfile?, for symbol: SymbolID) -> Bool {
        if let stopPrice = profile?.stopPrice, (!stopPrice.isFinite || stopPrice <= 0) { return false }
        if let targetPrice = profile?.targetPrice, (!targetPrice.isFinite || targetPrice <= 0) { return false }

        var normalized = profile
        if var value = normalized {
            value.sector = Self.nonemptyText(value.sector)
            normalized = value
        }
        if normalized?.sector == nil, normalized?.stopPrice == nil, normalized?.targetPrice == nil {
            normalized = nil
        }
        if let index = allItems.firstIndex(where: { $0.symbol == symbol }) {
            guard allItems[index].tradingProfile != normalized else { return true }
            allItems[index].tradingProfile = normalized
        } else if let index = retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }) {
            guard retainedHistoryItems[index].tradingProfile != normalized else { return true }
            retainedHistoryItems[index].tradingProfile = normalized
            pruneEmptyRetainedHistory(at: index)
        } else {
            return false
        }
        save()
        return true
    }

    @discardableResult
    public func setInstrumentEvent(_ event: InstrumentEvent, for symbol: SymbolID) -> Bool {
        guard let normalized = event.normalized() else { return false }

        if let index = allItems.firstIndex(where: { $0.symbol == symbol }) {
            guard Self.applyInstrumentEvent(normalized, to: &allItems[index].events) else { return true }
        } else if let index = retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }) {
            guard Self.applyInstrumentEvent(normalized, to: &retainedHistoryItems[index].events) else { return true }
        } else {
            return false
        }
        save()
        return true
    }

    @discardableResult
    public func deleteInstrumentEvent(_ id: UUID, for symbol: SymbolID) -> Bool {
        if let index = allItems.firstIndex(where: { $0.symbol == symbol }) {
            let count = allItems[index].events.count
            allItems[index].events.removeAll { $0.id == id }
            guard allItems[index].events.count != count else { return false }
        } else if let index = retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }) {
            let count = retainedHistoryItems[index].events.count
            retainedHistoryItems[index].events.removeAll { $0.id == id }
            guard retainedHistoryItems[index].events.count != count else { return false }
            pruneEmptyRetainedHistory(at: index)
        } else {
            return false
        }
        save()
        return true
    }

    private static func applyInstrumentEvent(_ event: InstrumentEvent, to events: inout [InstrumentEvent]) -> Bool {
        if let existing = events.first(where: { $0.id == event.id }),
           existing.kind == event.kind, existing.date == event.date,
           existing.title == event.title, existing.sourceURL == event.sourceURL,
           existing.note == event.note {
            return false
        }
        var updated = event
        updated.updatedAt = .now
        events.removeAll { $0.id == event.id }
        events.append(updated)
        events = InstrumentEvent.ordered(events)
        return true
    }

    private func pruneEmptyRetainedHistory(at index: Int) {
        let item = retainedHistoryItems[index]
        if item.materializedTransactions().isEmpty, item.drawings.isEmpty,
           item.tradingProfile == nil, item.events.isEmpty, item.positionAllocation == nil,
           item.thesis == nil, item.plans.isEmpty {
            retainedHistoryItems.remove(at: index)
        }
    }

    // MARK: - Chart drawings

    /// Creates or updates one saved chart drawing. Editing keeps the UUID and
    /// original creation time; a deleted UUID cannot be reused to resurrect it.
    @discardableResult
    public func setChartDrawing(_ drawing: ChartDrawing, for symbol: SymbolID) -> Bool {
        guard drawing.isValid, !drawing.isDeleted else { return false }

        if let index = allItems.firstIndex(where: { $0.symbol == symbol }) {
            guard Self.applyChartDrawing(drawing, to: &allItems[index].drawings, at: .now) else { return false }
            save()
            return true
        }

        guard let index = retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }),
              Self.applyChartDrawing(drawing, to: &retainedHistoryItems[index].drawings, at: .now) else {
            return false
        }
        save()
        return true
    }

    private static func applyChartDrawing(
        _ drawing: ChartDrawing,
        to drawings: inout [ChartDrawing],
        at now: Date
    ) -> Bool {
        guard drawing.isValid, !drawing.isDeleted else { return false }
        var updated = drawing
        if let index = drawings.firstIndex(where: { $0.id == drawing.id }) {
            guard !drawings[index].isDeleted else { return false }
            updated.createdAt = drawings[index].createdAt
        }
        updated.updatedAt = now
        updated.note = normalizedPlanNote(drawing.note)
        guard updated.isValid else { return false }
        drawings.removeAll { $0.id == drawing.id }
        drawings.append(updated)
        drawings = ChartDrawing.ordered(drawings)
        return true
    }

    /// Stores a deletion tombstone under the drawing's UUID for sync convergence.
    @discardableResult
    public func deleteChartDrawing(_ id: UUID, for symbol: SymbolID) -> Bool {
        if let index = allItems.firstIndex(where: { $0.symbol == symbol }),
           let drawingIndex = allItems[index].drawings.firstIndex(where: { $0.id == id }),
           !allItems[index].drawings[drawingIndex].isDeleted {
            allItems[index].drawings[drawingIndex].deletedAt = .now
            allItems[index].drawings[drawingIndex].updatedAt = .now
            save()
            return true
        }
        if let index = retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }),
           let drawingIndex = retainedHistoryItems[index].drawings.firstIndex(where: { $0.id == id }),
           !retainedHistoryItems[index].drawings[drawingIndex].isDeleted {
            retainedHistoryItems[index].drawings[drawingIndex].deletedAt = .now
            retainedHistoryItems[index].drawings[drawingIndex].updatedAt = .now
            save()
            return true
        }
        return false
    }

    public func updateLots(_ symbol: SymbolID, lots: [CostLot]) {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }) else { return }
        // Preserve legacy index data until the user explicitly removes it, but
        // never create or replace a position for a non-tradable index.
        guard allItems[index].supportsPosition || lots.isEmpty else { return }
        allItems[index].lots = lots
        save()
    }

    /// Clears the open position. Items with transaction history keep it —
    /// the ledger records a zero adjustment so realized P&L and the trade log
    /// survive; legacy lot-only items are wiped as before.
    public func clearPosition(_ symbol: SymbolID) {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }) else { return }
        guard !allItems[index].transactions.isEmpty else {
            updateLots(symbol, lots: [])
            return
        }
        calibratePosition(symbol, quantity: 0, averageCost: 0)
    }

    // MARK: - Transactions

    /// Records a user-reported fill and its plan context in one local commit.
    /// Nothing here sends an order or changes a manually entered cash balance.
    ///
    /// `fundingSource` describes the money that actually moved. It is written to
    /// the transaction and, for a buy, to the portion it creates. The plan's own
    /// intended funding is snapshotted separately in `planExecution` and is
    /// never substituted for the reported fill, nor used as a validation gate —
    /// a plan's intent is not a promise and cannot refuse a real trade.
    ///
    /// `salePortionQuantities` names which portion cards a sale consumes. A
    /// sell left without it may only be satisfied automatically when the
    /// candidate shares agree on one funding source; a sale spanning several
    /// sources is refused with `fundingSelectionRequired` rather than quietly
    /// spending one of them.
    @discardableResult
    public func recordTradePlanFill(
        symbol: SymbolID,
        planID: UUID,
        price: Double,
        quantity: Double,
        date: Date,
        fee: Double?,
        note: String?,
        transactionID: UUID = UUID(),
        expectedPlanUpdatedAt: Date? = nil,
        fundingSource: PositionFundingSource? = nil,
        salePortionQuantities: [UUID: Double]? = nil,
        expectedAllocationRevision: UUID? = nil
    ) throws -> PositionTransaction {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }) else {
            throw TradePlanExecutionError.itemNotFound
        }
        var previous = allItems[index]
        guard previous.supportsPosition else { throw TradePlanExecutionError.unsupportedInstrument }
        guard let planIndex = previous.plans.firstIndex(where: { $0.id == planID }) else {
            throw TradePlanExecutionError.planNotFound
        }
        let plan = previous.plans[planIndex]
        guard plan.status == .active, plan.hasValidPayload,
              expectedPlanUpdatedAt.map({ $0 == plan.updatedAt }) ?? true else {
            throw TradePlanExecutionError.stalePlan
        }
        if let expectedAllocationRevision,
           previous.positionAllocation?.revision != expectedAllocationRevision {
            throw TradePlanExecutionError.staleAllocation
        }
        let amount = price * quantity
        guard price.isFinite, price > 0, quantity.isFinite, quantity > 0,
              amount.isFinite, (amount + (fee ?? 0)).isFinite,
              fee.map({ $0.isFinite && $0 >= 0 }) ?? true,
              date.timeIntervalSince1970.isFinite,
              note.map({ $0.count <= 4_000 }) ?? true else {
            throw TradePlanExecutionError.invalidFill
        }
        guard !(allItems + retainedHistoryItems).contains(where: {
            $0.transactions.contains { $0.id == transactionID }
        }) else { throw TradePlanExecutionError.duplicateTransactionID }

        let transaction = PositionTransaction(
            id: transactionID, kind: plan.kind == .buy ? .buy : .sell,
            price: price, quantity: quantity, date: date, fee: fee,
            note: Self.nonemptyText(note),
            planExecution: TradePlanExecution(planID: planID, configuration: TradePlanConfiguration(plan: plan)),
            // The reported fill's funding; the snapshot above keeps the plan's
            // intent. Both are stored because they answer different questions.
            fundingSource: fundingSource
        )
        _ = initializePositionAllocation(&previous)
        var transactions = previous.materializedTransactions()
        transactions.append(transaction)
        let updated = Self.applyingTransactions(transactions, to: previous)
        let ledger = PositionLedger(transactions: updated.transactions)
        guard ledger.quantity.isFinite, ledger.averageCost.isFinite,
              ledger.realizedPnL.isFinite, ledger.totalFees.isFinite,
              ledger.costBasis.isFinite, ledger.dilutedCost.isFinite else {
            throw TradePlanExecutionError.invalidFill
        }

        var soldAllocation: PositionAllocation?
        if plan.kind == .sell {
            // Every check below runs before any state is written, so a refusal
            // leaves the ledger, the allocation, and the plan untouched.
            soldAllocation = try planSaleAllocation(
                previous: previous,
                updated: updated,
                plan: plan,
                transactionID: transactionID,
                quantity: quantity,
                salePortionQuantities: salePortionQuantities
            )
        }

        allItems[index] = updated
        if plan.kind == .buy { recordAppendedBuy(transaction, previous: previous, at: index) }
        if let soldAllocation { allItems[index].positionAllocation = soldAllocation }
        var updatedPlan = plan
        updatedPlan.filledTransactionID = plan.filledTransactionID.flatMap { legacyID in
            allItems[index].transactions.contains { $0.id == legacyID } ? legacyID : nil
        } ?? transactionID
        if TradePlanExecutionProgress(plan: updatedPlan, transactions: allItems[index].transactions).isComplete {
            updatedPlan.status = .done
        }
        updatedPlan.updatedAt = .now
        allItems[index].plans[planIndex] = updatedPlan
        save()
        return transaction
    }

    /// Works out the post-sale allocation for a plan sell, or refuses.
    ///
    /// Three shapes, in order of how much the caller told us:
    ///
    /// 1. An explicit `salePortionQuantities` map is the caller naming the
    ///    cards. Each id is validated against the live allocation, restricted
    ///    to the plan's pool when it has one, and the map's total must equal the
    ///    fill. The named portions are reduced by exactly those amounts.
    /// 2. No map and a single funding source among the candidate portions — one
    ///    distinct annotation, with `nil` read as `.unmarked` — consumes the
    ///    pool the way it always has. A pool whose cards all come from the same
    ///    money is unambiguous, so nothing is guessed.
    /// 3. No map and several sources: refused. Reducing one of them would
    ///    attribute the sale to a funding source the user never chose, and the
    ///    store cannot know which of their own or borrowed shares they meant.
    ///
    /// A plan with no pool and no explicit selection keeps the older behaviour:
    /// there is no pool to consume, so no shares are deducted and nothing is
    /// invented about where they came from.
    private func planSaleAllocation(
        previous: WatchItem,
        updated: WatchItem,
        plan: TradePlan,
        transactionID: UUID,
        quantity: Double,
        salePortionQuantities: [UUID: Double]?
    ) throws -> PositionAllocation? {
        guard plan.positionPool != nil || salePortionQuantities != nil else { return nil }
        guard let allocation = previous.positionAllocation,
              previous.positionQuantity > 0, !previous.positionAllocationNeedsReconciliation else {
            throw TradePlanExecutionError.allocationNeedsReconciliation
        }
        guard updated.transactions.last?.id == transactionID else {
            throw TradePlanExecutionError.historicalPoolSale
        }

        if let selection = salePortionQuantities {
            // Naming the cards is authoritative, so it works with or without a
            // pool on the plan; a nil pool competes across every portion.
            return try selectedSaleAllocation(
                allocation: allocation,
                updated: updated,
                pool: plan.positionPool,
                selection: selection,
                quantity: quantity
            )
        }
        guard let pool = plan.positionPool else { return nil }

        let candidates = allocation.portions.filter { $0.pool == pool }
        let available = candidates.reduce(0) { $0 + $1.quantity }
        guard available.isFinite,
              quantity <= available + PositionAllocation.quantityTolerance(quantity, available) else {
            throw TradePlanExecutionError.insufficientPoolQuantity(
                pool: pool, requested: quantity, available: available
            )
        }
        let sources = Set(candidates.map { $0.fundingSource ?? .unmarked })
        guard sources.count <= 1 else {
            var totals: [PositionFundingSource: Double] = [:]
            for portion in candidates {
                totals[portion.fundingSource ?? .unmarked, default: 0] += portion.quantity
            }
            throw TradePlanExecutionError.fundingSelectionRequired(available: totals)
        }

        var remaining = quantity
        let portions = allocation.portions.compactMap { portion -> PositionPortion? in
            guard portion.pool == pool, remaining > 0 else { return portion }
            let consumed = min(portion.quantity, remaining)
            remaining -= consumed
            var rest = portion
            rest.quantity -= consumed
            return rest.quantity > PositionAllocation.quantityTolerance(rest.quantity, consumed) ? rest : nil
        }
        return try validatedSaleAllocation(
            allocation: allocation, portions: portions, updated: updated, quantity: quantity
        )
    }

    /// Reduces exactly the portions a caller named, rejecting anything that
    /// does not describe this sale.
    private func selectedSaleAllocation(
        allocation: PositionAllocation,
        updated: WatchItem,
        pool: PositionPool?,
        selection: [UUID: Double],
        quantity: Double
    ) throws -> PositionAllocation {
        let byID = Dictionary(allocation.portions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var selected: [UUID: Double] = [:]
        for (id, amount) in selection {
            // An unknown id, a portion outside the plan's pool, a non-positive
            // or non-finite amount, or an amount past the card's own size all
            // mean the same thing: this map does not describe this sale.
            guard let portion = byID[id],
                  pool == nil || portion.pool == pool,
                  amount.isFinite, amount > 0,
                  amount <= portion.quantity + PositionAllocation.quantityTolerance(amount, portion.quantity) else {
                throw TradePlanExecutionError.invalidFundingSelection
            }
            selected[id] = amount
        }
        let total = selected.values.reduce(0, +)
        guard !selected.isEmpty, total.isFinite,
              abs(total - quantity) <= PositionAllocation.quantityTolerance(total, quantity) else {
            throw TradePlanExecutionError.invalidFundingSelection
        }
        let portions = allocation.portions.compactMap { portion -> PositionPortion? in
            guard let consumed = selected[portion.id] else { return portion }
            var rest = portion
            rest.quantity -= consumed
            return rest.quantity > PositionAllocation.quantityTolerance(rest.quantity, consumed) ? rest : nil
        }
        return try validatedSaleAllocation(
            allocation: allocation, portions: portions, updated: updated, quantity: quantity
        )
    }

    /// The last gate every sale passes: the candidate set must describe the
    /// position the trade actually left behind, or the sale is refused.
    private func validatedSaleAllocation(
        allocation: PositionAllocation,
        portions: [PositionPortion],
        updated: WatchItem,
        quantity: Double
    ) throws -> PositionAllocation {
        var candidate = changedAllocation(
            allocation, portions: portions, item: updated, kind: .reconcile,
            reason: "Recorded plan sale"
        )
        // A flat position keeps its history with no occupied portions.
        if updated.positionQuantity == 0 { candidate.portions = [] }
        var check = updated
        check.positionAllocation = candidate
        guard !check.positionAllocationNeedsReconciliation else {
            throw TradePlanExecutionError.allocationNeedsReconciliation
        }
        return candidate
    }

    /// Appends a trade. The first transaction on a lot-based item folds the
    /// legacy position into the ledger as an opening adjustment. A buy may
    /// carry a zero price — that is how a share split is bridged (more shares,
    /// no money moved); a sell at zero would fabricate a realized loss, so it
    /// stays strictly positive.
    public func addTransaction(_ symbol: SymbolID, _ transaction: PositionTransaction) {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }),
              allItems[index].supportsPosition,
              transaction.quantity.isFinite, transaction.quantity > 0,
              transaction.price.isFinite, transaction.price >= 0,
              transaction.kind == .buy || transaction.price > 0,
              transaction.hasValidFee else { return }
        if allItems[index].positionAllocation == nil,
           allItems[index].positionQuantity.isFinite, allItems[index].positionQuantity > 0 {
            _ = initializePositionAllocation(&allItems[index])
        }
        var transactions = allItems[index].materializedTransactions()
        transactions.append(transaction)
        commitTransactions(transactions, at: index, appendedBuy: transaction.kind == .buy ? transaction : nil)
    }

    public func deleteTransaction(_ symbol: SymbolID, id: UUID) {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }) else { return }
        var transactions = allItems[index].transactions
        let count = transactions.count
        transactions.removeAll { $0.id == id }
        guard transactions.count != count else { return }
        commitTransactions(transactions, at: index)
    }

    /// Replaces the transaction carrying `transaction.id`, keeping its
    /// `createdAt` so an edit never reshuffles same-day replay order. Buys may
    /// bridge a share split at a zero price; sells keep a positive price and
    /// an adjustment keeps the calibrator's looser contract (finite quantity,
    /// non-negative cost).
    public func updateTransaction(_ symbol: SymbolID, _ transaction: PositionTransaction) {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }),
              allItems[index].supportsPosition else { return }
        guard transaction.hasValidFee else { return }
        switch transaction.kind {
        case .buy:
            guard transaction.price.isFinite, transaction.price >= 0,
                  transaction.quantity.isFinite, transaction.quantity > 0 else { return }
        case .sell:
            guard transaction.price.isFinite, transaction.price > 0,
                  transaction.quantity.isFinite, transaction.quantity > 0 else { return }
        case .adjustment:
            guard transaction.quantity.isFinite,
                  transaction.price.isFinite, transaction.price >= 0 else { return }
        }
        var transactions = allItems[index].transactions
        guard let existing = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        var updated = transaction
        updated.createdAt = transactions[existing].createdAt
        updated.planExecution = transactions[existing].planExecution ?? updated.planExecution
        updated = Self.preservingTransactionMetadata(updated, from: transactions[existing])
        transactions[existing] = updated
        commitTransactions(transactions, at: index)
    }

    /// Updates only the user's execution reason and post-trade review. Keeping
    /// this separate from ledger edits protects trade values, dates, and order.
    @discardableResult
    public func updateTransactionReview(
        _ symbol: SymbolID,
        id: UUID,
        note: String?,
        review: PositionTransactionReview?
    ) -> Bool {
        let normalizedNote = Self.nonemptyText(note)
        var normalizedReview = review
        if var value = normalizedReview {
            value.retrospective = Self.nonemptyText(value.retrospective)
            value.strategy = Self.nonemptyText(value.strategy)
            // The checkpoint fields are validated as a unit: a non-finite date
            // or an over-long note refuses the whole update rather than
            // persisting the other half. Nothing is written on that path.
            guard let checked = value.normalizedCheckpoint() else { return false }
            normalizedReview = checked
        }
        // A review is empty only when every one of its fields is absent. The
        // checkpoint fields count: a note to check next week with no verdict
        // about the trade yet is a review worth keeping.
        if normalizedReview?.followedPlan == nil, normalizedReview?.retrospective == nil,
           normalizedReview?.strategy == nil, normalizedReview?.hasCheckpoint != true {
            normalizedReview = nil
        }

        if let itemIndex = allItems.firstIndex(where: { $0.symbol == symbol }),
           let transactionIndex = allItems[itemIndex].transactions.firstIndex(where: { $0.id == id }) {
            guard allItems[itemIndex].transactions[transactionIndex].note != normalizedNote
                    || allItems[itemIndex].transactions[transactionIndex].review != normalizedReview else {
                return false
            }
            allItems[itemIndex].transactions[transactionIndex].note = normalizedNote
            allItems[itemIndex].transactions[transactionIndex].review = normalizedReview
        } else if let itemIndex = retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }),
                  let transactionIndex = retainedHistoryItems[itemIndex].transactions.firstIndex(where: { $0.id == id }) {
            guard retainedHistoryItems[itemIndex].transactions[transactionIndex].note != normalizedNote
                    || retainedHistoryItems[itemIndex].transactions[transactionIndex].review != normalizedReview else {
                return false
            }
            retainedHistoryItems[itemIndex].transactions[transactionIndex].note = normalizedNote
            retainedHistoryItems[itemIndex].transactions[transactionIndex].review = normalizedReview
        } else {
            return false
        }
        save()
        return true
    }

    /// Captures each existing long position once; it never infers an order or FIFO lot history.
    public func initializePositionAllocations() {
        var changed = false
        for index in allItems.indices {
            changed = initializePositionAllocation(&allItems[index]) || changed
        }
        for index in retainedHistoryItems.indices {
            changed = initializePositionAllocation(&retainedHistoryItems[index]) || changed
        }
        if changed { save() }
    }

    @discardableResult
    public func transferPositionPortion(
        symbol: SymbolID,
        portionID: UUID,
        quantity: Double,
        to pool: PositionPool,
        reason: String,
        expectedRevision: UUID
    ) throws -> PositionAllocation {
        guard let item = positionAllocationItem(for: symbol) else {
            throw PositionAllocationError.itemNotFound(symbol)
        }
        // The retired observation purpose is not a destination any more. It is
        // refused rather than folded, because a caller asking to move shares
        // "into observation" wants the old verification bucket; the answer is to
        // record conditions on the card, not to silently land somewhere else.
        guard pool.isActivePurpose else { throw PositionAllocationError.retiredPool }
        let current = try currentPositionAllocation(for: item, expectedRevision: expectedRevision)
        guard quantity.isFinite, quantity > 0 else { throw PositionAllocationError.invalidQuantity }
        let enteredReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = enteredReason.isEmpty ? "用途调整" : enteredReason
        guard let index = current.portions.firstIndex(where: { $0.id == portionID }) else {
            throw PositionAllocationError.unknownPortion(portionID)
        }
        var portions = current.portions
        var source = portions[index]
        // A legacy card still stored under the retired purpose reads as
        // unassigned, so "move to unassigned" is not a no-op the user can see.
        guard source.pool.effectivePurpose != pool else { throw PositionAllocationError.samePool }
        let tolerance = PositionAllocation.quantityTolerance(quantity, source.quantity)
        guard quantity <= source.quantity + tolerance else {
            throw PositionAllocationError.quantityExceedsPortion
        }
        if quantity >= source.quantity - tolerance {
            source.pool = pool
            portions.remove(at: index)
            portions.append(source)
        } else {
            portions[index].quantity -= quantity
            // The moved card is a copy of the source, so every annotation it
            // carries — note, funding, conditions, and its brokerage account
            // label — travels with the shares that left.
            var moved = source
            moved.id = UUID()
            moved.quantity = quantity
            moved.pool = pool
            portions.append(moved)
        }
        let updated = changedAllocation(
            current,
            portions: portions,
            item: item,
            kind: .transfer,
            reason: reason
        )
        setPositionAllocation(updated, for: symbol)
        save()
        return updated
    }

    /// Annotates which money a portion was bought with, or clears the
    /// annotation with `.unmarked`.
    ///
    /// This is a labelling change and nothing else: it moves no shares, creates
    /// no transaction, and touches no price, quantity, cost, or P&L. Labelling
    /// a whole portion copies it and rewrites the source, so origin, pool, and
    /// note survive; labelling part of one splits a new id off the original and
    /// reduces the original by exactly that much, the same shape a partial
    /// transfer has. Shares are conserved either way.
    ///
    /// `reason` is optional and defaults to a generic label rather than being
    /// required, because the annotation itself is the record — asking for prose
    /// to go with it would only train people to type a dash.
    ///
    /// `.unmarked` is stored rather than normalized away: it is what makes "the
    /// user says this is unclassified" distinguishable from `nil`'s "nobody has
    /// said anything yet", and only the explicit one survives a later merge
    /// against a record that never had the field.
    @discardableResult
    public func markPositionFundingSource(
        symbol: SymbolID,
        portionID: UUID,
        quantity: Double,
        source: PositionFundingSource,
        reason: String,
        expectedRevision: UUID
    ) throws -> PositionAllocation {
        guard let item = positionAllocationItem(for: symbol) else {
            throw PositionAllocationError.itemNotFound(symbol)
        }
        let current = try currentPositionAllocation(for: item, expectedRevision: expectedRevision)
        guard quantity.isFinite, quantity > 0 else { throw PositionAllocationError.invalidQuantity }
        guard let index = current.portions.firstIndex(where: { $0.id == portionID }) else {
            throw PositionAllocationError.unknownPortion(portionID)
        }
        var portions = current.portions
        let original = portions[index]
        guard original.fundingSource != source else { throw PositionAllocationError.sameFundingSource }
        let tolerance = PositionAllocation.quantityTolerance(quantity, original.quantity)
        guard quantity <= original.quantity + tolerance else {
            throw PositionAllocationError.quantityExceedsPortion
        }
        if quantity >= original.quantity - tolerance {
            // Whole portion: the card keeps its identity, so a pool assignment
            // or note already attached to it is annotated rather than copied.
            var relabelled = original
            relabelled.fundingSource = source
            portions[index] = relabelled
        } else {
            // Partial: only the labelled shares leave the original card, so the
            // remainder keeps its id, origin, and history untouched. Both halves
            // are copies of the original, which is what carries a brokerage
            // account label across the split unchanged.
            var remainder = original
            remainder.quantity = original.quantity - quantity
            var labelled = original
            labelled.id = UUID()
            labelled.quantity = quantity
            labelled.fundingSource = source
            portions[index] = remainder
            portions.insert(labelled, at: index + 1)
        }
        let enteredReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = changedAllocation(
            current,
            portions: portions,
            item: item,
            kind: .funding,
            reason: enteredReason.isEmpty ? "资金来源标注" : enteredReason
        )
        setPositionAllocation(updated, for: symbol)
        save()
        return updated
    }

    /// The most conditions one portion may carry. A card is a place to record
    /// the handful of things that would change your mind, not a notebook; the
    /// cap keeps a paste or an agent from writing an unbounded array that every
    /// sync pass and archive round trip then has to carry.
    public static let maximumPortionConditionCount = 64

    /// Replaces the conditions a portion is held against.
    ///
    /// This is a metadata-only edit in the same family as
    /// `markPositionFundingSource`: it moves no shares, creates no transaction,
    /// and touches no price, quantity, cost, pool, origin, or funding. What it
    /// does change is the reasoning attached to the card, so it appends a
    /// `.verification` audit entry that keeps the previous and resulting
    /// condition arrays — which is what makes a single-step undo possible and
    /// what makes "the user cleared them" survive a merge.
    ///
    /// `conditions` is normalized and validated whole: a blank title, a
    /// malformed event reference, a duplicate id, or more than
    /// `maximumPortionConditionCount` entries is refused and nothing is written.
    /// Passing an explicit empty array clears the conditions and is stored as an
    /// empty array, distinct from `nil`'s "never recorded".
    ///
    /// An edit that normalizes to exactly what the card already holds returns
    /// the current allocation without saving, so a no-op edit never bumps the
    /// revision, never appends history, and never schedules a sync write.
    @discardableResult
    public func setPositionConditions(
        symbol: SymbolID,
        portionID: UUID,
        conditions: [TradePlanCondition]?,
        reason: String = "",
        expectedRevision: UUID
    ) throws -> PositionAllocation {
        guard let item = positionAllocationItem(for: symbol) else {
            throw PositionAllocationError.itemNotFound(symbol)
        }
        let current = try currentPositionAllocation(for: item, expectedRevision: expectedRevision)
        guard let index = current.portions.firstIndex(where: { $0.id == portionID }) else {
            throw PositionAllocationError.unknownPortion(portionID)
        }
        let normalized = try Self.validatedPortionConditions(conditions)
        guard normalized != current.portions[index].conditions else { return current }

        var portions = current.portions
        portions[index].conditions = normalized
        let enteredReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = changedAllocation(
            current,
            portions: portions,
            item: item,
            kind: .verification,
            reason: enteredReason.isEmpty ? "持有判断" : enteredReason
        )
        guard updated.isValid else { throw PositionAllocationError.invalidConditions }
        setPositionAllocation(updated, for: symbol)
        save()
        return updated
    }

    /// Labels which brokerage account a portion's shares are held in.
    ///
    /// This is metadata-only, in the same family as `markPositionFundingSource`
    /// and `setPositionConditions`: it moves no share, creates no transaction,
    /// and touches no price, quantity, cost, pool, origin, funding, or
    /// condition. What it changes is attribution, so it appends an `.account`
    /// audit entry whose before/after snapshots carry the previous and resulting
    /// portions — which is what lets a single-step undo restore the old label and
    /// what makes an explicit label survive a merge.
    ///
    /// `accountID` is a catalog `BrokerageAccountID`. `.unassigned` is stored as
    /// itself rather than normalized away, because it is a chosen value while
    /// `nil` is "inherit the enclosing ledger". There is deliberately no way to
    /// write `nil` through this API: clearing a label is the `.unassigned` case,
    /// and the two states stay distinguishable.
    ///
    /// The guards match every other allocation setter: the item must carry a
    /// valid, source-matching, fully-allocated position, and the caller's
    /// revision must be current. Tagging a card with the label it already holds
    /// returns the current allocation without saving, so a repeated tag never
    /// bumps the revision or appends history.
    @discardableResult
    public func setPositionBrokerageAccount(
        symbol: SymbolID,
        portionID: UUID,
        accountID: BrokerageAccountID,
        expectedRevision: UUID
    ) throws -> PositionAllocation {
        guard let item = positionAllocationItem(for: symbol) else {
            throw PositionAllocationError.itemNotFound(symbol)
        }
        let current = try currentPositionAllocation(for: item, expectedRevision: expectedRevision)
        guard let index = current.portions.firstIndex(where: { $0.id == portionID }) else {
            throw PositionAllocationError.unknownPortion(portionID)
        }
        guard current.portions[index].brokerageAccountID != accountID else {
            return current
        }
        var portions = current.portions
        portions[index].brokerageAccountID = accountID
        let updated = changedAllocation(
            current,
            portions: portions,
            item: item,
            kind: .account,
            reason: "券商账户标注"
        )
        setPositionAllocation(updated, for: symbol)
        save()
        return updated
    }

    /// Normalizes and validates one condition payload, refusing anything that
    /// cannot be stored. Shared by the store API and the migration so a migrated
    /// condition is held to the same bar as one the user typed.
    private static func validatedPortionConditions(
        _ conditions: [TradePlanCondition]?
    ) throws -> [TradePlanCondition]? {
        guard let conditions else { return nil }
        guard conditions.count <= maximumPortionConditionCount else {
            throw PositionAllocationError.tooManyConditions(limit: maximumPortionConditionCount)
        }
        let normalized = conditions.compactMap { $0.normalized() }
        guard normalized.count == conditions.count,
              Set(normalized.map(\.id)).count == normalized.count else {
            throw PositionAllocationError.invalidConditions
        }
        return normalized
    }

    @discardableResult
    public func reconcilePositionAllocation(
        symbol: SymbolID,
        quantities: [UUID: Double],
        reason: String,
        expectedRevision: UUID
    ) throws -> PositionAllocation {
        guard let item = positionAllocationItem(for: symbol) else {
            throw PositionAllocationError.itemNotFound(symbol)
        }
        guard item.supportsPosition, item.positionQuantity.isFinite, item.positionQuantity > 0 else {
            throw PositionAllocationError.notApplicable
        }
        guard let current = item.positionAllocation else { throw PositionAllocationError.missingAllocation }
        guard current.revision == expectedRevision else {
            throw PositionAllocationError.staleRevision(expected: expectedRevision, actual: current.revision)
        }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw PositionAllocationError.reasonRequired }
        for (id, quantity) in quantities {
            guard current.portions.contains(where: { $0.id == id }) else {
                throw PositionAllocationError.unknownQuantity(id)
            }
            guard quantity.isFinite, quantity >= 0 else { throw PositionAllocationError.invalidQuantity }
        }
        for portion in current.portions where quantities[portion.id] == nil {
            throw PositionAllocationError.missingQuantity(portion.id)
        }
        var confirmedQuantities = quantities
        var total = current.portions.reduce(0.0) { $0 + (confirmedQuantities[$1.id] ?? 0) }
        guard total.isFinite else { throw PositionAllocationError.invalidQuantity }
        let held = item.positionQuantity
        if total > held {
            var excess = total - held
            let tolerance = PositionAllocation.quantityTolerance(total, held)
            guard excess <= tolerance else { throw PositionAllocationError.totalExceedsPosition }
            for portion in current.portions.reversed() {
                guard let quantity = confirmedQuantities[portion.id], quantity > 0 else { continue }
                let reduced = quantity - excess
                if reduced >= 0, reduced < quantity {
                    confirmedQuantities[portion.id] = reduced
                    excess -= quantity - reduced
                    if excess <= 0 { break }
                }
            }
            total = current.portions.reduce(0.0) { $0 + (confirmedQuantities[$1.id] ?? 0) }
            guard total <= held || total - held <= tolerance else {
                throw PositionAllocationError.totalExceedsPosition
            }
        }

        let invalidSource = !current.hasMatchingSources(for: item)
        var portions = current.portions.compactMap { portion -> PositionPortion? in
            guard let quantity = confirmedQuantities[portion.id], quantity > 0 else { return nil }
            var updated = portion
            updated.quantity = quantity
            if invalidSource {
                updated.origin = PositionPortion.Origin(kind: .snapshot, date: .now)
            }
            return updated
        }
        let remainder = held - total
        if remainder > 0 {
            // A reconciliation remainder is a genuinely new card with no prior
            // attribution. Only the source is reset here; its account label is
            // left `nil` so it inherits the enclosing ledger rather than being
            // handed one of the surviving labels.
            portions.append(PositionPortion(
                quantity: remainder,
                pool: .unassigned,
                origin: PositionPortion.Origin(kind: .snapshot, date: .now)
            ))
        }
        let updated = changedAllocation(
            current,
            portions: portions,
            item: item,
            kind: invalidSource ? .sourceInvalidated : .reconcile,
            reason: reason
        )
        guard updated.isValid else { throw PositionAllocationError.sourceQuantityExceeded }
        setPositionAllocation(updated, for: symbol)
        save()
        return updated
    }

    /// Undoes one metadata or pool move.
    ///
    /// This stays a strict single step: only the newest change may be reverted,
    /// and only when it is one of the kind-preserving edits (`transfer`,
    /// `funding`, `verification`, `account`) whose previous state is fully
    /// described by `previousPortions`. A reconcile or an invalidation can change
    /// the basis or the set of pool assignments in ways a snapshot rollback would
    /// misrepresent, so those still require the user to re-do them.
    ///
    /// The revision guard is strict and unchanged: `previous.revision` must be
    /// the one the newest change replaced, so a rollback that raced another edit
    /// on the same position is refused rather than silently reverting that edit
    /// too.
    @discardableResult
    public func restorePositionAllocation(
        symbol: SymbolID,
        previous: PositionAllocation,
        expectedRevision: UUID
    ) throws -> PositionAllocation {
        guard let item = positionAllocationItem(for: symbol) else {
            throw PositionAllocationError.itemNotFound(symbol)
        }
        let current = try currentPositionAllocation(for: item, expectedRevision: expectedRevision)
        guard previous.basisFingerprint == current.basisFingerprint,
              let last = current.changes.last,
              last.kind == .transfer || last.kind == .funding || last.kind == .verification
                || last.kind == .account,
              last.priorRevision == previous.revision,
              last.previousPortions == previous.portions else {
            throw PositionAllocationError.noSingleTransferToRestore
        }
        let undoReason: String
        switch last.kind {
        case .funding: undoReason = "Undo funding change"
        case .verification: undoReason = "Undo verification change"
        case .account: undoReason = "Undo account change"
        default: undoReason = "Undo transfer"
        }
        let updated = changedAllocation(
            current,
            portions: previous.portions,
            item: item,
            kind: .restore,
            reason: undoReason
        )
        setPositionAllocation(updated, for: symbol)
        save()
        return updated
    }

    private func initializePositionAllocation(_ item: inout WatchItem) -> Bool {
        guard item.positionAllocation == nil, item.supportsPosition,
              item.positionQuantity.isFinite, item.positionQuantity > 0 else { return false }
        let portion = PositionPortion(
            quantity: item.positionQuantity,
            pool: .unassigned,
            origin: PositionPortion.Origin(kind: .snapshot, date: .now)
        )
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [portion],
            changes: [PositionAllocation.Change(
                kind: .initialize,
                reason: "Current position snapshot",
                previousPortions: [],
                resultingPortions: [portion]
            )]
        )
        return true
    }

    private func positionAllocationItem(for symbol: SymbolID) -> WatchItem? {
        item(for: symbol) ?? retainedHistoryItem(for: symbol)
    }

    private func setPositionAllocation(_ allocation: PositionAllocation, for symbol: SymbolID) {
        if let index = allItems.firstIndex(where: { $0.symbol == symbol }) {
            allItems[index].positionAllocation = allocation
        } else if let index = retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }) {
            retainedHistoryItems[index].positionAllocation = allocation
        }
    }

    private func currentPositionAllocation(
        for item: WatchItem,
        expectedRevision: UUID
    ) throws -> PositionAllocation {
        guard item.supportsPosition, item.positionQuantity.isFinite, item.positionQuantity > 0 else {
            throw PositionAllocationError.notApplicable
        }
        guard let allocation = item.positionAllocation else { throw PositionAllocationError.missingAllocation }
        guard allocation.revision == expectedRevision else {
            throw PositionAllocationError.staleRevision(expected: expectedRevision, actual: allocation.revision)
        }
        guard !item.positionAllocationNeedsReconciliation else {
            throw PositionAllocationError.needsReconciliation
        }
        return allocation
    }

    private func changedAllocation(
        _ current: PositionAllocation,
        portions: [PositionPortion],
        item: WatchItem,
        kind: PositionAllocation.Change.Kind,
        reason: String
    ) -> PositionAllocation {
        var updated = current
        updated.revision = UUID()
        updated.basisFingerprint = PositionAllocation.basisFingerprint(for: item)
        updated.portions = portions
        updated.changes.append(PositionAllocation.Change(
            kind: kind,
            reason: reason,
            priorRevision: current.revision,
            previousPortions: current.portions,
            resultingPortions: portions
        ))
        return updated
    }

    private static func nonemptyText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fillingMissingTradingProfile(
        _ existing: TradingProfile?,
        from incoming: TradingProfile?
    ) -> TradingProfile? {
        guard let incoming, incoming.isValid else { return existing }
        var result = existing ?? TradingProfile()
        if result.sector == nil { result.sector = nonemptyText(incoming.sector) }
        if result.stopPrice == nil { result.stopPrice = incoming.stopPrice }
        if result.targetPrice == nil { result.targetPrice = incoming.targetPrice }
        return result.sector == nil && result.stopPrice == nil && result.targetPrice == nil ? nil : result
    }

    /// Overwrites the position with a target quantity and average cost as an
    /// `.adjustment` entry ("quick set" / reconciling with a broker). A
    /// negative quantity calibrates a short. Produces no realized P&L.
    public func calibratePosition(
        _ symbol: SymbolID,
        quantity: Double,
        averageCost: Double,
        date: Date = .now,
        id: UUID = UUID()
    ) {
        guard let index = allItems.firstIndex(where: { $0.symbol == symbol }),
              allItems[index].supportsPosition,
              quantity.isFinite, averageCost.isFinite, averageCost >= 0 else { return }
        var transactions = allItems[index].materializedTransactions()
        transactions.append(PositionTransaction(
            id: id,
            kind: .adjustment,
            price: averageCost,
            quantity: quantity,
            date: date
        ))
        commitTransactions(transactions, at: index)
    }

    /// Stores the replay-ordered list and refreshes the derived single-lot
    /// cache so lot-based consumers (rows, sharing, older builds) keep seeing
    /// the open position. A short caches as a negative-quantity lot, which
    /// older builds simply treat as no position rather than corrupting it.
    private func commitTransactions(
        _ transactions: [PositionTransaction],
        at index: Int,
        appendedBuy: PositionTransaction? = nil
    ) {
        let previous = allItems[index]
        applyTransactions(transactions, at: index)
        // Reopen only a plan that was completed by its linked fills. A manually
        // closed partial plan and a cancelled plan remain the user's decision.
        for planIndex in allItems[index].plans.indices {
            let plan = allItems[index].plans[planIndex]
            guard plan.status == .done,
                  TradePlanExecutionProgress(plan: plan, transactions: previous.transactions).isComplete,
                  !TradePlanExecutionProgress(plan: plan, transactions: allItems[index].transactions).isComplete else {
                continue
            }
            allItems[index].plans[planIndex].status = .active
            allItems[index].plans[planIndex].updatedAt = .now
        }
        if let appendedBuy { recordAppendedBuy(appendedBuy, previous: previous, at: index) }
        save()
    }

    private func recordAppendedBuy(
        _ transaction: PositionTransaction,
        previous: WatchItem,
        at index: Int
    ) {
        guard transaction.kind == .buy, allItems[index].positionQuantity > 0 else { return }
        let newTransactions = allItems[index].transactions
        guard newTransactions.last?.id == transaction.id,
              newTransactions.filter({ $0.id == transaction.id }).count == 1 else { return }
        if previous.transactions.isEmpty {
            let legacyAdjustment = previous.materializedTransactions().first
            guard newTransactions.count == (legacyAdjustment == nil ? 1 : 2) else { return }
            if let legacyAdjustment, let applied = newTransactions.first {
                guard applied.kind == .adjustment,
                      applied.price == legacyAdjustment.price,
                      applied.quantity == legacyAdjustment.quantity,
                      applied.date == legacyAdjustment.date,
                      applied.createdAt == legacyAdjustment.createdAt else { return }
            }
        } else {
            guard newTransactions.count == previous.transactions.count + 1,
                  previous.transactions.allSatisfy({ old in
                      newTransactions.first(where: { $0.id == old.id }) == old
                  }) else { return }
        }
        let added = allItems[index].positionQuantity - previous.positionQuantity
        guard abs(added - transaction.quantity) <= PositionAllocation.quantityTolerance(added, transaction.quantity) else {
            return
        }
        if previous.positionQuantity == 0 {
            let portion = Self.buyPortion(from: transaction)
            let note = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var changes = previous.positionAllocation?.changes ?? []
            changes.append(PositionAllocation.Change(
                kind: .buy,
                reason: note.isEmpty ? "Buy transaction" : note,
                priorRevision: previous.positionAllocation?.revision,
                previousPortions: previous.positionAllocation?.portions ?? [],
                resultingPortions: [portion]
            ))
            allItems[index].positionAllocation = PositionAllocation(
                revision: UUID(),
                basisFingerprint: PositionAllocation.basisFingerprint(for: allItems[index]),
                portions: [portion],
                changes: changes
            )
            return
        }
        guard let allocation = previous.positionAllocation,
              !previous.positionAllocationNeedsReconciliation,
              previous.positionQuantity > 0 else { return }
        let portion = Self.buyPortion(from: transaction)
        let note = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let updated = changedAllocation(
            allocation,
            portions: allocation.portions + [portion],
            item: allItems[index],
            kind: .buy,
            reason: note.isEmpty ? "Buy transaction" : note
        )
        allItems[index].positionAllocation = updated
    }

    /// The portion a recorded buy creates.
    ///
    /// Pool and conditions both come from the transaction's *immutable*
    /// `planExecution` snapshot, never from the plan currently stored under that
    /// id. A plan may have been rewritten, re-pooled, or have had its conditions
    /// cleared since the fill was reported; the shares that exist were bought
    /// against the reasoning that was in force at the time, and that is the copy
    /// the snapshot froze.
    ///
    /// A snapshot still naming the retired observation purpose creates an
    /// `unassigned` portion. Its conditions are carried across unchanged, and if
    /// it recorded none, a pending "review the original observation" condition
    /// is added so the legacy intent to verify is preserved as a task rather
    /// than lost with the pool.
    ///
    /// The brokerage account is deliberately left `nil`. A buy is a *new* card
    /// with no prior attribution, and the transaction carries no account field
    /// to inherit from: the label belongs to whatever ledger the buy is recorded
    /// in, which the enclosing-account fallback already supplies. Inventing an
    /// owner here would attribute shares nobody classified.
    nonisolated static func buyPortion(from transaction: PositionTransaction) -> PositionPortion {
        let configuration = transaction.planExecution?.configuration
        let recordedPool = configuration?.positionPool ?? .unassigned
        var conditions = configuration?.conditions
        if recordedPool == .observation {
            conditions = Self.addingLegacyObservationCondition(to: conditions)
        }
        return PositionPortion(
            quantity: transaction.quantity,
            pool: recordedPool.effectivePurpose,
            origin: PositionPortion.Origin(
                kind: .buy,
                transactionID: transaction.id,
                date: transaction.date,
                price: transaction.price,
                quantity: transaction.quantity
            ),
            // The fill's own funding, never the plan's intent. The two can
            // disagree — a plan written for margin paid with cash — and the
            // portion has to follow the money that actually moved.
            fundingSource: transaction.fundingSource,
            conditions: conditions
        )
    }

    /// The condition the legacy observation purpose becomes.
    ///
    /// One fixed id would collide when a portion and a plan are both migrated,
    /// and a random one per call would make the migration non-idempotent — a
    /// second pass would append a duplicate. A deterministic id derived from the
    /// title gives both properties: the same legacy intent always maps to the
    /// same condition id, so "does it already exist" is answerable, and two
    /// different portions can each hold their own copy without a shared state.
    nonisolated static func legacyObservationCondition(id: UUID? = nil) -> TradePlanCondition {
        TradePlanCondition(
            id: id ?? legacyObservationConditionID,
            title: legacyObservationConditionTitle,
            kind: .manual,
            state: .pending
        )
    }

    /// The title the retired observation purpose maps to. Fixed so the migration
    /// can look for it before adding another.
    nonisolated static let legacyObservationConditionTitle = "核对原观察仓的持有判断"

    /// Stable id for the migration's condition. Not a random UUID: the
    /// migration must recognize its own earlier output across runs and devices.
    nonisolated static let legacyObservationConditionID = UUID(
        uuidString: "0b5e7a1c-9d4f-5e21-8a37-6c1f2d4b7e90"
    )!

    /// Whether this array already carries the migrated observation condition.
    ///
    /// Matched on the stable id rather than the title: a user is free to retitle
    /// the condition they were given, and the migration must not then hand them
    /// a second copy of it.
    nonisolated static func hasLegacyObservationCondition(_ conditions: [TradePlanCondition]?) -> Bool {
        (conditions ?? []).contains { $0.id == legacyObservationConditionID }
    }

    /// Applies the legacy observation migration to one condition array: keeps
    /// what is there and adds the pending review condition once.
    nonisolated static func addingLegacyObservationCondition(
        to conditions: [TradePlanCondition]?
    ) -> [TradePlanCondition] {
        var result = conditions ?? []
        guard !hasLegacyObservationCondition(result) else { return result }
        result.append(legacyObservationCondition())
        return result
    }

    /// Migrates a plan whose purpose is the retired observation pool.
    ///
    /// Only the current purpose is migrated. Historical configurations and
    /// immutable transaction snapshots remain as recorded. Everything the user attached survives: the id, the
    /// conditions they wrote, and the legacy filled-transaction link. The
    /// pre-migration configuration is appended as a revision first, so the
    /// intent to observe is still readable in the plan's own history rather than
    /// being erased by the migration.
    ///
    /// A plan with no observation anywhere is returned untouched, which is what
    /// makes calling this on every incoming plan safe and cheap.
    nonisolated static func migratedPlan(_ plan: TradePlan, at date: Date? = nil) -> TradePlan {
        guard plan.positionPool == .observation else { return plan }
        var result = plan
        result.positionPool = .unassigned
        result.conditions = addingLegacyObservationCondition(to: result.conditions)
        let revisionID = observationMigrationID(plan.id, kind: "plan|\(plan.updatedAt.timeIntervalSinceReferenceDate.bitPattern)")
        if !(result.history ?? []).contains(where: { $0.id == revisionID }) {
            result.history = (result.history ?? []) + [TradePlanRevision(id: revisionID,
                date: date ?? plan.updatedAt, configuration: TradePlanConfiguration(plan: plan))]
        }
        return result
    }

    /// Migrates one allocation's current portions off the retired observation
    /// purpose, and records the change.
    ///
    /// Every property that identifies shares survives: quantity, origin,
    /// funding, note, and each portion's id. Only the purpose moves, and each
    /// migrated card gains the pending review condition unless it already holds
    /// one. The change entry keeps the original `previousPortions` so the audit
    /// shows what the user actually had, and the caller supplies the resulting
    /// ones.
    ///
    /// This deliberately does not go through `changedAllocation`. That helper
    /// recomputes `basisFingerprint` and stamps a fresh revision — and a
    /// migration must not recalculate the basis, because a position whose ledger
    /// has since drifted would be re-blessed as verified by the act of
    /// migrating it. The basis and any reconciliation state are carried over
    /// exactly as they were; only `revision` is renewed, which is what tells a
    /// stale caller to re-read.
    nonisolated static func migratedAllocation(
        _ allocation: PositionAllocation,
        at date: Date? = nil
    ) -> PositionAllocation {
        guard allocation.portions.contains(where: { $0.pool == .observation }) else { return allocation }
        var migrated = allocation
        migrated.revision = observationMigrationID(allocation.revision, kind: "allocation")
        migrated.portions = allocation.portions.map { portion in
            guard portion.pool == .observation else { return portion }
            var updated = portion
            updated.pool = .unassigned
            updated.conditions = addingLegacyObservationCondition(to: updated.conditions)
            return updated
        }
        migrated.changes.append(PositionAllocation.Change(
            id: observationMigrationID(allocation.revision, kind: "change"),
            date: date ?? allocation.changes.last?.date ?? allocation.portions.compactMap(\.origin.date).max() ?? Date(timeIntervalSince1970: 0),
            kind: .reconcile,
            reason: "Retired observation purpose migrated to unassigned",
            priorRevision: allocation.revision,
            previousPortions: allocation.portions,
            resultingPortions: migrated.portions
        ))
        return migrated
    }

    // Identical legacy copies must migrate identically on different devices.
    private nonisolated static func observationMigrationID(_ original: UUID, kind: String) -> UUID {
        let hash = SHA256.hash(data: Data("retire-observation-v1|\(kind)|\(original.uuidString)".utf8))
        let bytes = Array(hash.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Replays a ledger onto an item and refreshes its derived single-lot cache.
    /// Split out from `commitTransactions` so a bulk import can apply many items
    /// before persisting once.
    private func applyTransactions(_ transactions: [PositionTransaction], at index: Int) {
        allItems[index] = Self.applyingTransactions(transactions, to: allItems[index])
    }

    private static func applyingTransactions(_ transactions: [PositionTransaction], to item: WatchItem) -> WatchItem {
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

    /// Replaces a persisted name only when its provider outranks the saved source.
    /// Static reference data may refresh a name from the same provider (for a
    /// locale change or an official rename); quote ticks never need that privilege.
    @discardableResult
    public func upgradeDisplayName(
        for symbol: SymbolID,
        to rawName: String,
        source: DisplayNameSource,
        allowSameProviderRefresh: Bool = false
    ) -> Bool {
        guard symbol.indexID == nil, symbol.metalID == nil,
              let index = allItems.firstIndex(where: { $0.symbol == symbol }) else {
            return false
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }

        let currentSource = allItems[index].displayNameSource
        let currentName = allItems[index].displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlaceholderName = currentName.isEmpty
            || currentName.caseInsensitiveCompare(symbol.code) == .orderedSame
            || currentName.caseInsensitiveCompare(symbol.displayCode) == .orderedSame
        // Legacy watchlists have no provenance. Preserve a real saved name
        // against quote ticks; authoritative static data may adopt and rank it.
        let isUpgrade = currentSource.map { source.priority < $0.priority }
            ?? (allowSameProviderRefresh || hasPlaceholderName)
        let isSameProviderRefresh = allowSameProviderRefresh
            && currentSource?.providerID == source.providerID
            && currentSource?.priority == source.priority
        guard isUpgrade || isSameProviderRefresh else { return false }
        guard allItems[index].displayName != name || currentSource != source else { return false }

        allItems[index].displayName = name
        allItems[index].displayNameSource = source
        save()
        return true
    }

    // MARK: - Archive

    /// The current grouped watchlists in portable form and display order.
    /// Retained-only history remains dormant and is not added to an exported list.
    public func archive(exportedAt: Date = .now, app: String? = nil) -> WatchlistArchive {
        let itemsBySymbol = Dictionary(uniqueKeysWithValues: allItems.map { ($0.symbol, $0) })
        let lists = groups.map { group in
            let pinned = Set(group.pinnedSymbols)
            let entries = group.symbols.compactMap { symbol -> WatchlistArchive.Entry? in
                guard let item = itemsBySymbol[symbol] else { return nil }
                let archiveTransactions = item.materializedTransactions()
                var archiveAllocation = item.positionAllocation
                let hasEligibleLongPosition = item.supportsPosition
                    && item.positionQuantity.isFinite
                    && item.positionQuantity > 0
                if hasEligibleLongPosition,
                   !item.positionAllocationNeedsReconciliation,
                   var allocation = archiveAllocation {
                    var archiveItem = item
                    archiveItem.transactions = PositionLedger.replayOrdered(archiveTransactions)
                    let ledger = PositionLedger(transactions: archiveItem.transactions)
                    archiveItem.lots = ledger.hasOpenPosition
                        ? [CostLot(
                            id: WatchlistSyncMerge.derivedLedgerLotID(for: symbol),
                            price: ledger.averageCost,
                            quantity: ledger.quantity
                        )]
                        : []
                    allocation.basisFingerprint = PositionAllocation.basisFingerprint(for: archiveItem)
                    archiveAllocation = allocation
                }
                return WatchlistArchive.Entry(
                    market: symbol.market,
                    code: symbol.code,
                    name: item.displayName,
                    type: item.instrumentType,
                    pinned: pinned.contains(symbol) ? true : nil,
                    // Positions recorded before the ledger existed live only in the
                    // legacy lot cache. Materializing here is what keeps them in the
                    // archive instead of silently exporting a position-less entry.
                    transactions: archiveTransactions.isEmpty ? nil : archiveTransactions,
                    thesis: item.thesis,
                    // Plans are the user's intentions, so they travel with the
                    // reasoning that explains them.
                    plans: item.plans.isEmpty ? nil : TradePlan.ordered(item.plans),
                    drawings: item.drawings.isEmpty ? nil : ChartDrawing.ordered(item.drawings),
                    tradingProfile: item.tradingProfile,
                    events: item.events.isEmpty ? nil : InstrumentEvent.ordered(item.events),
                    positionAllocation: archiveAllocation
                )
            }
            return WatchlistArchive.List(name: group.name, entries: entries)
        }
        return WatchlistArchive(exportedAt: exportedAt, app: app, lists: lists,
            brokerageAccountID: brokerageAccountsEnabled ? activeBrokerageAccountID : nil)
    }

    /// Full-fidelity sync state, including dormant transaction history and all
    /// stable group identifiers, memberships, pins, and orderings.
    public func syncSnapshot() -> WatchlistSyncSnapshot {
        guard brokerageAccountsEnabled else {
            return WatchlistSyncSnapshot(items: allItems, groups: groups, retainedHistoryItems: retainedHistoryItems)
        }
        var portfolios = accountPortfolios
        portfolios[activeBrokerageAccountID] = currentPortfolio()
        let unassigned = portfolios[.unassigned]!
        return WatchlistSyncSnapshot(items: unassigned.items, groups: unassigned.groups,
            retainedHistoryItems: unassigned.retainedHistoryItems,
            brokerageAccounts: BrokerageAccountID.allCases.filter { $0 != .unassigned }.compactMap { portfolios[$0] },
            accountSettings: unassigned.settings)
    }

    /// Replaces synchronized state from a merged peer snapshot. Selection remains
    /// local. Normalization and persistence follow the same path used at startup.
    /// Returns true only when the sync-visible state changed.
    @discardableResult
    public func applySyncSnapshot(_ snapshot: WatchlistSyncSnapshot) -> Bool {
        let previous = syncSnapshot()
        guard previous != snapshot else { return false }

        guard (try? WatchlistSyncWireCodec.encode(deviceID: "apply-check", snapshot: snapshot)) != nil else { return false }
        if brokerageAccountsEnabled || snapshot.brokerageAccounts != nil {
            var full = snapshot
            if full.brokerageAccounts == nil { full.brokerageAccounts = syncSnapshot().brokerageAccounts }
            // Older peers/backups did not carry account settings. Preserve known
            // settings; an explicit empty settings object remains a real clear.
            if full.accountSettings == nil { full.accountSettings = previous.accountSettings }
            for index in full.brokerageAccounts?.indices ?? 0..<0 {
                if full.brokerageAccounts?[index].settings == nil,
                   let id = full.brokerageAccounts?[index].accountID {
                    full.brokerageAccounts?[index].settings = brokerageSettings(for: id)
                }
            }
            checkpointAccount()
            installAccountSnapshot(full, selecting: activeBrokerageAccountID)
        } else {
            allItems = snapshot.items
            groups = snapshot.groups
            retainedHistoryItems = snapshot.retainedHistoryItems
            normalizeLoadedState()
        }
        // Applying a peer snapshot is not a local edit, so it must not schedule
        // a write back out to the sync folder on its own.
        save(syncRelevant: false)
        return previous != syncSnapshot()
    }

    /// A user-confirmed backup restore is a local edit, so it also propagates to
    /// configured sync peers. Callers must save the current snapshot beforehand.
    @discardableResult
    public func restoreBackup(_ snapshot: WatchlistSyncSnapshot) throws -> Bool {
        try LocalBackupStore.validateSnapshot(snapshot)
        // Validate the complete envelope before changing any in-memory state.
        _ = try WatchlistSyncWireCodec.encode(deviceID: "backup-restore", snapshot: snapshot)
        var restored = snapshot
        if (brokerageAccountsEnabled || hasUnreadableBrokerageData) && restored.brokerageAccounts == nil {
            restored.brokerageAccounts = BrokerageAccountID.allCases.filter { $0 != .unassigned }.map(emptyPortfolio)
        }
        let changed = applySyncSnapshot(restored)
        if restored.brokerageAccounts != nil { hasUnreadableBrokerageData = false }
        if changed { onLocalSyncChange?(syncSnapshot()) }
        return changed
    }

    /// What importing `archive` would do, entry by entry, without writing anything.
    /// The settings screen shows this before asking for confirmation so the user can
    /// see the instruments Pulse understood rather than the text they pasted.
    public func importPlan(for archive: WatchlistArchive) -> WatchlistArchive.ImportPlan {
        // Account tags are explicit even when they name `.unassigned`. Refuse
        // a different destination regardless of whether accounts are enabled;
        // only untagged archives use whichever account is currently selected.
        if let archiveAccountID = archive.brokerageAccountID,
           archiveAccountID != activeBrokerageAccountID {
            return WatchlistArchive.ImportPlan(
                lists: [],
                rejectionReason: .accountMismatch(
                    archiveAccountID: archiveAccountID,
                    destinationAccountID: activeBrokerageAccountID
                )
            )
        }
        var listPlans: [WatchlistArchive.ImportPlan.ListPlan] = []
        var itemID = 0
        var originalDrawingsBySymbol: [SymbolID: [ChartDrawing]] = [:]
        var plannedDrawingsBySymbol: [SymbolID: [ChartDrawing]] = [:]
        var plannedEventsBySymbol: [SymbolID: [InstrumentEvent]] = [:]
        var metadataChangedSymbols = Set<SymbolID>()

        for (listIndex, list) in archive.lists.enumerated() {
            let name = normalizedName(list.name)
            let existing = groups.first { $0.name == name }
            // Membership accumulates while planning so a list that repeats a symbol
            // reports the second mention as already present rather than a second add.
            var plannedSymbols = Set(existing?.symbols ?? [])

            var items: [WatchlistArchive.ImportPlan.Item] = []
            for entry in list.entries {
                itemID += 1
                let resolution = entry.resolution
                let outcome: WatchlistArchive.ImportPlan.Outcome
                switch resolution {
                case .unknownMarket, .missingCode:
                    outcome = .skipped(resolution)
                case .resolved(let symbol):
                    if !name.isEmpty {
                        let current = item(for: symbol) ?? retainedHistoryItem(for: symbol)
                        if originalDrawingsBySymbol[symbol] == nil {
                            let existing = current?.drawings ?? []
                            originalDrawingsBySymbol[symbol] = existing
                            plannedDrawingsBySymbol[symbol] = existing
                        }
                        plannedDrawingsBySymbol[symbol] = ChartDrawingMerge.merge(
                            base: [],
                            local: plannedDrawingsBySymbol[symbol] ?? [],
                            remote: entry.drawings ?? []
                        )
                        if Self.fillingMissingTradingProfile(current?.tradingProfile, from: entry.tradingProfile)
                            != current?.tradingProfile {
                            metadataChangedSymbols.insert(symbol)
                        }
                        let currentEvents = plannedEventsBySymbol[symbol] ?? current?.events ?? []
                        let mergedEvents = InstrumentEventMerge.merge(
                            base: [], local: currentEvents, remote: entry.events ?? []
                        )
                        if mergedEvents != currentEvents { metadataChangedSymbols.insert(symbol) }
                        plannedEventsBySymbol[symbol] = mergedEvents
                        if current?.positionAllocation == nil, entry.positionAllocation != nil {
                            metadataChangedSymbols.insert(symbol)
                        }
                    }
                    if plannedSymbols.contains(symbol) {
                        let hasEmptyLedger = item(for: symbol)?.materializedTransactions().isEmpty ?? false
                        let bringsTrades = !(entry.transactions ?? []).isEmpty
                        outcome = hasEmptyLedger && bringsTrades
                            ? .restorePosition(symbol)
                            : .alreadyInList(symbol)
                    } else {
                        plannedSymbols.insert(symbol)
                        outcome = .add(symbol)
                    }
                }
                items.append(.init(id: itemID, entry: entry, outcome: outcome))
            }

            listPlans.append(.init(
                id: listIndex,
                name: name.isEmpty ? list.name : name,
                isNew: existing == nil && !name.isEmpty,
                items: items
            ))
        }

        let drawingCount = originalDrawingsBySymbol.reduce(into: 0) { count, entry in
            count += ChartDrawingMerge.changedCount(
                local: entry.value,
                incoming: plannedDrawingsBySymbol[entry.key] ?? []
            )
        }
        return WatchlistArchive.ImportPlan(
            lists: listPlans,
            drawingCount: drawingCount,
            metadataCount: metadataChangedSymbols.count
        )
    }

    /// Adds everything in `archive` that is missing. Import is deliberately additive:
    /// it never removes a list, a symbol, or a trade, so importing a stale backup
    /// cannot destroy newer work and re-importing the same archive is a no-op.
    ///
    /// A symbol already on the watchlist keeps its saved name, and an instrument that
    /// already has trades keeps them — the archive only fills positions that are empty.
    /// An entry Pulse cannot resolve is skipped on its own; it never fails the import.
    @discardableResult
    public func merge(_ archive: WatchlistArchive) -> WatchlistArchive.ImportPlan {
        let plan = importPlan(for: archive)
        // The plan already decided whether this archive may be applied at all,
        // so a refusal returns that same plan untouched: no mutation, no
        // persistence, and no sync callback.
        guard plan.rejectionReason == nil else { return plan }

        for (list, listPlan) in zip(archive.lists, plan.lists) {
            let name = normalizedName(list.name)
            guard !name.isEmpty else { continue }

            let groupIndex: Int
            if let existing = groups.firstIndex(where: { $0.name == name }) {
                groupIndex = existing
            } else {
                groups.append(WatchlistGroup(name: name))
                groupIndex = groups.count - 1
            }

            var appended: [SymbolID] = []
            for planItem in listPlan.items {
                guard let symbol = planItem.symbol else { continue }
                let entry = planItem.entry
                let archivedTransactions = entry.transactions ?? []
                restoreRetainedHistory(for: symbol)

                if let itemIndex = allItems.firstIndex(where: { $0.symbol == symbol }) {
                    // Only an empty position adopts the archive's trades; a live
                    // ledger is never overwritten by an import.
                    // A legacy lot-only position is a real position: it must not read as
                    // an empty ledger the archive is free to fill.
                    if allItems[itemIndex].materializedTransactions().isEmpty,
                       !archivedTransactions.isEmpty {
                        applyTransactions(archivedTransactions, at: itemIndex)
                    } else {
                        // An archive may carry a newer review for an existing
                        // trade. Fill missing metadata by identity without
                        // replacing local trade values or existing notes.
                        for archived in archivedTransactions {
                            guard let transactionIndex = allItems[itemIndex].transactions
                                .firstIndex(where: { $0.id == archived.id }) else { continue }
                            allItems[itemIndex].transactions[transactionIndex] = Self.preservingTransactionMetadata(
                                allItems[itemIndex].transactions[transactionIndex],
                                from: archived
                            )
                        }
                    }
                    // An archive fills a thesis the local copy never had, but it
                    // does not overwrite one the user has already written —
                    // same rule the trades follow above.
                    if allItems[itemIndex].thesis == nil, let archivedThesis = entry.thesis {
                        allItems[itemIndex].thesis = archivedThesis
                    }
                    allItems[itemIndex].tradingProfile = Self.fillingMissingTradingProfile(
                        allItems[itemIndex].tradingProfile,
                        from: entry.tradingProfile
                    )
                    if let archivedEvents = entry.events, !archivedEvents.isEmpty {
                        allItems[itemIndex].events = InstrumentEventMerge.merge(
                            base: [],
                            local: allItems[itemIndex].events,
                            remote: archivedEvents
                        )
                    }
                    if allItems[itemIndex].positionAllocation == nil {
                        allItems[itemIndex].positionAllocation = entry.positionAllocation
                    }
                    // Same rule again for plans: only an instrument with no
                    // plans at all adopts the archive's, so a stale backup
                    // cannot replace a plan the user has since rewritten.
                    if allItems[itemIndex].plans.isEmpty, let archivedPlans = entry.plans,
                       !archivedPlans.isEmpty {
                        allItems[itemIndex].plans = TradePlan.ordered(archivedPlans)
                    }
                    if let archivedDrawings = entry.drawings, !archivedDrawings.isEmpty {
                        allItems[itemIndex].drawings = ChartDrawingMerge.merge(
                            base: [],
                            local: allItems[itemIndex].drawings,
                            remote: archivedDrawings
                        )
                    }
                } else {
                    let archivedName = entry.name?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    allItems.append(WatchItem(
                        symbol: symbol,
                        // An entry without a name keeps the code as a placeholder and
                        // no provenance, which is exactly the state the existing
                        // display-name upgrade path repairs on the first refresh.
                        displayName: archivedName.isEmpty ? symbol.displayCode : archivedName,
                        displayNameSource: nil,
                        instrumentType: entry.type,
                        thesis: entry.thesis,
                        plans: TradePlan.ordered(entry.plans ?? []),
                        drawings: ChartDrawing.ordered(entry.drawings ?? []),
                        tradingProfile: entry.tradingProfile,
                        events: InstrumentEvent.ordered(entry.events ?? []),
                        positionAllocation: entry.positionAllocation
                    ))
                    if !archivedTransactions.isEmpty {
                        applyTransactions(archivedTransactions, at: allItems.count - 1)
                    }
                }

                if case .add = planItem.outcome, !groups[groupIndex].symbols.contains(symbol) {
                    appended.append(symbol)
                }
                if entry.pinned == true, !groups[groupIndex].pinnedSymbols.contains(symbol) {
                    groups[groupIndex].pinnedSymbols.append(symbol)
                }
            }

            // Appending preserves the archive's own order. `add(_:to:)` inserts at the
            // top, which would silently reverse an imported list.
            groups[groupIndex].symbols.append(contentsOf: appended)
            if groups[groupIndex].manualOrder != nil {
                groups[groupIndex].manualOrder?.append(contentsOf: appended)
            }
        }

        normalizeLoadedState()
        if group(for: selectedGroupID) == nil {
            selectedGroupID = groups.first?.id
        }
        save()
        return plan
    }

    private struct Snapshot: Codable {
        var items: [WatchItem]
        var groups: [WatchlistGroup]
        var selectedGroupID: UUID?
        /// Optional so snapshots written before removed-history retention still decode.
        var retainedHistoryItems: [WatchItem]?
    }

    private struct AccountStored: Codable {
        var version: Int = 1
        var snapshot: WatchlistSyncSnapshot
        var activeAccountID: BrokerageAccountID
        var selectedGroupIDs: [String: UUID]
    }

    private func load() {
        if let data = defaults.data(forKey: accountStorageKey) {
            if let stored = try? JSONDecoder().decode(AccountStored.self, from: data), (1...2).contains(stored.version),
               stored.snapshot.brokerageAccounts != nil,
               (try? WatchlistSyncWireCodec.encode(deviceID: "load-check", snapshot: stored.snapshot)) != nil {
                accountGroupSelections = stored.selectedGroupIDs
                installAccountSnapshot(stored.snapshot, selecting: stored.activeAccountID)
                return
            }
            hasUnreadableBrokerageData = true
        }
        let currentSnapshot = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode(Snapshot.self, from: $0)
        }
        let previousSnapshot = defaults.data(forKey: previousStorageKey).flatMap {
            try? JSONDecoder().decode(Snapshot.self, from: $0)
        }
        if let snapshot = currentSnapshot ?? previousSnapshot {
            allItems = snapshot.items
            groups = snapshot.groups
            selectedGroupID = snapshot.selectedGroupID
            retainedHistoryItems = snapshot.retainedHistoryItems ?? []
            normalizeLoadedState()
            save(syncRelevant: false)
            return
        }
        migrateLegacyState()
    }

    private func migrateLegacyState() {
        if let data = defaults.data(forKey: legacyStorageKey),
           let decoded = try? JSONDecoder().decode([WatchItem].self, from: data) {
            allItems = decoded
        }
        let symbols = allItems.map(\.symbol).uniqued()
        var manualOrder: [SymbolID]?
        if let data = defaults.data(forKey: legacyManualOrderKey),
           let decoded = try? JSONDecoder().decode([SymbolID].self, from: data) {
            let known = Set(symbols)
            let ordered = decoded.filter { known.contains($0) }.uniqued()
            let orderedSet = Set(ordered)
            manualOrder = ordered + symbols.filter { !orderedSet.contains($0) }

            // Keep the legacy payload readable by the immediately preceding app version.
            if let encoded = try? JSONEncoder().encode(manualOrder) {
                defaults.set(encoded, forKey: legacyManualOrderKey)
            }
        }
        let group = WatchlistGroup(name: initialGroupName, symbols: symbols, manualOrder: manualOrder)
        groups = [group]
        selectedGroupID = group.id

        // Re-encoding also advances legacy crypto identifiers before v2 takes ownership.
        if let encoded = try? JSONEncoder().encode(allItems) {
            defaults.set(encoded, forKey: legacyStorageKey)
        }
        save(syncRelevant: false)
    }

    private func normalizeLoadedState() {
        // Provider-specific legacy index aliases can now decode to the same
        // canonical SymbolID. Merge them instead of dropping the later entry and
        // silently losing any position lots attached to it.
        let activeSymbols = Set(allItems.map(\.symbol))
        let normalizedStoredItems = normalizedItems(allItems + retainedHistoryItems)
        allItems = normalizedStoredItems.filter { activeSymbols.contains($0.symbol) }
            retainedHistoryItems = normalizedStoredItems.filter {
            !activeSymbols.contains($0.symbol)
                && (!$0.materializedTransactions().isEmpty || !$0.drawings.isEmpty
                    || $0.tradingProfile != nil || !$0.events.isEmpty || $0.positionAllocation != nil
                    || $0.thesis != nil || !$0.plans.isEmpty)
        }

        if groups.isEmpty {
            groups = [WatchlistGroup(name: initialGroupName, symbols: allItems.map(\.symbol))]
        }

        let known = Set(allItems.map(\.symbol))
        for index in groups.indices {
            groups[index].name = normalizedName(groups[index].name)
            if groups[index].name.isEmpty { groups[index].name = initialGroupName }
            groups[index].symbols = groups[index].symbols.filter { known.contains($0) }.uniqued()
            if let manualOrder = groups[index].manualOrder {
                groups[index].manualOrder = manualOrder.filter { known.contains($0) }.uniqued()
            }
            let members = Set(groups[index].symbols)
            groups[index].pinnedSymbols = groups[index].pinnedSymbols
                .filter { members.contains($0) }
                .uniqued()
        }

        let assigned = Set(groups.flatMap(\.symbols))
        for symbol in allItems.map(\.symbol) where !assigned.contains(symbol) {
            groups[0].symbols.append(symbol)
        }
        if group(for: selectedGroupID) == nil {
            selectedGroupID = groups[0].id
        }
    }

    private func normalizedItems(_ storedItems: [WatchItem]) -> [WatchItem] {
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
                profile.sector = Self.nonemptyText(profile.sector)
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
                        transactions[index] = Self.preservingTransactionMetadata(
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
        return normalizedItems.map(Self.migratingRetiredObservationState)
    }

    /// Rewrites the retired observation purpose on one normalized item.
    ///
    /// Only the current state moves: the live portions and the plans the user
    /// can still edit. Historical material — each allocation change's
    /// before/after snapshots, a plan's revisions, and a transaction's immutable
    /// `planExecution` snapshot — is left exactly as written, because those
    /// record what was true at the time and rewriting them would fabricate a
    /// past that never happened.
    ///
    /// An item with nothing to migrate is returned unchanged, so calling this on
    /// every load is a cheap identity for the overwhelming majority of items and
    /// makes the migration idempotent: a second pass finds no observation
    /// purpose left to move and adds no second condition.
    nonisolated private static func migratingRetiredObservationState(_ item: WatchItem) -> WatchItem {
        var migrated = item
        if item.plans.contains(where: { $0.positionPool == .observation }) {
            migrated.plans = item.plans.map { migratedPlan($0) }
        }
        if let allocation = item.positionAllocation,
           allocation.portions.contains(where: { $0.pool == .observation }) {
            migrated.positionAllocation = migratedAllocation(allocation)
        }
        return migrated
    }

    private func save(syncRelevant: Bool = true) {
        if brokerageAccountsEnabled {
            checkpointAccount()
            let snapshot = syncSnapshot()
            guard (try? WatchlistSyncWireCodec.encode(deviceID: "save-check", snapshot: snapshot)) != nil,
                  let data = try? JSONEncoder().encode(AccountStored(version: snapshot.hasAccountSettings ? 2 : 1, snapshot: snapshot,
                    activeAccountID: activeBrokerageAccountID, selectedGroupIDs: accountGroupSelections)) else { return }
            guard defaults.data(forKey: accountStorageKey) != data else { return }
            defaults.set(data, forKey: accountStorageKey)
            if syncRelevant { onLocalSyncChange?(snapshot) }
            return
        }
        let snapshot = Snapshot(
            items: allItems,
            groups: groups,
            selectedGroupID: selectedGroupID,
            retainedHistoryItems: retainedHistoryItems
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        guard defaults.data(forKey: storageKey) != data else { return }
        defaults.set(data, forKey: storageKey)
        if syncRelevant {
            onLocalSyncChange?(syncSnapshot())
        }
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
    private static func preservingTransactionMetadata(
        _ preferred: PositionTransaction,
        from fallback: PositionTransaction
    ) -> PositionTransaction {
        var result = preferred
        if result.note == nil { result.note = fallback.note }
        if result.planExecution == nil { result.planExecution = fallback.planExecution }
        if result.fundingSource == nil { result.fundingSource = fallback.fundingSource }
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

    /// Keeps removed ledger and drawing data outside the active watchlist so it neither renders nor refreshes.
    private func retainHistoryIfNeeded(from item: WatchItem) {
        guard !item.materializedTransactions().isEmpty || !item.drawings.isEmpty
                || item.tradingProfile != nil || !item.events.isEmpty || item.positionAllocation != nil
                || item.thesis != nil || !item.plans.isEmpty else { return }
        retainedHistoryItems = normalizedItems(retainedHistoryItems + [item])
    }

    /// Rehydrates the original item before normal add/update logic refreshes its metadata.
    private func restoreRetainedHistory(for symbol: SymbolID) {
        guard allItems.allSatisfy({ $0.symbol != symbol }),
              let index = retainedHistoryItems.firstIndex(where: { $0.symbol == symbol }) else {
            return
        }
        allItems.append(retainedHistoryItems.remove(at: index))
    }

    /// Rebuilds the hidden custom-order baseline from a visible pinned-first order.
    /// Pinned symbols keep their baseline slots; regular symbols adopt their visible
    /// relative order. With no pins, the visible order is the baseline directly.
    private func manualOrderPreservingPinnedPositions(
        visibleOrder: [SymbolID],
        pinned: Set<SymbolID>,
        storedOrder: [SymbolID]?
    ) -> [SymbolID] {
        guard !pinned.isEmpty else { return visibleOrder }

        let visibleSet = Set(visibleOrder)
        let stored = (storedOrder ?? visibleOrder)
            .filter { visibleSet.contains($0) }
            .uniqued()
        let storedSet = Set(stored)
        let baselineOrder = stored + visibleOrder.filter { !storedSet.contains($0) }
        let visibleUnpinned = visibleOrder.filter { !pinned.contains($0) }
        var unpinnedIndex = 0
        var updatedBaseline: [SymbolID] = []
        updatedBaseline.reserveCapacity(baselineOrder.count)

        for symbol in baselineOrder {
            if pinned.contains(symbol) {
                updatedBaseline.append(symbol)
            } else if unpinnedIndex < visibleUnpinned.count {
                updatedBaseline.append(visibleUnpinned[unpinnedIndex])
                unpinnedIndex += 1
            }
        }
        return updatedBaseline.uniqued()
    }

    /// New members lead the regular section without displacing pinned symbols.
    /// Keep the hidden custom-order baseline in sync so restoring or unpinning
    /// cannot send a newly added symbol back to the bottom.
    private func insertAtTopOfUnpinned(_ symbol: SymbolID, inGroupAt groupIndex: Int) {
        var updatedGroup = groups[groupIndex]
        let pinned = Set(updatedGroup.pinnedSymbols)
        let existingSymbols = updatedGroup.symbols
        let visiblePinned = existingSymbols.filter { pinned.contains($0) }
        let visibleUnpinned = existingSymbols.filter { !pinned.contains($0) }
        updatedGroup.symbols = visiblePinned + [symbol] + visibleUnpinned

        if let storedOrder = updatedGroup.manualOrder {
            let existingSet = Set(existingSymbols)
            let normalizedOrder = storedOrder
                .filter { existingSet.contains($0) }
                .uniqued()
            let normalizedSet = Set(normalizedOrder)
            var manualOrder = normalizedOrder + existingSymbols.filter {
                !normalizedSet.contains($0)
            }
            let baselineInsertionIndex = manualOrder.firstIndex {
                !pinned.contains($0)
            } ?? manualOrder.endIndex
            manualOrder.insert(symbol, at: baselineInsertionIndex)
            updatedGroup.manualOrder = manualOrder.uniqued()
        }

        groups[groupIndex] = updatedGroup
    }

    private func normalizedName(_ rawName: String) -> String {
        String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
    }

    private func hasGroup(named name: String, excluding excludedID: UUID? = nil) -> Bool {
        groups.contains {
            $0.id != excludedID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func shouldAcceptDisplayName(
        _ candidate: DisplayNameSource,
        over current: DisplayNameSource?
    ) -> Bool {
        guard let current else { return true }
        return candidate.priority < current.priority
    }

    private func shouldAcceptInstrumentType(
        _ candidate: InstrumentType?,
        over current: InstrumentType?
    ) -> Bool {
        guard let candidate, candidate != .other else { return false }
        return current == nil || current == .other
    }

    private static var localizedDefaultGroupName: String {
        let key = "watchlist.defaultName"
        let localized = PulseLocalization.localizedString(key)
        guard localized == key else { return localized }
        return PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? "自选" : "Watchlist"
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
