import Foundation
import Observation

/// A read-mostly, cross-account view over the financial `WatchlistStore`.
///
/// The financial store stays account scoped: its public arrays always describe
/// the *selected* brokerage account. The shared watchlist answers a different
/// question — "which instruments do I follow across every portfolio?" — so it
/// merges the fixed account order (unassigned, financing, mengmeng) into one
/// presentational surface for shared-UI code, without ever taking ownership of
/// a ledger, a plan, a lot, or an allocation.
///
/// Contract boundaries:
/// - Reads never call `selectBrokerageAccount` or `withBrokerageAccount`. They
///   go through `brokeragePortfolio(for:)`, which is a pure accessor, so a read
///   can never move the user's financial selection or dirty sync state.
/// - Mutations resolve the concrete source group/account *before* touching the
///   store, then scope through `withBrokerageAccount(_:)` and select exactly
///   that source group inside the scope, restoring the same account's prior
///   selected group in `defer`. The financial active account and its selected
///   group are unchanged when the call returns.
/// - Nothing here rewrites transactions, lots, plans, allocations, or account
///   settings. Adding a symbol writes membership metadata only. Removing a
///   symbol removes membership; the core store keeps the retained financial
///   history exactly as it already does.
///
/// Display groups with the same localized-case-insensitive name are merged into
/// one tab. The canonical identifier of a merged group is the id of its first
/// source group in account order, so the UI has one stable identity per name
/// while every underlying membership remains a real group UUID.
@MainActor
@Observable
public final class SharedWatchlist {
    /// The financial store this facade reads through. Never retained by value.
    @ObservationIgnored public let store: WatchlistStore
    /// Explicit local UI preferences. Deliberately separate from the financial
    /// store's storage so shared-UI ordering/selection can never be mistaken for
    /// synchronized watchlist data.
    @ObservationIgnored public let defaults: UserDefaults

    /// Ordered logical groups, merged by localized-case-insensitive name.
    ///
    /// Computed live from the financial store rather than cached: the facade is
    /// an observation-transparent projection, so a UI reading this inside a view
    /// body re-renders exactly when the underlying store changes. Caching would
    /// also make a read observe a stale snapshot after any store mutation.
    public var groups: [WatchlistGroup] { liveGroups() }

    /// Canonical id of the group the shared UI has selected. Selection is the
    /// one piece of shared state this facade genuinely owns.
    private var storedSelectionID: UUID?
    public var selectedGroupID: UUID? {
        let current = groups
        return current.first { $0.id == storedSelectionID }?.id ?? current.first?.id
    }

    @ObservationIgnored private let sharedSelectionKey = "pulse.sharedWatchlist.selectedGroup.v1"
    /// One Codable blob holds all UI-only overrides. Keeping it under a single
    /// new preference key means the facade never touches financial storage.
    @ObservationIgnored private let localPreferencesKey = "pulse.sharedWatchlist.localOrder.v1"

    /// UI-only overrides, keyed by canonical group id. None of this is
    /// financial state and none of it is synchronized.
    private struct LocalPreferences: Codable {
        var groupOrder: [String] = []
        var symbolOrder: [String: [SymbolID]] = [:]
        var manualBaseline: [String: [SymbolID]] = [:]
        /// Resolved pin set for merged groups whose pin state cannot be written
        /// to a single physical source.
        var pinnedSymbols: [String: [SymbolID]] = [:]
    }
    private var local = LocalPreferences()

    public init(store: WatchlistStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
        loadLocalPreferences()
        storedSelectionID = initialSelection()
    }

    // MARK: - Group projection

    /// The accounts this facade reads, in a fixed order. When brokerage accounts
    /// are disabled the financial store has a single live portfolio, so only the
    /// current data is projected.
    private var sourceAccounts: [BrokerageAccountID] {
        store.brokerageAccountsEnabled ? [.unassigned, .financing, .mengmeng] : [.unassigned]
    }

    private func portfolio(for account: BrokerageAccountID) -> BrokerageAccountPortfolio {
        // `brokeragePortfolio(for:)` is a pure accessor: for the active account
        // it returns a value built from the live arrays, for any other account
        // it returns the checkpointed store. Neither path mutates selection.
        store.brokeragePortfolio(for: account)
    }

    /// One source group together with the account that owns it.
    private struct SourceGroup {
        var account: BrokerageAccountID
        var group: WatchlistGroup
    }

    /// All physical source groups, including empty named-account default lists.
    /// Membership resolution and group lifecycle need every concrete group id,
    /// so they read this rather than the filtered projection below.
    private func allSourceGroups() -> [SourceGroup] {
        sourceAccounts.flatMap { account in
            portfolio(for: account).groups.map { SourceGroup(account: account, group: $0) }
        }
    }

