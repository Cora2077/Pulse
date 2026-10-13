import Foundation

/// Account orchestration is separate from single-ledger record merging. A
/// conflict never chooses an entire device snapshot: only disputed fields or
/// dependency-connected account/symbol ledgers are replaced on resolution.
enum WatchlistAccountSyncMerge {
    typealias Scope = WatchlistSyncMerge.AccountSymbolScope
    typealias SettingKey = WatchlistSyncMerge.AccountSettingKey
    typealias Resolution = WatchlistSyncMerge.ConflictResolution
    typealias MergeResult = WatchlistSyncMerge.Result

    static func merge(base: WatchlistSyncSnapshot, local: WatchlistSyncSnapshot,
                      remote: WatchlistSyncSnapshot) -> MergeResult {
        let named = base.brokerageAccounts != nil || local.brokerageAccounts != nil || remote.brokerageAccounts != nil
        let b = portfolios(base)
        let l = portfolios(local, inheriting: base)
        let r = portfolios(remote, inheriting: base)
        let ids = BrokerageAccountID.allCases.filter { $0 == .unassigned || (named && (b[$0] != nil || l[$0] != nil || r[$0] != nil)) }
        var ledgers: [BrokerageAccountID: MergeResult] = [:]
        var settings: [SettingKey] = []
        for id in ids {
            let bp = b[id] ?? BrokerageAccountPortfolio(accountID: id)
            let lp = l[id] ?? BrokerageAccountPortfolio(accountID: id)
            let rp = r[id] ?? BrokerageAccountPortfolio(accountID: id)
            let bf = ledgerSnapshot(bp), lf = ledgerSnapshot(lp), rf = ledgerSnapshot(rp)
            var result: MergeResult
            if id != .unassigned, lf == rf { result = MergeResult(snapshot: lf, conflicts: []) }
            else if id != .unassigned, lf == bf { result = MergeResult(snapshot: rf, conflicts: []) }
            else if id != .unassigned, rf == bf { result = MergeResult(snapshot: lf, conflicts: []) }
            else { result = WatchlistSyncMerge.mergeFlat(base: bf, local: lf, remote: rf) }
            preserveAnnotations(&result.snapshot, sources: [lf, rf, bf])
            let mergedSettings = mergeSettings(account: id, base: bp.settings,
                local: lp.settings, remote: rp.settings)
            result.snapshot.accountSettings = mergedSettings.value
            settings += mergedSettings.conflicts
            ledgers[id] = result
        }
        var snapshot = assemble(ledgers.mapValues(\.snapshot), named: named)
        var groups = ownershipDependencies(base: b, local: l, remote: r)
        // Independently valid edits can combine into an oversold history. That
        // ledger's related buys/sells must be picked together, not auto-applied.
        if named {
            for (id, portfolio) in portfolios(snapshot) {
                for item in portfolio.items + portfolio.retainedHistoryItems {
                    let prior = itemFor(Scope(accountID: id, symbol: item.symbol), in: b)
                    do {
                        try TradeMutationValidation.validateReplay(previous: prior?.materializedTransactions() ?? [],
                            proposed: item.materializedTransactions(), longOnly: true)
                    } catch {
                        groups.append([Scope(accountID: id, symbol: item.symbol)])
                    }
                }
            }
        }
        // Defensive duplicate detection also covers malformed or copied input.
        var owners: [UUID: Set<Scope>] = [:]
        for (id, portfolio) in portfolios(snapshot) {
            for item in portfolio.items + portfolio.retainedHistoryItems {
                for trade in item.transactions {
                    owners[trade.id, default: []].insert(Scope(accountID: id, symbol: item.symbol))
                }
            }
        }
        groups += owners.values.filter { $0.count > 1 }.map { $0 }
        groups = closeDependencies(groups, inputs: [b, l, r])
        let covered = Set(groups.flatMap { $0 })
        var result = MergeResult(snapshot: snapshot, conflicts: [])
        for id in ids {
            guard let ledger = ledgers[id] else { continue }
            result.conflicts += ledger.conflicts.compactMap { conflict in
                guard !covered.contains(Scope(accountID: id, symbol: conflict.symbol)) else { return nil }
                var value = conflict; value.accountID = id; return value
            }
            result.positionAllocationConflicts += ledger.positionAllocationConflicts.compactMap { conflict in
                guard !covered.contains(Scope(accountID: id, symbol: conflict.symbol)) else { return nil }
                var value = conflict; value.accountID = id; return value
            }
        }
        if !groups.isEmpty || !settings.isEmpty {
            let involved = Set(covered.map(\.accountID)).union(settings.map(\.accountID))
            result.brokerageConflict = .init(accountIDs: ids.filter(involved.contains), local: local, remote: remote,
                dependencyGroups: groups.map { $0.sorted(by: scopeLess) }.sorted { scopeLess($0[0], $1[0]) },
                settingKeys: settings.sorted { "\($0.accountID.rawValue):\($0.field.rawValue):\($0.key)" < "\($1.accountID.rawValue):\($1.field.rawValue):\($1.key)" })
            // A provisional candidate remains unique; it must not be published
            // until the user has selected the listed conflicts.
            applyDependencies(groups, from: l, to: &snapshot)
            result.snapshot = snapshot
        }
        result.ledgerResults = ledgers
        result.mergeBase = base
        return result
    }

