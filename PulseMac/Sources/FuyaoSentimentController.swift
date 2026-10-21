import Foundation
import Observation
import PulseCore

@MainActor
@Observable
final class FuyaoSentimentController {
    struct State {
        var statistics: FuyaoTimed<FuyaoMarketStatistics>?
        var pools: [FuyaoLimitKind: FuyaoTimed<FuyaoLimitPool>] = [:]
        var errors: [String: String] = [:]
        var loading = false
        var attemptedAt: Date?
    }
    private(set) var states: [String: State] = [:]
    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    init(provider: FuyaoProvider, available: @escaping () -> Bool) { self.provider = provider; self.available = available }
    func key(_ date: Date?) -> String { date.map(ResearchFormat.day) ?? "latest" }
    var latest: State { states["latest"] ?? .init() }
    func reset() { epoch += 1; tasks.values.forEach { $0.cancel() }; tasks = [:]; states = [:] }
    private func valid(_ value: Int) -> Bool { value == epoch && available() && !Task.isCancelled }

    func load(date: Date? = nil, force: Bool = false) async {
        guard available() else { return }
        let key = key(date)
        if let task = tasks[key] { await task.value; return }
        if !force, let attempt = states[key]?.attemptedAt, Date.now.timeIntervalSince(attempt) < 300 { return }
        let captured = epoch
        var state = states[key] ?? State(); state.loading = true; state.errors = [:]; states[key] = state
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.epoch == captured { self.states[key]?.loading = false; self.states[key]?.attemptedAt = .now; self.tasks[key] = nil } }
            do {
                let statistics = try await self.provider.marketStatistics(date: date)
                guard self.valid(captured) else { return }
                if self.states[key]?.statistics?.value.tradeDate != statistics.value.tradeDate { self.states[key]?.pools = [:] }
                self.states[key]?.statistics = statistics
                for kind in FuyaoLimitKind.allCases {
                    do {
                        let pool = try await self.provider.limitPool(kind, tradeDate: statistics.value.tradeDate)
                        guard self.valid(captured) else { return }
                        self.states[key]?.pools[kind] = pool
                    } catch {
                        guard self.valid(captured) else { return }
                        self.states[key]?.errors[kind.title] = FuyaoResearchController.message(error)
                        if case ProviderError.rateLimited = error { return }
                    }
                }
            } catch {
                guard self.valid(captured) else { return }
                self.states[key]?.errors["统计"] = FuyaoResearchController.message(error)
            }
        }
        tasks[key] = task; await task.value
    }
    func more(kind: FuyaoLimitKind, date: Date?) async {
        let key = key(date)
        guard available(), states[key]?.loading != true, let previous = states[key]?.pools[kind], previous.value.hasMore else { return }
        let captured = epoch
        states[key]?.loading = true
        defer { if epoch == captured { states[key]?.loading = false } }
        do {
            let next = try await provider.limitPool(kind, tradeDate: previous.value.tradeDate, page: previous.value.page + 1)
            guard valid(captured) else { return }
            var seen = Set(previous.value.stocks.map(\.thscode))
            let rows = previous.value.stocks + next.value.stocks.filter { seen.insert($0.thscode).inserted }
            let pool = FuyaoLimitPool(kind: kind, tradeDate: previous.value.tradeDate, dataTime: next.dataTime,
                stocks: rows, total: next.value.total, page: next.value.page, pages: next.value.pages)
            states[key]?.pools[kind] = .init(value: pool, dataTime: next.dataTime, fetchedAt: next.fetchedAt)
        } catch {
            guard valid(captured) else { return }
            states[key]?.errors[kind.title] = FuyaoResearchController.message(error)
        }
    }
}
