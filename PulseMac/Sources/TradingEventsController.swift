import Foundation
import Observation
import PulseCore

struct TradingEventEntry: Identifiable {
    let symbol: SymbolID
    let event: InstrumentEvent
    let sourceName: String
    let isForecast: Bool
    let isAutomatic: Bool

    var id: String { "\(symbol.description):\(event.id.uuidString)" }
}

@MainActor
@Observable
final class TradingEventsController {
    private struct RefreshStamp: Codable {
        let symbol: SymbolID
        let date: Date
    }

    private struct Cache: Codable {
        var automatic: [EastmoneyTradingEvents.Record] = []
        var refreshed: [RefreshStamp] = []
    }

    private static let storageKey = "pulse.tradingEvents.cache.v1"
    private static let cacheDuration: TimeInterval = 6 * 60 * 60

    private(set) var isRefreshing = false
    private(set) var error: String?

    @ObservationIgnored private let defaults: UserDefaults
    private var automatic: [EastmoneyTradingEvents.Record] = []
    @ObservationIgnored private var refreshed: [SymbolID: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            automatic = cache.automatic
            refreshed = Dictionary(cache.refreshed.map { ($0.symbol, $0.date) }, uniquingKeysWith: { max($0, $1) })
        }
    }

    func entries(for items: [WatchItem]) -> [TradingEventEntry] {
        let symbols = Set(items.map(\.symbol))
        let calendar = EastmoneyTradingEvents.dateCalendar
        let today = calendar.startOfDay(for: .now)
        let horizon = calendar.date(byAdding: .day, value: 90, to: today) ?? today
        var entries = items.flatMap { item in
            item.events.map {
                TradingEventEntry(symbol: item.symbol, event: $0, sourceName: "手动记录", isForecast: false, isAutomatic: false)
            }
        }
        entries.append(contentsOf: automatic.filter {
            symbols.contains($0.symbol) && $0.event.date >= today && $0.event.date <= horizon
        }.map {
            TradingEventEntry(symbol: $0.symbol, event: $0.event, sourceName: $0.sourceName, isForecast: $0.isForecast, isAutomatic: true)
        })
        var seen: Set<String> = []
        entries = entries.filter { entry in
            let key = "\(entry.symbol.description)|\(entry.event.kind.rawValue)|\(entry.event.date.timeIntervalSince1970)|\(entry.event.endDate.map { String($0.timeIntervalSince1970) } ?? "milestone")|\(entry.event.title.trimmingCharacters(in: .whitespacesAndNewlines))"
            return seen.insert(key).inserted
        }
        return entries.sorted {
            if $0.event.date != $1.event.date { return $0.event.date < $1.event.date }
            if $0.symbol != $1.symbol { return $0.symbol.description < $1.symbol.description }
            return $0.id < $1.id
        }
    }

    func refresh(items: [WatchItem], force: Bool = false) async {
        guard !isRefreshing else { return }
        let now = Date.now
        let stale = Array(Set(items.map(\.symbol).filter {
            EastmoneyTradingEvents.supports($0)
                && (force || (refreshed[$0].map { now.timeIntervalSince($0) >= Self.cacheDuration } ?? true))
        })).sorted { $0.description < $1.description }
        guard !stale.isEmpty else { return }

        isRefreshing = true
        error = nil
        defer { isRefreshing = false }

        let updates = await EastmoneyTradingEvents.fetch(symbols: stale, now: now)
        var successes: [SymbolID: Set<EastmoneyTradingEvents.Source>] = [:]
        var failedSources: Set<String> = []
        for update in updates {
            if !update.failedSymbols.isEmpty, let message = update.errorMessage { failedSources.insert(message) }
            for symbol in update.succeededSymbols {
                successes[symbol, default: []].insert(update.source)
            }
            guard !update.succeededSymbols.isEmpty else { continue }
            automatic.removeAll { $0.source == update.source && update.succeededSymbols.contains($0.symbol) }
            automatic.append(contentsOf: update.records)
        }

        for symbol in stale where successes[symbol]?.count == EastmoneyTradingEvents.Source.allCases.count {
            refreshed[symbol] = now
        }
        if failedSources.isEmpty {
            error = nil
        } else {
            error = "部分自动事件更新失败（\(failedSources.sorted().joined(separator: "、"))），已保留原有缓存。"
        }
        persist()
    }

    private func persist() {
        let cache = Cache(
            automatic: automatic,
            refreshed: refreshed.map { RefreshStamp(symbol: $0.key, date: $0.value) }
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