    static func resolve(_ result: MergeResult, choosing resolution: Resolution) -> WatchlistSyncSnapshot {
        guard let ledgers = result.ledgerResults else { return WatchlistSyncMerge.resolveFlat(result, choosing: resolution) }
        var snapshot = assemble(ledgers.mapValues { WatchlistSyncMerge.resolveFlat($0, choosing: resolution) },
            named: result.snapshot.brokerageAccounts != nil)
        if let conflict = result.brokerageConflict {
            let selected = portfolios(resolution == .local ? conflict.local : conflict.remote, inheriting: result.mergeBase)
            applyDependencies(conflict.dependencyGroups.map(Set.init), from: selected, to: &snapshot)
            var values = portfolios(snapshot)
            for key in conflict.settingKeys {
                var portfolio = values[key.accountID] ?? BrokerageAccountPortfolio(accountID: key.accountID)
                var settings = portfolio.settings ?? BrokerageAccountSettings()
                selectSetting(key, from: selected[key.accountID]?.settings, into: &settings)
                portfolio.settings = settings
                values[key.accountID] = portfolio
            }
            snapshot = assemble(values.mapValues(\.flatSnapshot), named: snapshot.brokerageAccounts != nil)
        }
        return snapshot
    }

    static func validate(_ snapshot: WatchlistSyncSnapshot, against base: WatchlistSyncSnapshot?) throws {
        _ = try WatchlistSyncWireCodec.encode(deviceID: "merge-validation", snapshot: snapshot)
        _ = try LocalBackupStore.validateSnapshot(snapshot)
        guard snapshot.brokerageAccounts != nil else { return }
        let before = base.map { portfolios($0) } ?? [:]
        for (account, portfolio) in portfolios(snapshot) {
            for item in portfolio.items + portfolio.retainedHistoryItems {
                let old = itemFor(Scope(accountID: account, symbol: item.symbol), in: before)
                try TradeMutationValidation.validateReplay(previous: old?.materializedTransactions() ?? [],
                    proposed: item.materializedTransactions(), longOnly: true)
            }
        }
    }

    private static func portfolios(_ snapshot: WatchlistSyncSnapshot,
                                   inheriting base: WatchlistSyncSnapshot? = nil) -> [BrokerageAccountID: BrokerageAccountPortfolio] {
        var result: [BrokerageAccountID: BrokerageAccountPortfolio] = [:]
        for portfolio in snapshot.brokerageAccounts ?? base?.brokerageAccounts ?? [] { result[portfolio.accountID] = portfolio }
        result[.unassigned] = .init(accountID: .unassigned, items: snapshot.items, groups: snapshot.groups,
            retainedHistoryItems: snapshot.retainedHistoryItems, settings: snapshot.accountSettings ?? base?.accountSettings)
        for id in result.keys where result[id]?.settings == nil {
            result[id]?.settings = base?.brokerageAccounts?.first { $0.accountID == id }?.settings
        }
        return result
    }

