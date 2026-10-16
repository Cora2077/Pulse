import Foundation
import PulseCore
@testable import PulseSync

/// Deterministic fixtures for the sync tests.
///
/// Every snapshot produced here satisfies the same validation sync enforces
/// (`WatchlistSyncWireCodec` round-trip plus `LocalBackupStore.validateSnapshot`),
/// so a test that passes is a test on data the real app could actually produce.
enum Fixtures {
    static let symbolA = SymbolID(market: .us, code: "AAPL")
    static let symbolB = SymbolID(market: .us, code: "MSFT")
    static let symbolC = SymbolID(market: .us, code: "NVDA")

    /// A minimal, valid snapshot: one group holding exactly the items present.
    static func snapshot(
        symbols: [SymbolID] = [symbolA],
        groupName: String = "Main",
        transactions: [SymbolID: [PositionTransaction]] = [:],
        thesis: String? = nil
    ) -> WatchlistSyncSnapshot {
        let items = symbols.map { symbol in
            WatchItem(
                symbol: symbol,
                displayName: symbol.displayCode,
                transactions: transactions[symbol] ?? [],
                thesis: thesis
            )
        }
        let group = WatchlistGroup(name: groupName, symbols: symbols)
        return WatchlistSyncSnapshot(items: items, groups: [group])
    }

    /// A snapshot with an added symbol, standing in for "the user edited the
    /// watchlist on this device".
    static func snapshotWithAddedSymbol(_ symbol: SymbolID, base: WatchlistSyncSnapshot? = nil) -> WatchlistSyncSnapshot {
        let existing = base ?? snapshot()
        var items = existing.items
        if !items.contains(where: { $0.symbol == symbol }) {
            items.append(WatchItem(symbol: symbol, displayName: symbol.displayCode))
        }
        var groups = existing.groups
        let index = groups.firstIndex(where: { $0.name == "Main" }) ?? 0
        if !groups[index].symbols.contains(symbol) {
            groups[index].symbols.append(symbol)
        }
        return WatchlistSyncSnapshot(items: items, groups: groups)
    }

    /// A transaction with an explicit ID, so a test can assert that the same
    /// price and size on different IDs are two distinct facts.
    static func transaction(
        id: UUID = UUID(),
        price: Double,
        quantity: Double
    ) -> PositionTransaction {
        PositionTransaction(id: id, kind: .buy, price: price, quantity: quantity)
    }

    /// A unique temp directory per test, so no test can observe another's files
    /// and no test touches any real application data.
    static func makeTempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsesync-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeDirectory(_ url: URL) {
        // Guard: only ever remove a path this fixture helper created.
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("pulsesync-tests", isDirectory: true).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent() == parent,
              resolved.lastPathComponent.count > 36,
              UUID(uuidString: String(resolved.lastPathComponent.suffix(36))) != nil else { return }
        try? FileManager.default.removeItem(at: resolved)
    }
}