    /// The source groups the *projection* is built from.
    ///
    /// A named account's only list is its default list: enabling brokerage
    /// seeds each named account with one empty group carrying the localized
    /// default name. Once the user renames their unassigned list (`跟踪`,
    /// `持仓`, `美股`) those leftovers no longer match a canonical name and
    /// would each surface as a phantom `自选` tab.
    ///
    /// Filtering is decided in `liveGroups()`, which can compare names against
    /// each other. Named-account groups are always offered here so a union of
    /// memberships is never silently truncated.
    private func sourceGroups() -> [SourceGroup] { allSourceGroups() }

    /// Source groups that actually contribute symbols, in fixed account order.
    ///
    /// Ordering delegation and manual-order ownership use this rather than
    /// `resolvedSources`: an empty alias default group is not a real second
    /// contributor, so it must not force merged (UI-only) semantics onto a
    /// group whose only member-bearing source is one physical group.
    private func memberSources(for groupID: UUID?) -> [SourceGroup] {
        guard let canonical = group(for: groupID ?? selectedGroupID) else { return [] }
        let key = Self.normalizedName(canonical.name)
        return resolvedSources(for: canonical.id)
            .filter { Self.normalizedName($0.group.name) == key && !$0.group.symbols.isEmpty }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
    }

    /// Merges source groups by localized-case-insensitive name.
    ///
    /// Symbols and pins merge uniquely and preserve the order in which they are
    /// first seen across accounts. A named account's lone empty default list
    /// whose name matches no unassigned group is dropped before merging, so
    /// leftover `自选` aliases cannot add a duplicate tab.
    private func liveGroups() -> [WatchlistGroup] {
        var orderedKeys: [String] = []
        var canonicalByKey: [String: WatchlistGroup] = [:]
        var emptyAliasKeys = Set<String>()

        // A named account's *lone* empty group is its seeded default list, not a
        // list the user made. It is dropped only when its name matches no
        // unassigned group, which is exactly the leftover `自选` after the user
        // renamed their real lists to 持仓/跟踪/美股. A custom extra group, a
        // group with members, and every unassigned group always survive.
        let unassignedNames = Set(
            portfolio(for: .unassigned).groups.map { Self.normalizedName($0.name) }
        )
        let ignoredSources = allSourceGroups().filter { source in
            guard source.account != .unassigned,
                  source.group.symbols.isEmpty,
                  portfolio(for: source.account).groups.count == 1 else { return false }
            return !unassignedNames.contains(Self.normalizedName(source.group.name))
        }
        let sources = allSourceGroups().filter { source in
            !ignoredSources.contains { $0.account == source.account && $0.group.id == source.group.id }
        }

        // Computed from the merge below, never from `isEmpty`: that property
        // reads `groups`, and calling it here would recurse into `liveGroups`.
        var anyMembers = false

        for source in sources {
            let key = Self.normalizedName(source.group.name)
            if !source.group.symbols.isEmpty { anyMembers = true }
            if var canonical = canonicalByKey[key] {
                for symbol in source.group.symbols where !canonical.symbols.contains(symbol) {
                    canonical.symbols.append(symbol)
                }
                for symbol in source.group.pinnedSymbols where !canonical.pinnedSymbols.contains(symbol) {
                    canonical.pinnedSymbols.append(symbol)
                }
                // A merged tab keeps its canonical name; only membership and
                // pin state are unioned. Manual order is derived below.
                canonicalByKey[key] = canonical
            } else {
                var group = source.group
                group.symbols = group.symbols.uniqued()
                group.pinnedSymbols = group.pinnedSymbols.uniqued()
                canonicalByKey[key] = group
                orderedKeys.append(key)
            }
        }

        // Nothing is watched anywhere, so an empty tab has no row to represent.
        // It stays visible while the user is on it or while it owns a saved
        // selection, so a rename or delete never yanks the tab away.
        if !anyMembers {
            for key in orderedKeys where canonicalByKey[key]?.symbols.isEmpty == true {
                guard let id = canonicalByKey[key]?.id,
                      id != storedSelectionID,
                      id.uuidString != defaults.string(forKey: sharedSelectionKey) else { continue }
                emptyAliasKeys.insert(key)
            }
            // Never project zero tabs: the selection needs a home.
            if emptyAliasKeys.count == orderedKeys.count { emptyAliasKeys.removeAll() }
        }
        return finishMerging(orderedKeys.filter { !emptyAliasKeys.contains($0) }, canonicalByKey)
    }

    private func finishMerging(
        _ orderedKeys: [String],
        _ canonicalByKey: [String: WatchlistGroup]
    ) -> [WatchlistGroup] {
        var merged = orderedKeys.compactMap { canonicalByKey[$0] }
        merged = applyLocalGroupOrder(merged)
        for index in merged.indices {
            merged[index] = applyLocalSymbolOrder(to: merged[index])
        }
        return merged
    }

