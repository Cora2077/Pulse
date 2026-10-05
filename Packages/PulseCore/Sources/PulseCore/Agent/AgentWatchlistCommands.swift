import Foundation

@MainActor
public struct AgentWatchlistCommands {
    private let accountID: BrokerageAccountID?
    private let store: WatchlistStore
    private let market: MarketStore?
    private let searcher: (any AgentSymbolSearching)?

    public init(
        store: WatchlistStore,
        market: MarketStore? = nil,
        searcher: (any AgentSymbolSearching)? = nil,
        accountID: BrokerageAccountID? = nil
    ) {
        self.accountID = accountID
        self.store = store
        self.market = market
        self.searcher = searcher
    }

    public var brokerageAccountsEnabled: Bool { store.brokerageAccountsEnabled }

    public func scoped(to accountID: BrokerageAccountID) -> AgentWatchlistCommands {
        AgentWatchlistCommands(store: store, market: market, searcher: searcher, accountID: accountID)
    }

    public func listBrokerageAccounts() -> [AgentBrokerageAccountInfo] {
        let ids: [BrokerageAccountID] = store.brokerageAccountsEnabled ? BrokerageAccountID.allCases : [.unassigned]
        return ids.map { id in
            let portfolio = store.brokeragePortfolio(for: id)
            return AgentBrokerageAccountInfo(accountID: id, isCurrent: store.activeBrokerageAccountID == id,
                holdingsCount: portfolio.items.filter(\.hasPosition).count,
                transactionCount: (portfolio.items + portfolio.retainedHistoryItems).reduce(0) { $0 + $1.transactions.count })
        }
    }

    private func withAccount<T>(_ operation: () -> T) -> T {
        store.withBrokerageAccount(accountID ?? store.activeBrokerageAccountID, operation)
    }

    public func listWatchlists() -> AgentWatchlistSnapshot {
        return withAccount {
            AgentWatchlistSnapshot(groups: store.groups.map(groupSnapshot))
        }
    }

    public func listPositions() -> [AgentPositionSnapshot] {
        return withAccount {
            store.allItems
                .filter(\.hasPositionHistory)
                .map(positionSnapshot)
        }
    }

    public func quotes(for symbols: [AgentSymbolRef]) -> [AgentQuoteSnapshot] {
        guard let market else { return [] }
        return symbols.compactMap { ref in
            guard let symbol = symbol(from: ref), let quote = market.quote(for: symbol) else {
                return nil
            }
            return quoteSnapshot(quote)
        }
    }

