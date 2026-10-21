import Foundation
import Observation
import PulseCore

@MainActor
@Observable
final class FuyaoFinancialsController {
    struct State {
        var statements: [FuyaoStatementKind: FuyaoTimed<[FuyaoFinancialPeriod]>] = [:]
        var valuation: FuyaoTimed<FuyaoValuation?>?
        var errors: [String: String] = [:]
        var loading = false
        var attemptedAt: Date?
    }
    private(set) var states: [SymbolID: State] = [:]
    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var tasks: [SymbolID: Task<Void, Never>] = [:]
    init(provider: FuyaoProvider, available: @escaping () -> Bool) { self.provider = provider; self.available = available }
    func reset() { epoch += 1; tasks.values.forEach { $0.cancel() }; tasks = [:]; states = [:] }
    private func valid(_ value: Int) -> Bool { value == epoch && available() && !Task.isCancelled }
    func load(_ symbol: SymbolID, force: Bool = false) async {
        guard available() else { return }
        if let task = tasks[symbol] { await task.value; return }
        if !force, let attempt = states[symbol]?.attemptedAt, Date.now.timeIntervalSince(attempt) < 3_600 { return }
        let captured = epoch
        var state = states[symbol] ?? State(); state.loading = true; state.errors = [:]; states[symbol] = state
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.epoch == captured { self.states[symbol]?.loading = false; self.states[symbol]?.attemptedAt = .now; self.tasks[symbol] = nil } }
            for kind in FuyaoStatementKind.allCases {
                do {
                    let rows = try await self.provider.financialStatement(kind, for: symbol)
                    guard self.valid(captured) else { return }
                    self.states[symbol]?.statements[kind] = rows
                } catch {
                    guard self.valid(captured) else { return }
                    self.states[symbol]?.errors[kind.title] = FuyaoResearchController.message(error)
                    if case ProviderError.rateLimited = error { return }
                }
            }
            do {
                let result = try await self.provider.valuation(for: symbol)
                guard self.valid(captured) else { return }
                self.states[symbol]?.valuation = result
            } catch {
                guard self.valid(captured) else { return }
                self.states[symbol]?.errors["估值"] = FuyaoResearchController.message(error)
            }
        }
        tasks[symbol] = task; await task.value
    }
}