    /// Applies the UI-only global group order. Groups absent from the saved
    /// order keep their source-relative position at the end.
    private func applyLocalGroupOrder(_ input: [WatchlistGroup]) -> [WatchlistGroup] {
        guard !local.groupOrder.isEmpty else { return input }
        let rank = Dictionary(uniqueKeysWithValues: local.groupOrder.uniqued().enumerated().map { ($1, $0) })
        return input.enumerated().sorted { lhs, rhs in
            let lhsRank = rank[lhs.element.id.uuidString] ?? Int.max
            let rhsRank = rank[rhs.element.id.uuidString] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Applies UI-only per-group symbol interleaving. Saved symbols that are
    /// still members come first (pinned-first within their section); members not
    /// named by the override are appended in source order so nothing is lost.
    ///
    /// A merged group can also carry a local pin override: multi-source pin
    /// transitions (a manual move crossing the pinned boundary) have no single
    /// physical group to record against, so the resolved pin set is kept here.
    private func applyLocalSymbolOrder(to group: WatchlistGroup) -> WatchlistGroup {
        var updated = group
        if let localPins = local.pinnedSymbols[group.id.uuidString] {
            let members = Set(group.symbols)
            updated.pinnedSymbols = localPins.filter { members.contains($0) }
        }
        guard let saved = local.symbolOrder[group.id.uuidString], !saved.isEmpty else {
            return pinnedFirst(updated)
        }
        let members = Set(updated.symbols)
        let ordered = saved.filter { members.contains($0) }.uniqued()
        let orderedSet = Set(ordered)
        updated.symbols = ordered + updated.symbols.filter { !orderedSet.contains($0) }
        return pinnedFirst(updated)
    }

    /// Presentation is always pinned-first, matching the core store's list.
    private func pinnedFirst(_ group: WatchlistGroup) -> WatchlistGroup {
        let pinned = Set(group.pinnedSymbols)
        guard !pinned.isEmpty else { return group }
        var updated = group
        updated.pinnedSymbols = group.symbols.filter { pinned.contains($0) }.uniqued()
        updated.symbols = updated.pinnedSymbols + group.symbols.filter { !pinned.contains($0) }
        return updated
    }

    // MARK: - Readings

    public var selectedGroup: WatchlistGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    /// Every item across every merged group, deduplicated by symbol using the
    /// first source metadata seen. This is a *shared-symbol* union: it must not
    /// fabricate aggregate positions or fictitious trades.
    public var allItems: [WatchItem] {
        let bySymbol = physicalItems()
        var seen = Set<SymbolID>()
        var result: [WatchItem] = []
        for group in groups {
            for symbol in group.symbols where seen.insert(symbol).inserted {
                if let item = bySymbol[symbol] { result.append(item) }
            }
        }
        return result
    }

    /// Items in the shared selection, in merged presentation order.
    public var items: [WatchItem] {
        guard let group = selectedGroup else { return [] }
        let bySymbol = physicalItems()
        var seen = Set<SymbolID>()
        return group.symbols.compactMap { symbol in
            guard seen.insert(symbol).inserted else { return nil }
            return bySymbol[symbol]
        }
    }

    /// Every shared symbol, deduplicated. Refresh and streaming use this union.
    public var symbols: [SymbolID] { allItems.map(\.symbol) }

    /// Market-data symbols for the shared surface. The financial store already
    /// unions inactive accounts; this keeps the facade's contract explicit.
    public var quoteSymbols: [SymbolID] {
        let unified = store.quoteSymbols
        let shared = Set(symbols)
        let extras = unified.filter { !shared.contains($0) }
        return symbols + extras
    }

    public var isEmpty: Bool { groups.allSatisfy { $0.symbols.isEmpty } }

    /// Physical item metadata, keyed by symbol, in fixed account order. The
    /// first source wins so merged presentation is deterministic.
    private func physicalItems() -> [SymbolID: WatchItem] {
        var bySymbol: [SymbolID: WatchItem] = [:]
        for account in sourceAccounts {
            let portfolio = portfolio(for: account)
            for item in portfolio.items + portfolio.retainedHistoryItems
            where bySymbol[item.symbol] == nil {
                bySymbol[item.symbol] = item
            }
        }
        return bySymbol
    }

    public func item(for symbol: SymbolID) -> WatchItem? {
        physicalItems()[symbol]
    }

    public func items(in groupID: UUID?) -> [WatchItem] {
        guard let group = group(for: groupID) else { return [] }
        let bySymbol = physicalItems()
        var seen = Set<SymbolID>()
        return group.symbols.compactMap { symbol in
            guard seen.insert(symbol).inserted else { return nil }
            return bySymbol[symbol]
        }
    }

    public func group(for id: UUID?) -> WatchlistGroup? {
        guard let id else { return groups.first }
        return groups.first { $0.id == id }
    }

    public func contains(_ symbol: SymbolID, in groupID: UUID? = nil) -> Bool {
        group(for: groupID ?? selectedGroupID)?.symbols.contains(symbol) == true
    }

    public func isPinned(_ symbol: SymbolID, in groupID: UUID? = nil) -> Bool {
        group(for: groupID ?? selectedGroupID)?.pinnedSymbols.contains(symbol) == true
    }

    /// All physical records for a symbol: watched items plus retained account
    /// items. This answers "what does the user still hold somewhere?", which is
    /// deliberately broader than the merged presentation item.
    public func records(for symbol: SymbolID) -> [WatchItem] {
        var result: [WatchItem] = []
        for account in sourceAccounts {
            let portfolio = portfolio(for: account)
            if let item = portfolio.items.first(where: { $0.symbol == symbol }) {
                result.append(item)
            }
            if let retained = portfolio.retainedHistoryItems.first(where: { $0.symbol == symbol }) {
                result.append(retained)
            }
        }
        return result
    }

    /// Every plan across every account, keeping each plan's original id and
    /// tagging the owning account. The read-only `accountID` is board scope; the
    /// stored plan is never rewritten.
    public var tradePlanEntries: [TradePlanEntry] {
        var entries: [TradePlanEntry] = []
        for account in sourceAccounts {
            let portfolio = portfolio(for: account)
            let bySymbol = Dictionary(
                uniqueKeysWithValues: (portfolio.items + portfolio.retainedHistoryItems).map { ($0.symbol, $0) }
            )
            var seenInAccount = Set<SymbolID>()
            for group in portfolio.groups {
                for symbol in group.symbols where seenInAccount.insert(symbol).inserted {
                    guard let item = bySymbol[symbol] else { continue }
                    entries.append(contentsOf: item.plans.map {
                        TradePlanEntry(symbol: symbol, plan: $0, transactions: store.transactionsForPlan(symbol, account: account),
                                       accountID: account)
                    })
                }
            }
            // Retained financial history can carry plans even when the symbol is
            // no longer in any of that account's groups.
            for item in portfolio.retainedHistoryItems
            where !seenInAccount.contains(item.symbol) && !item.plans.isEmpty {
                seenInAccount.insert(item.symbol)
                entries.append(contentsOf: item.plans.map {
                    TradePlanEntry(symbol: item.symbol, plan: $0, transactions: store.transactionsForPlan(item.symbol, account: account),
                                   accountID: account)
                })
            }
        }
        return entries
    }

    /// Global filter: does any physical record hold an open position?
    public func hasPosition(for symbol: SymbolID) -> Bool {
        records(for: symbol).contains { $0.hasPosition }
    }

    /// Global filter: does any physical record have an active plan?
    public func hasActivePlan(for symbol: SymbolID) -> Bool {
        records(for: symbol).contains { $0.hasActivePlans }
    }

    /// Dormant ledger view for a symbol that is no longer in any shared group.
    public func retainedHistoryItem(for symbol: SymbolID) -> WatchItem? {
        for account in sourceAccounts {
            if let item = portfolio(for: account).retainedHistoryItems.first(where: { $0.symbol == symbol }) {
                return item
            }
        }
        return nil
    }

    // MARK: - Selection

    private func initialSelection() -> UUID? {
        if let raw = defaults.string(forKey: sharedSelectionKey),
           let saved = UUID(uuidString: raw),
           groups.contains(where: { $0.id == saved }) {
            return saved
        }
        // Prefer the financial store's current selection only when the active
        // account is unassigned; otherwise a named account's local selection has
        // no meaning on the shared surface.
        if store.activeBrokerageAccountID == .unassigned,
           let current = store.selectedGroupID,
           let match = groups.first(where: { $0.id == current || $0.name == store.selectedGroup?.name }) {
            return match.id
        }
        return groups.first?.id
    }

    public func selectGroup(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }), selectedGroupID != id else { return }
        storedSelectionID = id
        defaults.set(id.uuidString, forKey: sharedSelectionKey)
    }

