import Foundation
import Testing
@testable import PulseCore

@Suite("Chart drawing persistence")
struct ChartDrawingStoreTests {
    @MainActor
    @Test("Edits keep identity, deletions stay tombstoned, and drawings survive removal")
    func editsAndRemovalKeepDrawingHistory() throws {
        let suite = "ChartDrawingStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        let symbol = SymbolID(market: .us, code: "AAPL")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))

        let createdAt = Date(timeIntervalSince1970: 100)
        let drawing = ChartDrawing(
            id: UUID(),
            geometry: .horizontal(price: 200),
            createdAt: createdAt
        )
        var syncWrites = 0
        store.onLocalSyncChange = { _ in syncWrites += 1 }

        #expect(store.setChartDrawing(drawing, for: symbol))
        let first = try #require(store.item(for: symbol)?.drawings.first)
        #expect(first.createdAt == createdAt)
        #expect(first.updatedAt > createdAt)
        #expect(first.note == nil)

        store.remove(symbol)
        #expect(store.item(for: symbol) == nil)
        #expect(store.retainedHistoryItem(for: symbol)?.drawings.count == 1)

        let edited = ChartDrawing(
            id: drawing.id,
            geometry: .horizontal(price: 201),
            note: "  resistance  ",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        #expect(store.setChartDrawing(edited, for: symbol))
        let retainedEdit = try #require(store.retainedHistoryItem(for: symbol)?.drawings.first)
        #expect(retainedEdit.id == drawing.id)
        #expect(retainedEdit.geometry == .horizontal(price: 201))
        #expect(retainedEdit.createdAt == createdAt)
        #expect(retainedEdit.note == "resistance")
        #expect(store.retainedHistoryItem(for: symbol)?.drawings.count == 1)

        #expect(store.deleteChartDrawing(drawing.id, for: symbol))
        let deleted = try #require(store.retainedHistoryItem(for: symbol)?.drawings.first)
        #expect(deleted.isDeleted)
        #expect(!store.setChartDrawing(edited, for: symbol))
        #expect(!store.deleteChartDrawing(drawing.id, for: symbol))
        #expect(!store.setChartDrawing(
            ChartDrawing(geometry: .horizontal(price: 0)),
            for: symbol
        ))

        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        #expect(store.item(for: symbol)?.drawings == [deleted])
        #expect(syncWrites == 5)
    }
}
