import Foundation
import Testing
@testable import PulseCore

@Suite("Trading metadata persistence")
struct TradingMetadataPersistenceTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    @Test("Old watch items and reviews decode without the new fields")
    func legacyDecode() throws {
        let legacyItem = #"{"symbol":{"market":"us","code":"AAPL"},"displayName":"Apple","addedAt":0,"lots":[],"transactions":[]}"#
        let item = try JSONDecoder().decode(WatchItem.self, from: Data(legacyItem.utf8))
        #expect(item.tradingProfile == nil)
        #expect(item.events.isEmpty)

        let legacyReview = #"{"followedPlan":true,"retrospective":"Kept the limit"}"#
        let review = try JSONDecoder().decode(PositionTransactionReview.self, from: Data(legacyReview.utf8))
        #expect(review.strategy == nil)
    }

    @MainActor
    @Test("Profile, events, and strategy survive store, archive, wire, and agent readback")
    func fullRoundTrip() throws {
        let suite = "TradingMetadataPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        let transaction = PositionTransaction(kind: .buy, price: 200, quantity: 1)
        store.addTransaction(symbol, transaction)
        var writes = 0
        store.onLocalSyncChange = { _ in writes += 1 }

        let profile = TradingProfile(sector: "  Software  ", stopPrice: 180, targetPrice: 240)
        #expect(store.setTradingProfile(profile, for: symbol))
        #expect(store.item(for: symbol)?.tradingProfile == TradingProfile(
            sector: "Software", stopPrice: 180, targetPrice: 240
        ))
        let writesAfterProfile = writes
        #expect(store.setTradingProfile(profile, for: symbol))
        #expect(writes == writesAfterProfile)

        let event = InstrumentEvent(
            kind: .earnings,
            date: Date(timeIntervalSince1970: 1_800_000_000),
            title: "  Quarterly results  ",
            sourceURL: " https://example.com/earnings ",
            note: "  Before market  "
        )
        #expect(store.setInstrumentEvent(event, for: symbol))
        let savedEvent = try #require(store.item(for: symbol)?.events.first)
        #expect(savedEvent.title == "Quarterly results")
        #expect(savedEvent.sourceURL == "https://example.com/earnings")
        #expect(savedEvent.note == "Before market")
        let writesAfterEvent = writes
        #expect(store.setInstrumentEvent(event, for: symbol))
        #expect(writes == writesAfterEvent)

        #expect(store.updateTransactionReview(
            symbol,
            id: transaction.id,
            note: nil,
            review: PositionTransactionReview(strategy: "  Breakout  ")
        ))
        let saved = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let savedItem = try #require(saved.item(for: symbol))
        #expect(savedItem.tradingProfile?.sector == "Software")
        #expect(savedItem.events == [savedEvent])
        #expect(savedItem.transactions.first?.review?.strategy == "Breakout")

        let wire = try WatchlistSyncWireCodec.encode(deviceID: "metadata-test", snapshot: saved.syncSnapshot())
        let decodedWire = try WatchlistSyncWireCodec.decode(wire)
        #expect(decodedWire.version == 6)
        #expect(decodedWire.snapshot == saved.syncSnapshot())

        let archive = saved.archive()
        #expect(archive.version == 5)
        let decodedArchive = try WatchlistArchive.decoded(from: archive.encoded())
        let restoredDefaults = try #require(UserDefaults(suiteName: "\(suite).restore"))
        defer { restoredDefaults.removePersistentDomain(forName: "\(suite).restore") }
        let restored = WatchlistStore(defaults: restoredDefaults, defaultGroupName: "Core")
        restored.merge(decodedArchive)
        let restoredItem = try #require(restored.item(for: symbol))
        #expect(restoredItem.tradingProfile == savedItem.tradingProfile)
        #expect(restoredItem.events == savedItem.events)
        #expect(restoredItem.transactions.first?.review?.strategy == "Breakout")

        let agentPosition = try #require(AgentWatchlistCommands(store: saved).listPositions().first)
        #expect(agentPosition.tradingProfile == savedItem.tradingProfile)
        #expect(agentPosition.events == savedItem.events)
        #expect(agentPosition.transactions.first?.review?.strategy == "Breakout")

        saved.remove(symbol)
        #expect(saved.retainedHistoryItem(for: symbol)?.tradingProfile == savedItem.tradingProfile)
        var revisedEvent = savedEvent
        revisedEvent.title = "Updated results date"
        #expect(saved.setTradingProfile(.init(sector: "Technology"), for: symbol))
        #expect(saved.setInstrumentEvent(revisedEvent, for: symbol))
        #expect(saved.updateTransactionReview(
            symbol,
            id: transaction.id,
            note: nil,
            review: PositionTransactionReview(strategy: "  Earnings catalyst  ")
        ))
        let dormantReload = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let dormant = try #require(dormantReload.retainedHistoryItem(for: symbol))
        #expect(dormant.tradingProfile?.sector == "Technology")
        #expect(dormant.events.first?.title == "Updated results date")
        #expect(dormant.transactions.first?.review?.strategy == "Earnings catalyst")
    }

    @Test("Concurrent event additions merge while an explicit deletion wins")
    func concurrentEventMergeAndDeletion() throws {
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let deleted = InstrumentEvent(
            kind: .dividend,
            date: Date(timeIntervalSince1970: 100),
            title: "Old dividend",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let edited = InstrumentEvent(
            kind: .earnings,
            date: Date(timeIntervalSince1970: 200),
            title: "Original",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        var localEdit = edited
        localEdit.title = "Local edit"
        localEdit.updatedAt = Date(timeIntervalSince1970: 20)
        var remoteEdit = edited
        remoteEdit.title = "Remote edit"
        remoteEdit.updatedAt = Date(timeIntervalSince1970: 30)
        var concurrentDeletedEdit = deleted
        concurrentDeletedEdit.title = "Concurrent dividend edit"
        concurrentDeletedEdit.updatedAt = Date(timeIntervalSince1970: 300)
        let localAddition = InstrumentEvent(
            kind: .other, date: Date(timeIntervalSince1970: 300), title: "Local event"
        )
        let remoteAddition = InstrumentEvent(
            kind: .unlock, date: Date(timeIntervalSince1970: 400), title: "Remote event"
        )
        let base = WatchlistSyncSnapshot(
            items: [WatchItem(
                symbol: symbol,
                displayName: "Apple",
                tradingProfile: TradingProfile(sector: "Software", stopPrice: 180, targetPrice: 240),
                events: [deleted, edited]
            )],
            groups: [group]
        )
        var localProfile = try #require(base.items.first?.tradingProfile)
        localProfile.stopPrice = 175
        let local = WatchlistSyncSnapshot(
            items: [WatchItem(
                symbol: symbol,
                displayName: "Apple",
                tradingProfile: localProfile,
                events: [localEdit, localAddition]
            )],
            groups: [group]
        )
        var remoteProfile = try #require(base.items.first?.tradingProfile)
        remoteProfile.targetPrice = 260
        let remote = WatchlistSyncSnapshot(
            items: [WatchItem(
                symbol: symbol,
                displayName: "Apple",
                tradingProfile: remoteProfile,
                events: [concurrentDeletedEdit, remoteEdit, remoteAddition]
            )],
            groups: [group]
        )

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote).snapshot
        let events = try #require(merged.items.first?.events)
        #expect(!events.contains { $0.id == deleted.id })
        #expect(events.first { $0.id == edited.id }?.title == "Remote edit")
        #expect(events.contains { $0.id == localAddition.id })
        #expect(events.contains { $0.id == remoteAddition.id })
        #expect(merged.items.first?.tradingProfile == TradingProfile(
            sector: "Software", stopPrice: 175, targetPrice: 260
        ))
        #expect(WatchlistSyncMerge.merge(base: base, local: remote, remote: local).snapshot == merged)
        #expect(WatchlistSyncMerge.merge(base: base, local: merged, remote: remote).snapshot == merged)
    }

    @MainActor
    @Test("Malformed profile and event values are rejected")
    func malformedInputs() throws {
        let suite = "TradingMetadataInvalidTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))

        let invalidStop = TradingProfile(sector: "Software", stopPrice: 0)
        let invalidTarget = TradingProfile(targetPrice: .infinity)
        let invalidNaNStop = TradingProfile(stopPrice: .nan)
        let acceptedInvalidStop = store.setTradingProfile(invalidStop, for: symbol)
        let acceptedInfiniteTarget = store.setTradingProfile(invalidTarget, for: symbol)
        let acceptedNaNStop = store.setTradingProfile(invalidNaNStop, for: symbol)
        #expect(!acceptedInvalidStop)
        #expect(!acceptedInfiniteTarget)
        #expect(!acceptedNaNStop)
        #expect(store.item(for: symbol)?.tradingProfile == nil)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!store.setInstrumentEvent(.init(kind: .earnings, date: date, title: "   "), for: symbol))
        #expect(!store.setInstrumentEvent(.init(
            kind: .other, date: date, title: "Source", sourceURL: "ftp://example.com/file"
        ), for: symbol))
        #expect(!store.setInstrumentEvent(.init(
            kind: .other, date: date, title: "Source", sourceURL: "https://bad host/path"
        ), for: symbol))
        #expect(!store.setInstrumentEvent(.init(
            kind: .other, date: date, title: "Source", updatedAt: Date(timeIntervalSince1970: .nan)
        ), for: symbol))
        #expect(store.item(for: symbol)?.events.isEmpty == true)
    }
}