    // MARK: - Mutation helpers

    /// Resolves the concrete source groups behind a canonical (merged) group.
    /// Callers use this *before* any write so a stale or unknown id is a no-op.
    ///
    /// This walks every physical group, including the empty named-account
    /// defaults the projection hides: removal must clear a membership wherever
    /// it physically lives, and a rename or delete must reach every real group
    /// the tab represents.
    private func resolvedSources(for groupID: UUID?) -> [SourceGroup] {
        guard let canonical = group(for: groupID ?? selectedGroupID) else { return [] }
        let key = Self.normalizedName(canonical.name)
        return allSourceGroups().filter { Self.normalizedName($0.group.name) == key }
    }

    /// Runs `body` scoped to one account with a concrete source group selected,
    /// restoring that account's prior selected group afterwards. The caller must
    /// have resolved the account and group before entering.
    private func scoped<T>(
        account: BrokerageAccountID,
        selecting groupID: UUID,
        _ body: () -> T
    ) -> T {
        store.withBrokerageAccount(account) {
            let prior = store.selectedGroupID
            store.selectGroup(groupID)
            defer {
                if let prior, store.groups.contains(where: { $0.id == prior }) {
                    store.selectGroup(prior)
                }
            }
            return body()
        }
    }

    /// Re-anchors the shared selection after a mutation. Because the group list
    /// is derived, this only repairs a selection whose group no longer exists.
    private func refresh() {
        guard storedSelectionID == nil || !groups.contains(where: { $0.id == storedSelectionID })
        else { return }
        storedSelectionID = groups.first?.id
        if let selectedGroupID {
            defaults.set(selectedGroupID.uuidString, forKey: sharedSelectionKey)
        } else {
            defaults.removeObject(forKey: sharedSelectionKey)
        }
    }

