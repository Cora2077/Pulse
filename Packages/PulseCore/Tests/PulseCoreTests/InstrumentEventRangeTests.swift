import Foundation
import Testing
@testable import PulseCore

struct InstrumentEventRangeTests {
    @Test("Manual date ranges validate and round-trip; old milestones remain valid")
    func rangeValidation() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var event = InstrumentEvent(kind: .other, date: start, title: "Observe", endDate: start.addingTimeInterval(86_400))
        #expect(event.normalized() == event)
        #expect(try JSONDecoder().decode(InstrumentEvent.self, from: JSONEncoder().encode(event)) == event)
        event.endDate = start.addingTimeInterval(-1)
        #expect(event.normalized() == nil)
        event.endDate = Date(timeIntervalSince1970: .infinity)
        #expect(event.normalized() == nil)
        event.endDate = nil
        let data = try JSONEncoder().encode(event)
        #expect(!String(decoding: data, as: UTF8.self).contains("endDate"))
        #expect(try JSONDecoder().decode(InstrumentEvent.self, from: data).endDate == nil)
    }

    @MainActor
    @Test("Event ranges survive local storage, sync, and archive with version gates")
    func rangePersistence() throws {
        let suite = "EventRangeTests.\(UUID())"
        let restoreSuite = suite + ".restore"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let restoreDefaults = try #require(UserDefaults(suiteName: restoreSuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            restoreDefaults.removePersistentDomain(forName: restoreSuite)
        }
        let store = WatchlistStore(defaults: defaults)
        let symbol = SymbolID(market: .us, code: "RANGE-FIXTURE")
        store.add(SymbolInfo(symbol: symbol, name: "Range fixture"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = InstrumentEvent(kind: .other, date: start, title: "Observe", endDate: start.addingTimeInterval(86_400))
        #expect(store.setInstrumentEvent(event, for: symbol))
        let savedEvent = try #require(store.item(for: symbol)?.events.first)
        #expect(savedEvent.endDate == event.endDate)
        #expect(WatchlistStore(defaults: defaults).item(for: symbol)?.events == [savedEvent])
        let wire = try WatchlistSyncWireCodec.decode(WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: store.syncSnapshot()))
        #expect(wire.version == 6)
        #expect(wire.snapshot.items.first?.events == [savedEvent])
        let archive = store.archive()
        #expect(archive.version == 5)
        let restored = WatchlistStore(defaults: restoreDefaults)
        restored.merge(try WatchlistArchive.decoded(from: archive.encoded()))
        #expect(restored.item(for: symbol)?.events == [savedEvent])
        var invalid = event
        invalid.endDate = start.addingTimeInterval(-1)
        #expect(!store.setInstrumentEvent(invalid, for: symbol))
        #expect(store.item(for: symbol)?.events == [savedEvent])
    }
}
