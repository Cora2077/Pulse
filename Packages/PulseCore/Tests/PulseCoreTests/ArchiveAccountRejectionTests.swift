import Foundation
import Testing
@testable import PulseCore

/// A cross-account import is refused as a whole, and refusing must be inert.
///
/// The account tag travels with an archive so one installation's ledger is never
/// folded into another's. That refusal is the store's decision, not the screen's,
/// and it must hold with the account feature switched off — which is the one
/// state a UI-gated check used to miss. These tests pin the typed reason, the
/// empty plan, and the fact that nothing at all is written when the plan is
/// refused.
@Suite("Archive account rejection")
struct ArchiveAccountRejectionTests {
    private let baselineSymbol = SymbolID(market: .us, code: "MSFT")
    private let baselineName = "Microsoft"

    @MainActor
    private func makeStore(
        _ label: String
    ) throws -> (store: WatchlistStore, defaults: UserDefaults, suite: String) {
        let suite = "ArchiveAccountRejectionTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist"), defaults, suite)
    }

    /// One list, one entry — all a refusal needs to have something to refuse.
    private func archive(account: BrokerageAccountID?, code: String = "AAPL") -> WatchlistArchive {
        WatchlistArchive(
            exportedAt: Date(timeIntervalSince1970: 0),
            lists: [.init(name: "Core", entries: [.init(market: .us, code: code)])],
            brokerageAccountID: account
        )
    }

    /// The two keys the store persists into. Comparing their bytes catches a
    /// refused merge that quietly wrote anything back: a plan that mutates and
    /// then saves is otherwise indistinguishable from a harmless no-op import.
    private static func persistedBytes(_ defaults: UserDefaults) -> [String: Data] {
        var values: [String: Data] = [:]
        for key in ["pulse.watchlists.v3", "pulse.watchlists.v4"] {
            if let data = defaults.data(forKey: key) { values[key] = data }
        }
        return values
    }

    /// What the store looked like before the refused merge.
    ///
    /// Captured after setup on purpose: construction and account selection write
    /// to the defaults legitimately, so only the state from that point on is the
    /// refusal's responsibility.
    @MainActor
    private struct Baseline {
        var snapshot: WatchlistSyncSnapshot
        var items: [WatchItem]
        var groupSymbols: [[SymbolID]]
        var selectedGroupID: UUID?
        var activeAccount: BrokerageAccountID
        var enabled: Bool
        var persisted: [String: Data]
        var domain: NSDictionary

        init(_ store: WatchlistStore, _ defaults: UserDefaults, _ suite: String) {
            snapshot = store.syncSnapshot()
            items = store.allItems
            groupSymbols = store.groups.map(\.symbols)
            selectedGroupID = store.selectedGroupID
            activeAccount = store.activeBrokerageAccountID
            enabled = store.brokerageAccountsEnabled
            persisted = ArchiveAccountRejectionTests.persistedBytes(defaults)
            domain = (defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary
        }

        func assertUnchanged(
            _ store: WatchlistStore,
            _ defaults: UserDefaults,
            _ suite: String,
            syncCallbacks: Int,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            #expect(store.syncSnapshot() == snapshot, sourceLocation: sourceLocation)
            #expect(store.allItems == items, sourceLocation: sourceLocation)
            #expect(store.groups.map(\.symbols) == groupSymbols, sourceLocation: sourceLocation)
            #expect(store.selectedGroupID == selectedGroupID, sourceLocation: sourceLocation)
            #expect(store.activeBrokerageAccountID == activeAccount, sourceLocation: sourceLocation)
            #expect(store.brokerageAccountsEnabled == enabled, sourceLocation: sourceLocation)
            #expect(syncCallbacks == 0, sourceLocation: sourceLocation)
            #expect(ArchiveAccountRejectionTests.persistedBytes(defaults) == persisted, sourceLocation: sourceLocation)
            #expect(
                ((defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary) == domain,
                sourceLocation: sourceLocation
            )
        }
    }

    /// Every refusal assertion in one place, so a new refusal case cannot forget
    /// half of them.
    @MainActor
    private func assertRefused(
        store: WatchlistStore,
        defaults: UserDefaults,
        suite: String,
        archive archiveValue: WatchlistArchive,
        archiveAccountID: BrokerageAccountID,
        destinationAccountID: BrokerageAccountID,
        baseline: Baseline,
        syncCallbacks: () -> Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        // The plan itself is recomputed here rather than compared against the
        // baseline: `importPlan` is pure, so recomputing it is what proves the
        // refusal is a reading of the archive and not a sticky stored flag.
        let plan = store.importPlan(for: archiveValue)
        #expect(
            plan.rejectionReason == WatchlistArchive.ImportPlan.RejectionReason.accountMismatch(
                archiveAccountID: archiveAccountID,
                destinationAccountID: destinationAccountID
            ),
            sourceLocation: sourceLocation
        )
        #expect(plan.changesAnything == false, sourceLocation: sourceLocation)
        #expect(plan.lists.isEmpty, sourceLocation: sourceLocation)
        #expect(plan.allItems.isEmpty, sourceLocation: sourceLocation)
        #expect(plan.newListCount == 0, sourceLocation: sourceLocation)
        #expect(plan.addCount == 0, sourceLocation: sourceLocation)
        #expect(plan.skippedCount == 0, sourceLocation: sourceLocation)
        #expect(plan.restoreCount == 0, sourceLocation: sourceLocation)
        #expect(plan.drawingCount == 0, sourceLocation: sourceLocation)
        #expect(plan.metadataCount == 0, sourceLocation: sourceLocation)

        // `merge` must return that identical refusal rather than re-deciding it.
        let applied = store.merge(archiveValue)
        #expect(applied == plan, sourceLocation: sourceLocation)

        baseline.assertUnchanged(
            store, defaults, suite, syncCallbacks: syncCallbacks(), sourceLocation: sourceLocation
        )
    }

    /// A list and a traded position the refused merge must leave alone.
    @MainActor
    private func seedBaselineContent(_ store: WatchlistStore) {
        store.add(SymbolInfo(symbol: baselineSymbol, name: baselineName))
        store.addTransaction(baselineSymbol, PositionTransaction(
            id: UUID(),
            kind: .buy,
            price: 100,
            quantity: 2,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }

    // MARK: - Accepted

    @MainActor
    @Test("A matching tagged archive imports into the selected named account")
    func matchingTaggedArchiveImports() throws {
        let (store, defaults, suite) = try makeStore("acceptedMatching")
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.enableBrokerageAccounts())
        #expect(store.selectBrokerageAccount(.financing))

        let plan = store.importPlan(for: archive(account: .financing))
        #expect(plan.rejectionReason == nil)
        #expect(plan.changesAnything)
        #expect(plan.addCount == 1)

        let applied = store.merge(archive(account: .financing))
        #expect(applied.rejectionReason == nil)
        #expect(applied.addCount == 1)
        let apple = SymbolID(market: .us, code: "AAPL")
        #expect(store.item(for: apple) != nil)
        #expect(store.groups.contains { $0.symbols.contains(apple) })
    }

    @MainActor
    @Test("An unassigned tag imports with the account feature off")
    func unassignedTagImportsWithFeatureOff() throws {
        let (store, defaults, suite) = try makeStore("acceptedUnassignedOff")
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.brokerageAccountsEnabled == false)
        #expect(store.activeBrokerageAccountID == .unassigned)

        let plan = store.importPlan(for: archive(account: .unassigned))
        #expect(plan.rejectionReason == nil)
        #expect(plan.addCount == 1)

        #expect(store.merge(archive(account: .unassigned)).rejectionReason == nil)
        #expect(store.item(for: SymbolID(market: .us, code: "AAPL")) != nil)
    }

    @MainActor
    @Test("An unassigned tag imports with the account feature on")
    func unassignedTagImportsWithFeatureOn() throws {
        let (store, defaults, suite) = try makeStore("acceptedUnassignedOn")
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.enableBrokerageAccounts())
        #expect(store.activeBrokerageAccountID == .unassigned)

        let plan = store.importPlan(for: archive(account: .unassigned))
        #expect(plan.rejectionReason == nil)
        #expect(plan.addCount == 1)

        #expect(store.merge(archive(account: .unassigned)).rejectionReason == nil)
        #expect(store.item(for: SymbolID(market: .us, code: "AAPL")) != nil)
    }

    @MainActor
    @Test("An untagged archive imports into the current account with the feature off")
    func untaggedArchiveImportsWithFeatureOff() throws {
        let (store, defaults, suite) = try makeStore("acceptedUntaggedOff")
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.brokerageAccountsEnabled == false)

        let plan = store.importPlan(for: archive(account: nil))
        #expect(plan.rejectionReason == nil)
        #expect(plan.addCount == 1)

        #expect(store.merge(archive(account: nil)).rejectionReason == nil)
        #expect(store.item(for: SymbolID(market: .us, code: "AAPL")) != nil)
    }

    @MainActor
    @Test("An untagged archive imports into the explicitly selected named account")
    func untaggedArchiveImportsIntoSelectedNamedAccount() throws {
        let (store, defaults, suite) = try makeStore("acceptedUntaggedOn")
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.enableBrokerageAccounts())
        #expect(store.selectBrokerageAccount(.mengmeng))

        let plan = store.importPlan(for: archive(account: nil))
        #expect(plan.rejectionReason == nil)
        #expect(plan.addCount == 1)

        #expect(store.merge(archive(account: nil)).rejectionReason == nil)
        let apple = SymbolID(market: .us, code: "AAPL")
        #expect(store.item(for: apple) != nil)
        #expect(store.brokeragePortfolio(for: .mengmeng).items.contains { $0.symbol == apple })
        #expect(!store.brokeragePortfolio(for: .unassigned).items.contains { $0.symbol == apple })
    }

    // MARK: - Refused

    @MainActor
    @Test("A tagged account mismatch is refused whether or not the ledger is clean")
    func taggedNamedMismatchIsRefusedWithFeatureOn() throws {
        let (cleanStore, cleanDefaults, cleanSuite) = try makeStore("refusedNamedClean")
        defer { cleanDefaults.removePersistentDomain(forName: cleanSuite) }
        #expect(cleanStore.enableBrokerageAccounts())
        #expect(cleanStore.selectBrokerageAccount(.financing))
        var cleanCallbacks = 0
        cleanStore.onLocalSyncChange = { _ in cleanCallbacks += 1 }
        let cleanBaseline = Baseline(cleanStore, cleanDefaults, cleanSuite)
        assertRefused(
            store: cleanStore, defaults: cleanDefaults, suite: cleanSuite,
            archive: archive(account: .mengmeng),
            archiveAccountID: .mengmeng,
            destinationAccountID: .financing,
            baseline: cleanBaseline,
            syncCallbacks: { cleanCallbacks }
        )

        let (dirty, dirtyDefaults, dirtySuite) = try makeStore("refusedNamedDirty")
        defer { dirtyDefaults.removePersistentDomain(forName: dirtySuite) }
        #expect(dirty.enableBrokerageAccounts())
        #expect(dirty.selectBrokerageAccount(.financing))
        seedBaselineContent(dirty)
        var dirtyCallbacks = 0
        dirty.onLocalSyncChange = { _ in dirtyCallbacks += 1 }
        let dirtyBaseline = Baseline(dirty, dirtyDefaults, dirtySuite)
        assertRefused(
            store: dirty, defaults: dirtyDefaults, suite: dirtySuite,
            archive: archive(account: .mengmeng),
            archiveAccountID: .mengmeng,
            destinationAccountID: .financing,
            baseline: dirtyBaseline,
            syncCallbacks: { dirtyCallbacks }
        )
    }

    /// A disabled account feature must still expose the core refusal rather
    /// than presenting an empty, apparently successful import preview.
    @MainActor
    @Test("A tagged archive is refused with the account feature off")
    func taggedArchiveIsRefusedWithFeatureOff() throws {
        let (cleanStore, cleanDefaults, cleanSuite) = try makeStore("refusedOffClean")
        defer { cleanDefaults.removePersistentDomain(forName: cleanSuite) }
        #expect(cleanStore.brokerageAccountsEnabled == false)
        var cleanCallbacks = 0
        cleanStore.onLocalSyncChange = { _ in cleanCallbacks += 1 }
        let cleanBaseline = Baseline(cleanStore, cleanDefaults, cleanSuite)
        assertRefused(
            store: cleanStore, defaults: cleanDefaults, suite: cleanSuite,
            archive: archive(account: .mengmeng),
            archiveAccountID: .mengmeng,
            destinationAccountID: .unassigned,
            baseline: cleanBaseline,
            syncCallbacks: { cleanCallbacks }
        )

        let (dirty, dirtyDefaults, dirtySuite) = try makeStore("refusedOffDirty")
        defer { dirtyDefaults.removePersistentDomain(forName: dirtySuite) }
        #expect(dirty.brokerageAccountsEnabled == false)
        seedBaselineContent(dirty)
        var dirtyCallbacks = 0
        dirty.onLocalSyncChange = { _ in dirtyCallbacks += 1 }
        let dirtyBaseline = Baseline(dirty, dirtyDefaults, dirtySuite)
        assertRefused(
            store: dirty, defaults: dirtyDefaults, suite: dirtySuite,
            archive: archive(account: .mengmeng),
            archiveAccountID: .mengmeng,
            destinationAccountID: .unassigned,
            baseline: dirtyBaseline,
            syncCallbacks: { dirtyCallbacks }
        )
    }

    @MainActor
    @Test("An unassigned tag is refused into a selected named account")
    func unassignedTagIsRefusedIntoNamedAccount() throws {
        let (cleanStore, cleanDefaults, cleanSuite) = try makeStore("refusedTagClean")
        defer { cleanDefaults.removePersistentDomain(forName: cleanSuite) }
        #expect(cleanStore.enableBrokerageAccounts())
        #expect(cleanStore.selectBrokerageAccount(.mengmeng))
        var cleanCallbacks = 0
        cleanStore.onLocalSyncChange = { _ in cleanCallbacks += 1 }
        let cleanBaseline = Baseline(cleanStore, cleanDefaults, cleanSuite)
        assertRefused(
            store: cleanStore, defaults: cleanDefaults, suite: cleanSuite,
            archive: archive(account: .unassigned),
            archiveAccountID: .unassigned,
            destinationAccountID: .mengmeng,
            baseline: cleanBaseline,
            syncCallbacks: { cleanCallbacks }
        )

        let (dirty, dirtyDefaults, dirtySuite) = try makeStore("refusedTagDirty")
        defer { dirtyDefaults.removePersistentDomain(forName: dirtySuite) }
        #expect(dirty.enableBrokerageAccounts())
        #expect(dirty.selectBrokerageAccount(.mengmeng))
        seedBaselineContent(dirty)
        var dirtyCallbacks = 0
        dirty.onLocalSyncChange = { _ in dirtyCallbacks += 1 }
        let dirtyBaseline = Baseline(dirty, dirtyDefaults, dirtySuite)
        assertRefused(
            store: dirty, defaults: dirtyDefaults, suite: dirtySuite,
            archive: archive(account: .unassigned),
            archiveAccountID: .unassigned,
            destinationAccountID: .mengmeng,
            baseline: dirtyBaseline,
            syncCallbacks: { dirtyCallbacks }
        )
    }
}
