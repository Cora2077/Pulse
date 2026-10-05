import Foundation

/// Stable identities: legacy data stays unassigned until the user classifies it.
/// Account identity is independent of the source of funding for a trade.
public enum BrokerageAccountID: String, Codable, Sendable, CaseIterable, Identifiable {
    case unassigned
    case financing
    case mengmeng
    public var id: String { rawValue }
}

/// An independently replayed ledger and its account-local watchlists/metadata.
/// Sync keeps the unassigned portfolio in the legacy top-level fields.
public struct BrokerageAccountPortfolio: Codable, Sendable, Equatable {
    public var accountID: BrokerageAccountID
    public var items: [WatchItem]
    public var groups: [WatchlistGroup]
    public var retainedHistoryItems: [WatchItem]
    public var settings: BrokerageAccountSettings?

    public init(accountID: BrokerageAccountID, items: [WatchItem] = [],
                groups: [WatchlistGroup] = [], retainedHistoryItems: [WatchItem] = [],
                settings: BrokerageAccountSettings? = nil) {
        self.accountID = accountID
        self.items = items
        self.groups = groups
        self.retainedHistoryItems = retainedHistoryItems
        self.settings = settings
    }

    public var flatSnapshot: WatchlistSyncSnapshot {
        WatchlistSyncSnapshot(items: items, groups: groups, retainedHistoryItems: retainedHistoryItems,
                              accountSettings: settings)
    }
}