    public func searchSymbols(
        _ query: String
    ) async -> Result<[AgentInstrument], AgentWatchlistError> {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .success([]) }
        guard let searcher else { return .failure(.searchUnavailable) }
        do {
            return .success(try await searcher.search(query).map(instrument))
        } catch {
            return .failure(.searchFailed(error.localizedDescription))
        }
    }

    public func createGroup(
        named name: String
    ) -> Result<AgentMutation<AgentGroupSnapshot>, AgentWatchlistError> {
        return withAccount {
            let name = normalizedGroupName(name)
            guard !name.isEmpty else { return .failure(.invalidName) }
            guard !store.groups.contains(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                return .failure(.duplicateGroupName(name))
            }

            let before = Set(store.symbols)
            let previousSelection = store.selectedGroupID
            guard let id = store.createGroup(named: name) else {
                return .failure(.invalidName)
            }
            if let previousSelection {
                store.selectGroup(previousSelection)
            }
            guard let group = store.group(for: id) else {
                return .failure(.groupNotFound(id))
            }
            return .success(mutation(
                groupSnapshot(group),
                before: before,
                alreadyApplied: false
            ))
        }
    }

    public func renameGroup(
        _ id: UUID,
        to name: String
    ) -> Result<AgentGroupSnapshot, AgentWatchlistError> {
        return withAccount {
            guard let group = store.group(for: id) else {
                return .failure(.groupNotFound(id))
            }
            let name = normalizedGroupName(name)
            guard !name.isEmpty else { return .failure(.invalidName) }
            guard !store.groups.contains(where: {
                $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                return .failure(.duplicateGroupName(name))
            }
            if group.name != name {
                guard store.renameGroup(id, to: name) else {
                    return .failure(.invalidName)
                }
            }
            guard let renamed = store.group(for: id) else {
                return .failure(.groupNotFound(id))
            }
            return .success(groupSnapshot(renamed))
        }
    }

    public func deleteGroup(
        _ id: UUID
    ) -> Result<AgentMutation<Void>, AgentWatchlistError> {
        return withAccount {
            let before = Set(store.symbols)
            guard store.group(for: id) != nil else {
                return .success(mutation((), before: before, alreadyApplied: true))
            }
            guard store.groups.count > 1 else {
                return .failure(.lastGroupProtected)
            }
            guard store.deleteGroup(id) else {
                return .failure(.groupNotFound(id))
            }
            return .success(mutation((), before: before, alreadyApplied: false))
        }
    }

    /// Sets tag-bar order. `orderedIDs` must list every current group exactly once.
    public func reorderGroups(
        _ orderedIDs: [UUID]
    ) -> Result<AgentMutation<AgentWatchlistSnapshot>, AgentWatchlistError> {
        return withAccount {
            let currentIDs = store.groups.map(\.id)
            guard Set(orderedIDs).count == orderedIDs.count,
                  orderedIDs.count == currentIDs.count,
                  Set(orderedIDs) == Set(currentIDs) else {
                return .failure(.invalidGroupOrder)
            }

            let before = Set(store.symbols)
            let alreadyApplied = orderedIDs == currentIDs
            if !alreadyApplied {
                guard store.reorderGroups(orderedIDs) else {
                    return .failure(.invalidGroupOrder)
                }
            }
            return .success(mutation(
                listWatchlists(),
                before: before,
                alreadyApplied: alreadyApplied
            ))
        }
    }

    /// Sets Custom Order for a group. Pin membership is unchanged; the stored order is
    /// coerced to pinned-first using relative order within each section from `refs`.
    public func reorderSymbols(
        _ refs: [AgentSymbolRef],
        in groupID: UUID
    ) -> Result<AgentMutation<AgentGroupSnapshot>, AgentWatchlistError> {
        return withAccount {
            guard let group = store.group(for: groupID) else {
                return .failure(.groupNotFound(groupID))
            }

            var symbols: [SymbolID] = []
            symbols.reserveCapacity(refs.count)
            var seen = Set<SymbolID>()
            for ref in refs {
                guard let symbol = symbol(from: ref) else {
                    return .failure(.invalidSymbol(ref))
                }
                guard !seen.contains(symbol) else {
                    return .failure(.invalidSymbolOrder)
                }
                seen.insert(symbol)
                symbols.append(symbol)
            }

            guard symbols.count == group.symbols.count,
                  Set(symbols) == Set(group.symbols) else {
                return .failure(.invalidSymbolOrder)
            }

            let pinned = Set(group.pinnedSymbols)
            let pinnedOrdered = symbols.filter { pinned.contains($0) }
            let expectedVisible = pinnedOrdered + symbols.filter { !pinned.contains($0) }
            let alreadyApplied = group.symbols == expectedVisible
                && group.pinnedSymbols == pinnedOrdered

            let before = Set(store.symbols)
            if !alreadyApplied {
                guard store.applyCustomOrder(symbols, in: groupID) else {
                    return .failure(.invalidSymbolOrder)
                }
            }
            guard let updated = store.group(for: groupID) else {
                return .failure(.groupNotFound(groupID))
            }
            return .success(mutation(
                groupSnapshot(updated),
                before: before,
                alreadyApplied: alreadyApplied
            ))
        }
    }

    public func addSymbol(
        _ ref: AgentSymbolRef,
        name: String? = nil,
        type: InstrumentType? = nil,
        to groupID: UUID
    ) -> Result<AgentMutation<AgentInstrument>, AgentWatchlistError> {
        return withAccount {
            guard store.group(for: groupID) != nil else {
                return .failure(.groupNotFound(groupID))
            }
            guard let symbol = symbol(from: ref) else {
                return .failure(.invalidSymbol(ref))
            }

            let before = Set(store.symbols)
            let alreadyApplied = store.contains(symbol, in: groupID)
            let resolvedName = name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? symbol.displayCode
            store.add(
                SymbolInfo(
                    symbol: symbol,
                    name: resolvedName,
                    type: type ?? inferredType(for: symbol)
                ),
                to: groupID
            )
            guard let item = store.item(for: symbol) else {
                return .failure(.symbolNotFound(ref))
            }
            return .success(mutation(
                instrument(item),
                before: before,
                alreadyApplied: alreadyApplied
            ))
        }
    }

    public func removeSymbol(
        _ ref: AgentSymbolRef,
        from groupID: UUID
    ) -> Result<AgentMutation<Void>, AgentWatchlistError> {
        return withAccount {
            guard store.group(for: groupID) != nil else {
                return .failure(.groupNotFound(groupID))
            }
            guard let symbol = symbol(from: ref) else {
                return .failure(.invalidSymbol(ref))
            }
            let before = Set(store.symbols)
            let alreadyApplied = !store.contains(symbol, in: groupID)
            store.setMembership(symbol, in: groupID, included: false)
            return .success(mutation((), before: before, alreadyApplied: alreadyApplied))
        }
    }

    public func recordTrade(
        _ draft: AgentTradeDraft
    ) -> Result<AgentMutation<AgentPositionSnapshot>, AgentWatchlistError> {
        return withAccount {
            guard draft.quantity.isFinite, draft.quantity > 0 else {
                return .failure(.invalidQuantity)
            }
            // A zero price is legitimate on a buy: it is how a share split is
            // bridged (more shares, no money moved). A sell at zero would
            // fabricate a realized loss, so it keeps the positive contract.
            let priceIsValid = draft.price.isFinite
                && (draft.kind == .buy ? draft.price >= 0 : draft.price > 0)
            guard priceIsValid else {
                return .failure(.invalidPrice)
            }
            if let fee = draft.fee, !(fee.isFinite && fee >= 0) {
                return .failure(.invalidPrice)
            }
            guard let symbol = symbol(from: draft.symbol) else {
                return .failure(.invalidSymbol(draft.symbol))
            }
            guard let item = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            guard item.supportsPosition else {
                return .failure(.positionNotSupported)
            }

            let before = Set(store.symbols)
            if let id = draft.id, item.transactions.contains(where: { $0.id == id }) {
                return .success(mutation(
                    positionSnapshot(item),
                    before: before,
                    alreadyApplied: true
                ))
            }
            store.addTransaction(symbol, PositionTransaction(
                id: draft.id ?? UUID(),
                kind: draft.kind.positionKind,
                price: draft.price,
                quantity: draft.quantity,
                date: draft.date,
                fee: draft.fee
            ))
            guard let updated = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            return .success(mutation(
                positionSnapshot(updated),
                before: before,
                alreadyApplied: false
            ))
        }
    }

    /// Rewrites fields on an existing transaction. Omitted parameters keep their
    /// recorded values; the entry's id and insertion timestamp always survive the
    /// edit. `kind` applies only to buy/sell entries — a calibration entry never
    /// becomes a trade.
    /// Records the user's own reason for holding this instrument. Free text;
    /// an empty or whitespace-only string clears it. Routed through the same
    /// store call the UI uses, so an agent edit and a typed one land
    /// identically.
    public func setThesis(
        symbol ref: AgentSymbolRef,
        text: String?
    ) -> Result<AgentMutation<AgentPositionSnapshot>, AgentWatchlistError> {
        return withAccount {
            guard let symbol = symbol(from: ref) else {
                return .failure(.invalidSymbol(ref))
            }
            guard let item = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let incoming = (normalized?.isEmpty ?? true) ? nil : normalized
            let alreadyApplied = item.thesis == incoming
            let before = Set(store.symbols)
            if !alreadyApplied {
                store.setThesis(text, for: symbol)
            }
            guard let updated = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            return .success(mutation(
                positionSnapshot(updated),
                before: before,
                alreadyApplied: alreadyApplied
            ))
        }
    }

    /// Creates or rewrites one trade plan. `kind`, `price`, and `quantity` are
    /// always written; `status` and `note` fall back to what the plan already
    /// carries, so an edit that only moves the price does not silently reset
    /// the rest. Conditions, revision history, and the intended pool likewise
    /// survive an edit the command did not ask for. Supplying `id` for one that
    /// already exists makes a retry idempotent — the same shape `recordTrade`
    /// uses.
    public func setTradePlan(
        symbol ref: AgentSymbolRef,
        id: UUID?,
        kind: AgentTradeKind,
        price: Double,
        quantity: Double,
        status: TradePlan.Status? = nil,
        note: String? = nil
    ) -> Result<AgentMutation<AgentPositionSnapshot>, AgentWatchlistError> {
        return withAccount {
            guard price.isFinite, price > 0 else {
                return .failure(.invalidPrice)
            }
            guard quantity.isFinite, quantity > 0 else {
                return .failure(.invalidQuantity)
            }
            guard let symbol = symbol(from: ref) else {
                return .failure(.invalidSymbol(ref))
            }
            guard let item = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            guard item.supportsPosition else {
                return .failure(.positionNotSupported)
            }

            let existing = id.flatMap { planID in item.plans.first { $0.id == planID } }
            // Absent note keeps what was written; an empty string clears it, the
            // same contract `setThesis` offers.
            let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedNote: String? = trimmedNote.map { $0.isEmpty ? nil : $0 } ?? existing?.note
            let resolvedStatus = status ?? existing?.status ?? .active
            let planKind = kind.planKind

            let alreadyApplied = existing.map {
                $0.kind == planKind
                    && $0.price == price
                    && $0.quantity == quantity
                    && $0.status == resolvedStatus
                    && $0.note == resolvedNote
            } ?? false

            let before = Set(store.symbols)
            if !alreadyApplied {
                // The command only writes the fields it owns. Conditions and history
                // are the store's to carry: it keeps an omitted condition list and
                // always takes the prior history, so an agent edit of price or size
                // cannot quietly erase either.
                store.setTradePlan(
                    TradePlan(
                        id: id ?? UUID(),
                        kind: planKind,
                        price: price,
                        quantity: quantity,
                        status: resolvedStatus,
                        note: resolvedNote,
                        positionPool: existing?.positionPool,
                        conditions: existing?.conditions
                    ),
                    for: symbol
                )
            }
            guard let updated = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            return .success(mutation(
                positionSnapshot(updated),
                before: before,
                alreadyApplied: alreadyApplied
            ))
        }
    }

    public func deleteTradePlan(
        symbol ref: AgentSymbolRef,
        id: UUID
    ) -> Result<AgentMutation<AgentPositionSnapshot>, AgentWatchlistError> {
        return withAccount {
            guard let symbol = symbol(from: ref) else {
                return .failure(.invalidSymbol(ref))
            }
            guard let item = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }

            let before = Set(store.symbols)
            let alreadyApplied = !item.plans.contains { $0.id == id }
            if !alreadyApplied {
                store.deleteTradePlan(id, for: symbol)
            }
            guard let updated = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            return .success(mutation(
                positionSnapshot(updated),
                before: before,
                alreadyApplied: alreadyApplied
            ))
        }
    }

    public func updateTrade(
        symbol ref: AgentSymbolRef,
        id: UUID,
        kind: AgentTradeKind? = nil,
        quantity: Double? = nil,
        price: Double? = nil,
        fee: Double? = nil,
        date: Date? = nil
    ) -> Result<AgentMutation<AgentPositionSnapshot>, AgentWatchlistError> {
        return withAccount {
            guard let symbol = symbol(from: ref) else {
                return .failure(.invalidSymbol(ref))
            }
            guard let item = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            guard let existing = item.transactions.first(where: { $0.id == id }) else {
                return .failure(.transactionNotFound(id))
            }

            var updated = existing
            if existing.kind != .adjustment, let kind {
                updated.kind = kind.positionKind
            }
            if let quantity { updated.quantity = quantity }
            if let price { updated.price = price }
            if let fee { updated.fee = fee }
            if let date { updated.date = date }

            if let fee = updated.fee, !(fee.isFinite && fee >= 0) {
                return .failure(.invalidPrice)
            }
            switch updated.kind {
            case .buy, .sell:
                guard updated.quantity.isFinite, updated.quantity > 0 else {
                    return .failure(.invalidQuantity)
                }
                // A buy may bridge a share split at a zero price; a sell at zero
                // would fabricate a realized loss.
                let priceIsValid = updated.price.isFinite
                    && (updated.kind == .buy ? updated.price >= 0 : updated.price > 0)
                guard priceIsValid else {
                    return .failure(.invalidPrice)
                }
            case .adjustment:
                guard updated.quantity.isFinite else {
                    return .failure(.invalidQuantity)
                }
                guard updated.price.isFinite, updated.price >= 0 else {
                    return .failure(.invalidPrice)
                }
            }

            let before = Set(store.symbols)
            let alreadyApplied = updated == existing
            if !alreadyApplied {
                store.updateTransaction(symbol, updated)
            }
            guard let updatedItem = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            return .success(mutation(
                positionSnapshot(updatedItem),
                before: before,
                alreadyApplied: alreadyApplied
            ))
        }
    }

    public func deleteTrade(
        symbol ref: AgentSymbolRef,
        id: UUID
    ) -> Result<AgentMutation<AgentPositionSnapshot>, AgentWatchlistError> {
        return withAccount {
            guard let symbol = symbol(from: ref) else {
                return .failure(.invalidSymbol(ref))
            }
            guard let item = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }

            let before = Set(store.symbols)
            let alreadyApplied = !item.transactions.contains(where: { $0.id == id })
            if !alreadyApplied {
                store.deleteTransaction(symbol, id: id)
            }
            guard let updated = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            return .success(mutation(
                positionSnapshot(updated),
                before: before,
                alreadyApplied: alreadyApplied
            ))
        }
    }

    public func calibratePosition(
        symbol ref: AgentSymbolRef,
        quantity: Double,
        averageCost: Double,
        date: Date,
        id: UUID?
    ) -> Result<AgentMutation<AgentPositionSnapshot>, AgentWatchlistError> {
        return withAccount {
            guard quantity.isFinite else {
                return .failure(.invalidQuantity)
            }
            guard averageCost.isFinite, averageCost >= 0 else {
                return .failure(.invalidPrice)
            }
            guard let symbol = symbol(from: ref) else {
                return .failure(.invalidSymbol(ref))
            }
            guard let item = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            guard item.supportsPosition else {
                return .failure(.positionNotSupported)
            }

            let before = Set(store.symbols)
            if let id, item.transactions.contains(where: { $0.id == id }) {
                return .success(mutation(
                    positionSnapshot(item),
                    before: before,
                    alreadyApplied: true
                ))
            }
            store.calibratePosition(
                symbol,
                quantity: quantity,
                averageCost: averageCost,
                date: date,
                id: id ?? UUID()
            )
            guard let updated = store.item(for: symbol) else {
                return .failure(.itemNotOnWatchlist)
            }
            return .success(mutation(
                positionSnapshot(updated),
                before: before,
                alreadyApplied: false
            ))
        }
    }

    private func mutation<Value: Sendable>(
        _ value: Value,
        before: Set<SymbolID>,
        alreadyApplied: Bool
    ) -> AgentMutation<Value> {
        AgentMutation(
            value: value,
            didChangeSymbolUnion: before != Set(store.symbols),
            alreadyApplied: alreadyApplied
        )
    }

    private func groupSnapshot(_ group: WatchlistGroup) -> AgentGroupSnapshot {
        AgentGroupSnapshot(
            id: group.id,
            name: group.name,
            symbols: store.items(in: group.id).map(instrument)
        )
    }

    private func positionSnapshot(_ item: WatchItem) -> AgentPositionSnapshot {
        let quote = market?.quote(for: item.symbol)
        return AgentPositionSnapshot(
            symbol: instrument(item),
            quantity: item.positionQuantity,
            averageCost: item.averageCost,
            costBasis: item.costBasis,
            realizedPnL: item.realizedPnL,
            transactions: item.transactions.map(transactionSnapshot),
            quote: quote.map(quoteSnapshot),
            thesis: item.thesis,
            plans: item.plans.map { planSnapshot($0, quote: quote, transactions: item.transactions) },
            tradingProfile: item.tradingProfile,
            events: item.events,
            positionAllocation: item.positionAllocation
        )
    }

    private func planSnapshot(
        _ plan: TradePlan,
        quote: Quote?,
        transactions: [PositionTransaction]
    ) -> AgentTradePlan {
        let progress = TradePlanExecutionProgress(plan: plan, transactions: transactions)
        return AgentTradePlan(
            id: plan.id,
            kind: plan.kind.rawValue,
            price: plan.price,
            quantity: plan.quantity,
            status: plan.status.rawValue,
            note: plan.note,
            reached: quote.map { plan.isReached(at: $0.price) },
            createdAt: plan.createdAt,
            updatedAt: plan.updatedAt,
            conditions: plan.conditions,
            history: plan.history,
            fillQuantity: progress.filledQuantity,
            remainingQuantity: progress.remainingQuantity
        )
    }

    private func instrument(_ item: WatchItem) -> AgentInstrument {
        AgentInstrument(
            market: item.symbol.market.rawValue,
            code: item.symbol.code,
            displayCode: item.symbol.displayCode,
            name: item.resolvedDisplayName,
            type: item.resolvedInstrumentType?.rawValue,
            supportsPosition: item.supportsPosition
        )
    }

    private func instrument(_ info: SymbolInfo) -> AgentInstrument {
        instrument(WatchItem(
            symbol: info.symbol,
            displayName: info.resolvedDisplayName,
            displayNameSource: info.displayNameSource,
            instrumentType: info.type
        ))
    }

    private func transactionSnapshot(_ transaction: PositionTransaction) -> AgentTransaction {
        AgentTransaction(
            id: transaction.id,
            kind: transaction.kind.rawValue,
            price: transaction.price,
            quantity: transaction.quantity,
            date: formattedDay(transaction.date),
            fee: transaction.fee,
            note: transaction.note,
            review: transaction.review,
            planExecution: transaction.planExecution
        )
    }

    private func quoteSnapshot(_ quote: Quote) -> AgentQuoteSnapshot {
        AgentQuoteSnapshot(
            price: quote.price,
            previousClose: quote.previousClose,
            changePercent: quote.changePercent,
            currencyCode: quote.currencyCode,
            timestamp: quote.timestamp,
            marketState: quote.marketState?.rawValue
        )
    }

    private func symbol(from ref: AgentSymbolRef) -> SymbolID? {
        let rawMarket = ref.market.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code = ref.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let market = Market(rawValue: rawMarket), !code.isEmpty else {
            return nil
        }
        return SymbolID(market: market, code: code)
    }

    private func inferredType(for symbol: SymbolID) -> InstrumentType {
        if symbol.indexID != nil { return .index }
        if symbol.metalID != nil { return .commodity }
        if symbol.cryptoPair != nil { return .crypto }
        return .equity
    }

    private func normalizedGroupName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
    }

    /// Trade dates are calendar days in the user's own zone — that is how the
    /// app enters and displays them — so they read back in that zone too.
    /// Formatting in UTC shifted every entry east of Greenwich to the previous
    /// day: a trade the user dated September 2 came back as September 1.
    private func formattedDay(_ date: Date) -> String {
        let day = CalendarDay(date, in: .current)
        return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }
}

private extension AgentTradeKind {
    var positionKind: PositionTransaction.Kind {
        switch self {
        case .buy: .buy
        case .sell: .sell
        }
    }

    var planKind: TradePlan.Kind {
        switch self {
        case .buy: .buy
        case .sell: .sell
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

public struct AgentBrokerageAccountInfo: Codable, Sendable, Equatable {
    public var accountID: BrokerageAccountID
    public var isCurrent: Bool
    public var holdingsCount: Int
    public var transactionCount: Int
}