    private static func ledgerSnapshot(_ portfolio: BrokerageAccountPortfolio) -> WatchlistSyncSnapshot {
        .init(items: portfolio.items, groups: portfolio.groups, retainedHistoryItems: portfolio.retainedHistoryItems)
    }

    private static func assemble(_ values: [BrokerageAccountID: WatchlistSyncSnapshot], named: Bool) -> WatchlistSyncSnapshot {
        var result = values[.unassigned] ?? WatchlistSyncSnapshot(items: [], groups: [])
        result.brokerageAccounts = named ? BrokerageAccountID.allCases.filter { $0 != .unassigned }.compactMap { id in
            guard let value = values[id] else { return nil }
            return BrokerageAccountPortfolio(accountID: id, items: value.items, groups: value.groups,
                retainedHistoryItems: value.retainedHistoryItems, settings: value.accountSettings)
        } : nil
        return result
    }

    private static func preserveAnnotations(_ snapshot: inout WatchlistSyncSnapshot, sources: [WatchlistSyncSnapshot]) {
        let candidates = sources.flatMap { $0.items + $0.retainedHistoryItems }.flatMap(\.transactions)
        func preserve(_ items: inout [WatchItem]) {
            for index in items.indices {
                for tradeIndex in items[index].transactions.indices {
                    var trade = items[index].transactions[tradeIndex]
                    for old in candidates where old.id == trade.id {
                        if trade.planExecution == nil { trade.planExecution = old.planExecution }
                        else { trade.planExecution = trade.planExecution?.preservingSourceAccount(from: old.planExecution) }
                        if trade.brokerageAccountID == nil { trade.brokerageAccountID = old.brokerageAccountID }
                        if trade.fundingSource == nil { trade.fundingSource = old.fundingSource }
                    }
                    items[index].transactions[tradeIndex] = trade
                }
            }
        }
        preserve(&snapshot.items); preserve(&snapshot.retainedHistoryItems)
    }

