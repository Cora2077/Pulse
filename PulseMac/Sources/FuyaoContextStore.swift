import Foundation
import Observation
import PulseCore

/// Local, immutable research notes. These never alter a plan or financial ledger.
@MainActor
@Observable
final class FuyaoContextStore {
    private(set) var records: [FuyaoMarketContext] = []
    private(set) var firstEnabledAt: Date?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "pulse.fuyao.marketContexts.v1"
    @ObservationIgnored private var known: Set<FuyaoContextKey> = []
    @ObservationIgnored private var initialized = false
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var enabledSince: Date?
    private struct Archive: Codable { let firstEnabledAt: Date?; let records: [FuyaoMarketContext] }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey), let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            firstEnabledAt = archive.firstEnabledAt
            var seen: Set<FuyaoContextKey> = []
            records = archive.records.filter { seen.insert($0.key).inserted }.sorted { $0.capturedAt > $1.capturedAt }
        }
    }
    func initialize(snapshot: WatchlistSyncSnapshot, enabled: Bool, now: Date = .now) {
        known = Set(FuyaoContextEvent.events(in: snapshot).map(\.key))
        initialized = true; self.enabled = enabled; enabledSince = enabled ? now : nil
        if enabled, firstEnabledAt == nil { firstEnabledAt = now; save() }
    }
    func availabilityChanged(snapshot: WatchlistSyncSnapshot, enabled: Bool, now: Date = .now) {
        guard self.enabled != enabled || !initialized else { return }
        initialize(snapshot: snapshot, enabled: enabled, now: now)
    }
    func observe(_ snapshot: WatchlistSyncSnapshot, now: Date = .now, capture: (FuyaoContextKey, Date) -> FuyaoMarketContext) {
        let events = FuyaoContextEvent.events(in: snapshot)
        guard initialized else { initialize(snapshot: snapshot, enabled: enabled, now: now); return }
        let new = events.filter { !known.contains($0.key) }
        // Keep removed identities seen for the session: undo, import and account
        // changes must not rewrite a context that was captured the first time.
        known.formUnion(events.map(\.key))
        guard enabled, let enabledSince else { return }
        var changed = false
        for event in new {
            guard event.createdAt >= enabledSince, event.createdAt <= now,
                  records.allSatisfy({ $0.key != event.key }) else { continue }
            // A backdated fill's recording time is not its market context.
            if let date = event.tradeDate, !Calendar.current.isDate(date, inSameDayAs: now) { continue }
            let record = capture(event.key, now)
            guard record.key == event.key, record.capturedAt == now else { continue }
            records.append(record); changed = true
        }
        if changed {
            records.sort { $0.capturedAt > $1.capturedAt }
            // This is a bounded local research cache, separate from the ledger.
            records = Array(records.prefix(1_000))
            save()
        }
    }
    func context(for key: FuyaoContextKey) -> FuyaoMarketContext? { records.first { $0.key == key } }
    private func save() {
        guard let data = try? JSONEncoder().encode(Archive(firstEnabledAt: firstEnabledAt, records: records)) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