    // MARK: - Membership mutation

    /// Adds a symbol to the shared group (or the shared selection by default).
    ///
    /// The write lands in the *canonical* source group only — the first source
    /// group seen in account order — so a merged tab accumulates one real
    /// membership at a time and never silently rewrites every account. Only
    /// membership metadata is written: the core store keeps existing item
    /// metadata and no trade is created.
    public func add(_ info: SymbolInfo, to groupID: UUID? = nil) {
        let sources = resolvedSources(for: groupID)
        guard let target = sources.first else { return }
        scoped(account: target.account, selecting: target.group.id) {
            store.add(info, to: target.group.id)
        }
        refresh()
    }

    /// Removes the symbol from every source group merged into the requested
    /// group. Financial history retained by the core store is untouched.
    public func remove(_ symbol: SymbolID) {
        remove(symbol, in: selectedGroupID)
    }

    private func remove(_ symbol: SymbolID, in groupID: UUID?) {
        let sources = resolvedSources(for: groupID)
        guard !sources.isEmpty else { return }
        for source in sources {
            let holds = store.brokeragePortfolio(for: source.account)
                .groups.first(where: { $0.id == source.group.id })?
                .symbols.contains(symbol) == true
            guard holds else { continue }
            scoped(account: source.account, selecting: source.group.id) {
                store.setMembership(symbol, in: source.group.id, included: false)
            }
        }
        refresh()
    }

    /// Adds or removes membership for one symbol in one shared group.
    ///
    /// Addition lands in exactly one place: the canonical source group — the
    /// first concrete source in account order. Duplicating the symbol into every
    /// merged account would silently clone a watch entry across portfolios, and
    /// a merged group whose members already contain the symbol is already in the
    /// requested state, so that case is a deliberate no-op.
    ///
    /// Removal is the mirror image: it must clear the symbol from every concrete
    /// source that actually holds it, because each of those is a real membership.
    public func setMembership(_ symbol: SymbolID, in groupID: UUID?, included: Bool) {
        let sources = resolvedSources(for: groupID)
        guard !sources.isEmpty else { return }

        guard included else {
            for source in sources {
                let holds = store.brokeragePortfolio(for: source.account)
                    .groups.first { $0.id == source.group.id }?.symbols.contains(symbol) == true
                guard holds else { continue }
                scoped(account: source.account, selecting: source.group.id) {
                    store.setMembership(symbol, in: source.group.id, included: false)
                }
            }
            refresh()
            return
        }

        // Already a member of the merged group: nothing to add, and no account
        // may gain a copy. The merged membership is the union over sources, so
        // one concrete membership satisfies the request.
        guard !(group(for: groupID ?? selectedGroupID)?.symbols.contains(symbol) ?? false),
              let target = sources.first else { return }

        // Resolve shared reference metadata *before* entering the scope: this
        // reads every account, which is only correct on the unscoped store.
        guard let info = symbolInfo(for: symbol) else { return }
        // An existing item already carries its own financial record; only a
        // symbol with no backing item needs one materialized. The write is
        // membership plus shared reference metadata — never a copied ledger,
        // lot, plan, or transaction.
        if store.brokeragePortfolio(for: target.account)
            .items.contains(where: { $0.symbol == symbol }) {
            scoped(account: target.account, selecting: target.group.id) {
                store.setMembership(symbol, in: target.group.id, included: true)
            }
        } else {
            scoped(account: target.account, selecting: target.group.id) {
                store.materializeItem(info)
                store.setMembership(symbol, in: target.group.id, included: true)
            }
        }
        refresh()
    }