    private static func mergeSettings(account: BrokerageAccountID, base: BrokerageAccountSettings?,
                                      local: BrokerageAccountSettings?, remote: BrokerageAccountSettings?)
        -> (value: BrokerageAccountSettings?, conflicts: [SettingKey]) {
        let local = local ?? base, remote = remote ?? base
        if local == remote { return (local, []) }
        if local == base { return (remote, []) }
        if remote == base { return (local, []) }
        guard base != nil || local != nil || remote != nil else { return (nil, []) }
        var conflicts: [SettingKey] = []
        func merge<V: Equatable>(_ b: [String: V], _ l: [String: V], _ r: [String: V], field: SettingKey.Field) -> [String: V] {
            var result: [String: V] = [:]
            for key in Set(b.keys).union(l.keys).union(r.keys).sorted() {
                let value: V?
                if l[key] == r[key] { value = l[key] }
                else if l[key] == b[key] { value = r[key] }
                else if r[key] == b[key] { value = l[key] }
                else { value = l[key]; conflicts.append(.init(accountID: account, field: field, key: key)) }
                result[key] = value
            }
            return result
        }
        func limits(_ value: BrokerageAccountSettings?) -> [String: BrokeragePoolLimit] {
            Dictionary((value?.poolLimits ?? []).map { ("\($0.currency)|\($0.pool.rawValue)", $0) }, uniquingKeysWith: { first, _ in first })
        }
        func scenarios(_ value: BrokerageAccountSettings?) -> [String: BrokeragePoolBudgetScenario] {
            Dictionary((value?.scenarios ?? []).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let pools = merge(limits(base), limits(local), limits(remote), field: .poolLimit)
        let scenarioValues = merge(scenarios(base), scenarios(local), scenarios(remote), field: .scenario)
        let value = BrokerageAccountSettings(
            cashBalances: merge(base?.cashBalances ?? [:], local?.cashBalances ?? [:], remote?.cashBalances ?? [:], field: .cash),
            poolLimits: pools.keys.sorted().compactMap { pools[$0] },
            scenarios: scenarioValues.keys.sorted().compactMap { scenarioValues[$0] },
            sectorLimits: merge(base?.sectorLimits ?? [:], local?.sectorLimits ?? [:], remote?.sectorLimits ?? [:], field: .sector))
        return (value, conflicts)
    }

    private static func selectSetting(_ key: SettingKey, from chosen: BrokerageAccountSettings?, into settings: inout BrokerageAccountSettings) {
        switch key.field {
        case .cash: settings.cashBalances[key.key] = chosen?.cashBalances[key.key]
        case .sector: settings.sectorLimits[key.key] = chosen?.sectorLimits[key.key]
        case .poolLimit:
            settings.poolLimits.removeAll { "\($0.currency)|\($0.pool.rawValue)" == key.key }
            if let value = chosen?.poolLimits.first(where: { "\($0.currency)|\($0.pool.rawValue)" == key.key }) { settings.poolLimits.append(value) }
        case .scenario:
            settings.scenarios.removeAll { $0.id.uuidString == key.key }
            if let value = chosen?.scenarios.first(where: { $0.id.uuidString == key.key }) { settings.scenarios.append(value) }
        }
    }

    private struct LocatedTrade: Equatable { var scope: Scope; var trade: PositionTransaction }
    private struct LocatedPlan: Equatable { var scope: Scope; var plan: TradePlan }

    private static func ownershipDependencies(base: [BrokerageAccountID: BrokerageAccountPortfolio],
                                              local: [BrokerageAccountID: BrokerageAccountPortfolio],
                                              remote: [BrokerageAccountID: BrokerageAccountPortfolio]) -> [Set<Scope>] {
        func trades(_ values: [BrokerageAccountID: BrokerageAccountPortfolio]) -> [UUID: LocatedTrade] {
            var result: [UUID: LocatedTrade] = [:]
            for (account, portfolio) in values {
                for item in portfolio.items + portfolio.retainedHistoryItems {
                    for trade in item.transactions { result[trade.id] = .init(scope: .init(accountID: account, symbol: item.symbol), trade: trade) }
                }
            }
            return result
        }
        let b = trades(base), l = trades(local), r = trades(remote)
        var groups: [Set<Scope>] = []
        for id in Set(b.keys).union(l.keys).union(r.keys) {
            let moved = (b[id] != nil && ((l[id] != nil && l[id]?.scope != b[id]?.scope)
                || (r[id] != nil && r[id]?.scope != b[id]?.scope)))
                || (b[id] == nil && l[id] != nil && r[id] != nil && l[id]?.scope != r[id]?.scope)
            if moved, l[id] != b[id], r[id] != b[id], l[id] != r[id] {
                groups.append(Set([b[id]?.scope, l[id]?.scope, r[id]?.scope].compactMap { $0 }))
            }
        }
        // Plan IDs may legitimately be namesakes in different accounts. Treat a
        // relocation only when the input identity is unambiguous for this symbol.
        func plans(_ values: [BrokerageAccountID: BrokerageAccountPortfolio]) -> [String: [LocatedPlan]] {
            var result: [String: [LocatedPlan]] = [:]
            for (account, portfolio) in values {
                for item in portfolio.items + portfolio.retainedHistoryItems {
                    for plan in item.plans {
                        result["\(item.symbol):\(plan.id)", default: []].append(.init(scope: .init(accountID: account, symbol: item.symbol), plan: plan))
                    }
                }
            }
            return result
        }
        let bp = plans(base), lp = plans(local), rp = plans(remote)
        for key in bp.keys where bp[key]?.count == 1 && (lp[key]?.count ?? 0) <= 1 && (rp[key]?.count ?? 0) <= 1 {
            let bv = bp[key]?.first, lv = lp[key]?.first, rv = rp[key]?.first
            if ((lv != nil && lv?.scope != bv?.scope) || (rv != nil && rv?.scope != bv?.scope)), lv != bv, rv != bv, lv != rv {
                groups.append(Set([bv?.scope, lv?.scope, rv?.scope].compactMap { $0 }))
            }
        }
        return groups
    }

    private static func closeDependencies(_ groups: [Set<Scope>],
                                          inputs: [[BrokerageAccountID: BrokerageAccountPortfolio]]) -> [Set<Scope>] {
        var groups = groups.filter { !$0.isEmpty }
        var changed = true
        while changed {
            changed = false
            for index in groups.indices {
                var additions = groups[index]
                for values in inputs {
                    for (account, portfolio) in values {
                        for item in portfolio.items + portfolio.retainedHistoryItems {
                            let scope = Scope(accountID: account, symbol: item.symbol)
                            for trade in item.transactions {
                                guard let execution = trade.planExecution else { continue }
                                let source = Scope(accountID: BrokerageOwnership.planSourceAccount(for: trade, enclosingAccount: account), symbol: item.symbol)
                                let holder = itemFor(source, in: values)
                                guard holder?.plans.contains(where: { $0.id == execution.planID }) == true else { continue }
                                if additions.contains(source) || additions.contains(scope) {
                                    additions.insert(source); additions.insert(scope)
                                }
                            }
                            for plan in item.plans {
                                guard let id = plan.filledTransactionID else { continue }
                                for (owner, ledger) in values {
                                    if (ledger.items + ledger.retainedHistoryItems).contains(where: {
                                        $0.symbol == item.symbol && $0.transactions.contains(where: { $0.id == id && $0.planExecution == nil })
                                    }) {
                                        let fillScope = Scope(accountID: owner, symbol: item.symbol)
                                        if additions.contains(scope) || additions.contains(fillScope) {
                                            additions.insert(scope); additions.insert(fillScope)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if additions != groups[index] { groups[index] = additions; changed = true }
            }
            var combined: [Set<Scope>] = []
            for group in groups {
                if let index = combined.firstIndex(where: { !$0.isDisjoint(with: group) }) {
                    combined[index].formUnion(group); changed = true
                } else { combined.append(group) }
            }
            groups = combined
        }
        return groups
    }

    private static func itemFor(_ scope: Scope, in values: [BrokerageAccountID: BrokerageAccountPortfolio]) -> WatchItem? {
        let portfolio = values[scope.accountID]
        return portfolio?.items.first { $0.symbol == scope.symbol } ?? portfolio?.retainedHistoryItems.first { $0.symbol == scope.symbol }
    }

    private static func scopeLess(_ lhs: Scope, _ rhs: Scope) -> Bool {
        "\(lhs.accountID.rawValue):\(lhs.symbol)" < "\(rhs.accountID.rawValue):\(rhs.symbol)"
    }

    private static func applyDependencies(_ groups: [Set<Scope>],
                                          from selected: [BrokerageAccountID: BrokerageAccountPortfolio],
                                          to snapshot: inout WatchlistSyncSnapshot) {
        var values = portfolios(snapshot)
        for scope in groups.flatMap({ $0 }).sorted(by: scopeLess) {
            var target = values[scope.accountID] ?? BrokerageAccountPortfolio(accountID: scope.accountID)
            let source = selected[scope.accountID]
            target.items.removeAll { $0.symbol == scope.symbol }
            target.retainedHistoryItems.removeAll { $0.symbol == scope.symbol }
            if let item = source?.items.first(where: { $0.symbol == scope.symbol }) { target.items.append(item) }
            if let item = source?.retainedHistoryItems.first(where: { $0.symbol == scope.symbol }) { target.retainedHistoryItems.append(item) }
            for index in target.groups.indices {
                target.groups[index].symbols.removeAll { $0 == scope.symbol }
                target.groups[index].pinnedSymbols.removeAll { $0 == scope.symbol }
                target.groups[index].manualOrder?.removeAll { $0 == scope.symbol }
            }
            for group in source?.groups ?? [] where group.symbols.contains(scope.symbol) {
                if let index = target.groups.firstIndex(where: { $0.id == group.id || $0.name == group.name }) {
                    target.groups[index].symbols.append(scope.symbol)
                    if group.pinnedSymbols.contains(scope.symbol) { target.groups[index].pinnedSymbols.append(scope.symbol) }
                    if group.manualOrder?.contains(scope.symbol) == true { target.groups[index].manualOrder?.append(scope.symbol) }
                } else {
                    target.groups.append(.init(id: group.id, name: group.name, symbols: [scope.symbol],
                        manualOrder: group.manualOrder.map { $0.filter { $0 == scope.symbol } },
                        pinnedSymbols: group.pinnedSymbols.filter { $0 == scope.symbol }))
                }
            }
            values[scope.accountID] = target
        }
        snapshot = assemble(values.mapValues(\.flatSnapshot), named: snapshot.brokerageAccounts != nil)
    }
}
