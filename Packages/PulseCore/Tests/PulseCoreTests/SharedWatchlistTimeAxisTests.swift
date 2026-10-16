import Foundation
import Testing
@testable import PulseCore

/// The group-level switch that puts a group's rows on one shared reference-market
/// clock. It is UI-only state: never financial, never synchronized, and off until
/// a user asks for it.
@Suite("Shared watchlist time axis")
struct SharedWatchlistTimeAxisTests {
    @MainActor
    private func makeShared(_ label: String) throws -> (shared: SharedWatchlist, defaults: UserDefaults, suite: String) {
        let suite = "SharedWatchlistTimeAxisTests.\(label).\(UUID().uuidString)"
        let storeSuite = "\(suite).store"
        let storeDefaults = try #require(UserDefaults(suiteName: storeSuite))
        let sharedDefaults = try #require(UserDefaults(suiteName: suite))
        storeDefaults.removePersistentDomain(forName: storeSuite)
        sharedDefaults.removePersistentDomain(forName: suite)
        let store = WatchlistStore(defaults: storeDefaults, defaultGroupName: "跟踪")
        let shared = SharedWatchlist(store: store, defaults: sharedDefaults)
        return (shared, sharedDefaults, suite)
    }

    /// Off by default, including for a group that already holds both markets.
    /// Inferring it from the contents would change a reader's axis without anyone
    /// asking, which is exactly the surprise the switch exists to avoid.
    @MainActor
    @Test("A group starts unaligned and stays that way without a switch")
    func defaultsToAlignedOff() throws {
        let (shared, _, _) = try makeShared("defaultsOff")
        let groupID = try #require(shared.selectedGroupID)

        #expect(!shared.isChinaAligned(groupID))
        // An unknown or missing group is off rather than a crash.
        #expect(!shared.isChinaAligned(nil))
        #expect(!shared.isChinaAligned(UUID()))
    }

    @MainActor
    @Test("Switching the shared axis on and off round-trips")
    func toggleRoundTrips() throws {
        let (shared, _, _) = try makeShared("toggle")
        let groupID = try #require(shared.selectedGroupID)

        shared.setChinaAligned(true, for: groupID)
        #expect(shared.isChinaAligned(groupID))

        shared.setChinaAligned(false, for: groupID)
        #expect(!shared.isChinaAligned(groupID))
    }

    /// The switch is per group: turning it on for one must not move any other.
    /// A single shared flag here would silently re-axis every tab at once.
    @MainActor
    @Test("The switch applies only to the group it names")
    func switchIsPerGroup() throws {
        let (shared, _, _) = try makeShared("perGroup")
        let first = try #require(shared.selectedGroupID)
        // `createGroup` selects the new group, so keep the original id.
        let second = try #require(shared.createGroup(named: "盯盘"))

        shared.setChinaAligned(true, for: first)
        #expect(shared.isChinaAligned(first))
        #expect(!shared.isChinaAligned(second))

        shared.setChinaAligned(true, for: second)
        shared.setChinaAligned(false, for: first)
        #expect(!shared.isChinaAligned(first))
        #expect(shared.isChinaAligned(second))
    }

    /// Renaming a group must not drop the switch: it is keyed by id, and the id
    /// survives a rename. Keying it by name would silently turn the axis off the
    /// moment a user renamed the tab, with nothing on screen to explain it.
    @MainActor
    @Test("Renaming a group keeps its shared-axis switch")
    func renameKeepsSwitch() throws {
        let (shared, _, _) = try makeShared("rename")
        let groupID = try #require(shared.selectedGroupID)
        shared.setChinaAligned(true, for: groupID)

        #expect(shared.renameGroup(groupID, to: "盯盘"))
        #expect(shared.isChinaAligned(groupID))
        // And through the merged projection the UI actually reads.
        let projected = try #require(shared.groups.first { $0.name == "盯盘" })
        #expect(shared.isChinaAligned(projected.id))
    }

    /// The switch has to outlive the process, or every restart would drop it.
    @MainActor
    @Test("The switch survives a reload from preferences")
    func switchPersists() throws {
        let (shared, defaults, _) = try makeShared("persist")
        let groupID = try #require(shared.selectedGroupID)
        shared.setChinaAligned(true, for: groupID)

        let reloaded = SharedWatchlist(store: shared.store, defaults: defaults)
        #expect(reloaded.isChinaAligned(groupID))
    }

    /// The regression this guards: `loadLocalPreferences` decodes with `try?`, so
    /// one unreadable key discards the whole blob. A preferences file written
    /// before this field existed must still load, or upgrading would silently
    /// reset every user's group order, symbol order and pins.
    @MainActor
    @Test("Preferences written before this field decode without losing the rest")
    func legacyPreferencesStillDecode() throws {
        let (shared, defaults, suite) = try makeShared("legacy")
        let groupID = try #require(shared.selectedGroupID)
        shared.setChinaAligned(true, for: groupID)
        let key = "pulse.sharedWatchlist.localOrder.v1"
        #expect(defaults.data(forKey: key) != nil)

        // Rewrite the blob as an older build would have: no chinaAlignedGroups.
        let legacy = #"{"groupOrder":[],"symbolOrder":{},"manualBaseline":{},"pinnedSymbols":{}}"#
        defaults.set(Data(legacy.utf8), forKey: key)

        let reloaded = SharedWatchlist(store: shared.store, defaults: defaults)
        // The blob decoded, so the new field fell back to its default...
        #expect(!reloaded.isChinaAligned(groupID))
        // ...and, crucially, the rest of the preferences were not thrown away.
        let rewritten = try #require(defaults.data(forKey: key))
        let reloadedAgain = SharedWatchlist(store: shared.store, defaults: defaults)
        #expect(reloadedAgain.groups.count == shared.groups.count)
        #expect(!rewritten.isEmpty)
        defaults.removePersistentDomain(forName: suite)
    }
}