    /// Best-effort reference metadata for a symbol already known to the shared
    /// surface, so adding membership elsewhere never invents trade data.
    private func symbolInfo(for symbol: SymbolID) -> SymbolInfo? {
        guard let item = physicalItems()[symbol] else { return nil }
        return SymbolInfo(
            symbol: item.symbol,
            name: item.displayName,
            type: item.resolvedInstrumentType ?? .equity,
            displayNameSource: item.displayNameSource
        )
    }

    public func setPinned(_ symbol: SymbolID, in groupID: UUID? = nil, pinned: Bool) -> Bool {
        guard let canonical = group(for: groupID ?? selectedGroupID) else { return false }
        let sources = resolvedSources(for: groupID)
        guard !sources.isEmpty else { return false }
        var changed = false
        for source in sources {
            let group = store.brokeragePortfolio(for: source.account)
                .groups.first { $0.id == source.group.id }
            guard group?.symbols.contains(symbol) == true else { continue }
            scoped(account: source.account, selecting: source.group.id) {
                if store.setPinned(symbol, in: source.group.id, pinned: pinned) { changed = true }
            }
        }
        if changed, sources.count > 1 {
            // A merged group's pin is the union of its sources. Keep the local
            // resolution so unpinning one source symbol cannot be undone by
            // another source that still holds the pin.
            var pins = Set(canonical.pinnedSymbols)
            if pinned { pins.insert(symbol) } else { pins.remove(symbol) }
            local.pinnedSymbols[canonical.id.uuidString] = canonical.symbols.filter { pins.contains($0) }
            saveLocalPreferences()
        }
        refresh()
        return changed
    }

    // MARK: - Group lifecycle

