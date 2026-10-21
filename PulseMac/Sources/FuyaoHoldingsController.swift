import Foundation
import Observation
import PulseCore

@MainActor
@Observable
final class FuyaoHoldingsController {
    private(set) var reports: [SymbolID: FuyaoFundHoldings] = [:]
    private(set) var types: [SymbolID: InstrumentType] = [:]
    private(set) var errors: [SymbolID: String] = [:]
    private(set) var loading: Set<SymbolID> = []
    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var attempts: [SymbolID: Date] = [:]
    @ObservationIgnored private var tasks: [SymbolID: Task<Void, Never>] = [:]

    init(provider: FuyaoProvider, available: @escaping () -> Bool) {
        self.provider = provider; self.available = available
    }
    func reset() {
        epoch += 1; tasks.values.forEach { $0.cancel() }; tasks = [:]
        reports = [:]; types = [:]; errors = [:]; loading = []; attempts = [:]
    }
    private func valid(_ captured: Int) -> Bool { captured == epoch && available() && !Task.isCancelled }

    func load(_ symbol: SymbolID, knownType: InstrumentType? = nil, force: Bool = false) async {
        guard available() else { return }
        if let task = tasks[symbol] { await task.value; return }
        if !force, let attempt = attempts[symbol], Date.now.timeIntervalSince(attempt) < 3_600 { return }
        let captured = epoch
        loading.insert(symbol); errors[symbol] = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == captured {
                    self.loading.remove(symbol); self.tasks[symbol] = nil; self.attempts[symbol] = .now
                }
            }
            do {
                let type: InstrumentType?
                if symbol.market == .sh || symbol.market == .sz {
                    type = try await self.provider.researchInstrumentType(for: symbol)
                } else { type = knownType }
                guard self.valid(captured) else { return }
                self.types[symbol] = type
                guard type == .etf || type == .fund else { return }
                // This service's exchange-fund holdings query is only wired for
                // mainland funds; an overseas fund stays unresolved.
                guard symbol.market == .sh || symbol.market == .sz else {
                    self.errors[symbol] = "当前暂未接入该市场的基金披露持仓"; return
                }
                let report = try await self.provider.latestFundHoldings(for: symbol)
                guard self.valid(captured) else { return }
                self.reports[symbol] = report
                if report.disclosedWeightPercent == nil {
                    self.errors[symbol] = "披露权重不完整或总和异常，暂不用于穿透估算"
                } else if report.holdings.contains(where: { $0.thscode.split(separator: ".").count != 2 }) {
                    self.errors[symbol] = "部分持仓市场尚未确认，未计入重合敞口"
                }
            } catch {
                guard self.valid(captured) else { return }
                self.errors[symbol] = FuyaoResearchController.message(error)
            }
        }
        tasks[symbol] = task
        await task.value
    }
}