    /// Creates a group. The first write lands in the unassigned portfolio (or the
    /// active account when brokerage is disabled), which keeps the canonical id
    /// stable and the financial selection untouched.
    public func createGroup(named rawName: String) -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !groups.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }

        // Group creation lands in unassigned, which is the canonical home for
        // shared-only groups: named accounts keep their own default lists.
        var created: UUID?
        store.withBrokerageAccount(.unassigned) {
            let prior = store.selectedGroupID
            created = store.createGroup(named: name)
            if let prior, store.groups.contains(where: { $0.id == prior }) {
                store.selectGroup(prior)
            }
        }
        guard let created else { return nil }
        refresh()
        selectGroup(created)
        return created
    }

    /// Renames using the core implementation, which already rejects a name
    /// collision. Returns false without writing when any source group is invalid.
    public func renameGroup(_ id: UUID, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let sources = resolvedSources(for: id)
        guard !sources.isEmpty else { return false }
        // Validate every source before any write.
        guard sources.allSatisfy({ source in
            store.brokeragePortfolio(for: source.account)
                .groups.contains { $0.id == source.group.id }
        }) else { return false }
        guard !groups.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { return false }

        var renamed = false
        for source in sources {
            scoped(account: source.account, selecting: source.group.id) {
                if store.renameGroup(source.group.id, to: name) { renamed = true }
            }
        }
        refresh()
        return renamed
    }

    /// Deletes every source group merged into the shared group. The core store
    /// keeps instruments and their financial history; only the tag is removed.
    ///
    /// Every source group is validated before any write. The core store refuses
    /// to delete an account's last remaining list, so a merged group that is the
    /// only list in one of its accounts is refused as a whole rather than
    /// partially deleted — that would leave the tab visible with some
    /// memberships silently gone.
    public func deleteGroup(_ id: UUID) -> Bool {
        let sources = resolvedSources(for: id)
        guard !sources.isEmpty else { return false }
        guard sources.allSatisfy({ source in
            let portfolio = store.brokeragePortfolio(for: source.account)
            return portfolio.groups.contains { $0.id == source.group.id } && portfolio.groups.count > 1
        }) else { return false }
        var deleted = false
        for source in sources {
            scoped(account: source.account, selecting: source.group.id) {
                if store.deleteGroup(source.group.id) { deleted = true }
            }
        }
        guard deleted else { return false }
        if storedSelectionID == id {
            storedSelectionID = nil
            defaults.removeObject(forKey: sharedSelectionKey)
        }
        refresh()
        if let selectedGroupID {
            defaults.set(selectedGroupID.uuidString, forKey: sharedSelectionKey)
        }
        return true
    }

    // MARK: - Ordering

    public func moveGroup(_ sourceID: UUID, relativeTo destinationID: UUID) {
        guard sourceID != destinationID,
              let sourceIndex = groups.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = groups.firstIndex(where: { $0.id == destinationID }) else { return }
        var updated = groups
        let moving = updated.remove(at: sourceIndex)
        guard let updatedDestination = updated.firstIndex(where: { $0.id == destinationID })
        else { return }
        let insertion = sourceIndex < destinationIndex ? updatedDestination + 1 : updatedDestination
        updated.insert(moving, at: insertion)
        local.groupOrder = updated.map(\.id.uuidString)
        saveLocalPreferences()
    }

    /// Applies an automatic symbol sort to the shared selection.
    ///
    /// `orderedSymbols` is the presentation the UI computed; symbols that are
    /// not members of the selected group are filtered out, and members the
    /// request does not name stay appended in their current relative order, so
    /// a partial or stale sort can never drop a row.
    ///
    /// With exactly one member-bearing source the core `reorder` runs inside
    /// that scope, which also updates the physical group's own manual baseline —
    /// that is what makes "restore my custom order" work after switching back
    /// from an automatic sort. With several real contributors the merged
    /// presentation is a UI-only override: only `local.symbolOrder` changes and
    /// the remembered manual baseline is preserved untouched. Ordering is
    /// delegated on `memberSources`, so an empty alias default group does not
    /// by itself turn a single physical list into a merged one.
    public func reorder(_ orderedSymbols: [SymbolID]) {
        guard let group = selectedGroup else { return }
        let members = Set(group.symbols)
        let ordered = orderedSymbols.filter { members.contains($0) }.uniqued()
        let orderedSet = Set(ordered)
        let completed = ordered + group.symbols.filter { !orderedSet.contains($0) }
        guard completed != group.symbols else { return }

        let sources = memberSources(for: group.id)
        if sources.count == 1, let source = sources.first,
           source.group.symbols.count == group.symbols.count {
            scoped(account: source.account, selecting: source.group.id) {
                store.reorder(completed)
                // The core store owns the baseline for a single physical list;
                // a stale UI override would shadow the restored order.
                clearLocalSymbolOrder(for: group.id)
            }
            refresh()
            return
        }

        // Merged presentation: pinned-first is a resolved fact here, so it is
        // stored alongside the order and the existing baseline is left alone.
        storeLocalSymbolOrder(completed, pinned: Set(group.pinnedSymbols), for: group.id,
                              baseline: local.manualBaseline[group.id.uuidString])
    }

    /// Commits a manual move inside the shared selection.
    ///
    /// For single-source groups the core `commitManualMove` runs verbatim so the
    /// existing manual-order and pin-boundary semantics stay exact. For
    /// multi-source groups the permutation and pin-boundary transition are
    /// validated here before the UI-only override is stored, and the physical
    /// source groups are left alone.
    @discardableResult
    public func commitManualMove(orderedSymbols: [SymbolID], movingSymbols: [SymbolID]) -> Bool {
        guard let group = selectedGroup else { return false }
        let currentSet = Set(group.symbols)
        guard orderedSymbols.count == group.symbols.count,
              Set(orderedSymbols) == currentSet,
              orderedSymbols.uniqued().count == orderedSymbols.count else { return false }
        let moving = movingSymbols.filter { currentSet.contains($0) }.uniqued()
        let movingSet = Set(moving)
        guard !moving.isEmpty,
              orderedSymbols.contains(where: { movingSet.contains($0) }) else { return false }

        let sources = memberSources(for: group.id)
        if sources.count == 1, let source = sources.first,
           source.group.symbols.count == group.symbols.count {
            let committed = scoped(account: source.account, selecting: source.group.id) {
                store.commitManualMove(orderedSymbols: orderedSymbols, movingSymbols: moving)
            }
            if committed { clearLocalSymbolOrder(for: group.id) }
            refresh()
            return committed
        }

        // Multi-source: validate the pin boundary transition before applying.
        // The physical source groups stay untouched; the merged presentation is
        // a UI-only override keyed by the canonical id.
        let pinned = Set(group.pinnedSymbols)
        let movingPinned = moving.filter { pinned.contains($0) }.count
        guard movingPinned == 0 || movingPinned == moving.count else { return false }
        var updatedPinned = pinned
        if movingPinned == moving.count {
            let insertion = orderedSymbols.firstIndex(where: { movingSet.contains($0) }) ?? 0
            let remaining = pinned.count - movingPinned
            if insertion > remaining { updatedPinned.subtract(movingSet) }
        } else {
            let insertion = orderedSymbols.firstIndex(where: { movingSet.contains($0) }) ?? 0
            let remaining = pinned.count - movingPinned
            if insertion < remaining { updatedPinned.formUnion(movingSet) }
        }

        let visible = orderedSymbols.filter { updatedPinned.contains($0) }
            + orderedSymbols.filter { !updatedPinned.contains($0) }
        storeLocalSymbolOrder(visible, pinned: updatedPinned, for: group.id,
                              baseline: manualBaselineAfterMove(group: group, visible: visible, pinned: pinned))
        return true
    }

    /// Maintains the hidden manual baseline separately from the visible order so
    /// automatic reorder and pin-boundary logic can still restore it. Pinned
    /// symbols keep their existing baseline slots; unpinned symbols adopt their
    /// visible relative order — the same rule the core store uses.
    private func manualBaselineAfterMove(
        group: WatchlistGroup,
        visible: [SymbolID],
        pinned: Set<SymbolID>
    ) -> [SymbolID] {
        guard !pinned.isEmpty else { return visible }
        let visibleSet = Set(visible)
        let stored = (local.manualBaseline[group.id.uuidString] ?? group.symbols)
            .filter { visibleSet.contains($0) }.uniqued()
        let storedSet = Set(stored)
        let baseline = stored + visible.filter { !storedSet.contains($0) }
        let visibleUnpinned = visible.filter { !pinned.contains($0) }
        var index = 0
        var result: [SymbolID] = []
        for symbol in baseline {
            if pinned.contains(symbol) {
                result.append(symbol)
            } else if index < visibleUnpinned.count {
                result.append(visibleUnpinned[index])
                index += 1
            }
        }
        return result.uniqued()
    }

    /// Remembers the visible order of the shared selection as the manual baseline.
    public func rememberManualOrder() {
        guard let group = selectedGroup else { return }
        let sources = memberSources(for: group.id)
        if sources.count == 1, let source = sources.first,
           source.group.symbols.count == group.symbols.count {
            scoped(account: source.account, selecting: source.group.id) {
                store.rememberManualOrder()
            }
            clearLocalSymbolOrder(for: group.id)
            refresh()
            return
        }
        local.manualBaseline[group.id.uuidString] = group.symbols
        local.symbolOrder[group.id.uuidString] = group.symbols
        saveLocalPreferences()
    }

    /// Restores the shared manual baseline for the selection. Single-source
    /// groups delegate to the core store's own baseline.
    @discardableResult
    public func restoreManualOrder() -> Bool {
        guard let group = selectedGroup else { return false }
        let sources = memberSources(for: group.id)
        if sources.count == 1, let source = sources.first,
           source.group.symbols.count == group.symbols.count {
            let restored = scoped(account: source.account, selecting: source.group.id) {
                store.restoreManualOrder()
            }
            if restored { clearLocalSymbolOrder(for: group.id) }
            refresh()
            return restored
        }
        guard let baseline = local.manualBaseline[group.id.uuidString], !baseline.isEmpty else {
            return false
        }
        let members = Set(group.symbols)
        let remembered = baseline.filter { members.contains($0) }.uniqued()
        guard !remembered.isEmpty else { return false }
        // A baseline that no longer covers every member keeps the unnamed
        // members appended rather than dropping them.
        let rememberedSet = Set(remembered)
        let completed = remembered + group.symbols.filter { !rememberedSet.contains($0) }
        let updated = pinnedFirst(replacingSymbols: group, with: completed)
        storeLocalSymbolOrder(updated.symbols, pinned: Set(updated.pinnedSymbols), for: group.id)
        return true
    }

    private func pinnedFirst(replacingSymbols group: WatchlistGroup, with symbols: [SymbolID]) -> WatchlistGroup {
        var updated = group
        updated.symbols = symbols
        return pinnedFirst(updated)
    }

    /// Records the merged presentation order and its resolved pin set. `pinned`
    /// is only persisted for groups whose physical sources cannot express it.
    private func storeLocalSymbolOrder(
        _ ordered: [SymbolID],
        pinned: Set<SymbolID>,
        for id: UUID,
        baseline: [SymbolID]? = nil,
        pinsLocally: Bool = true
    ) {
        local.symbolOrder[id.uuidString] = ordered
        local.manualBaseline[id.uuidString] = baseline ?? ordered
        if pinsLocally {
            local.pinnedSymbols[id.uuidString] = ordered.filter { pinned.contains($0) }
        }
        saveLocalPreferences()
    }

    private func clearLocalSymbolOrder(for id: UUID) {
        local.symbolOrder.removeValue(forKey: id.uuidString)
        local.manualBaseline.removeValue(forKey: id.uuidString)
        local.pinnedSymbols.removeValue(forKey: id.uuidString)
        saveLocalPreferences()
    }

    // MARK: - Local preference storage

    private func loadLocalPreferences() {
        guard let data = defaults.data(forKey: localPreferencesKey) else { return }
        if let decoded = try? JSONDecoder().decode(LocalPreferences.self, from: data) {
            local = decoded
        }
    }

    private func saveLocalPreferences() {
        guard let data = try? JSONEncoder().encode(local) else { return }
        defaults.set(data, forKey: localPreferencesKey)
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
