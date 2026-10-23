import Foundation
import Observation
import PulseCore

@MainActor
@Observable
final class FuyaoFinancialsController {
    struct State {
        var statements: [FuyaoStatementKind: FuyaoTimed<[FuyaoFinancialPeriod]>] = [:]
        var valuation: FuyaoTimed<FuyaoValuation?>?
        /// 五类财务指标，按报告期降序（最新在前）。每个报告期是一次单独请求。
        var indicators: [FuyaoIndicatorSet] = []
        var errors: [String: String] = [:]
        var loading = false
        var attemptedAt: Date?
        /// 已尝试过的报告期，避免每次进页面重复拉同一批。
        var attemptedReports: Set<String> = []
    }
    private(set) var states: [SymbolID: State] = [:]
    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var tasks: [SymbolID: Task<Void, Never>] = [:]
    init(provider: FuyaoProvider, available: @escaping () -> Bool) { self.provider = provider; self.available = available }
    /// 指标每个报告期一次请求，单码端点不能批取。上限压在 4 期：
    /// 更早的期次对"看趋势"没有增量，却会按几何级数消耗请求预算。
    static let indicatorReportLimit = 4
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

extension FuyaoFinancialsController {
    /// 为已有报表的最新若干报告期补齐五类指标。
    ///
    /// 报告期**从利润表推导**，不自行推算"今天是几月所以该有中报"：上游某期
    /// 没披露时，推算出来的期次只会换来一个空结果。认不出的期次标签直接跳过。
    func loadIndicators(_ symbol: SymbolID, force: Bool = false) async {
        guard available() else { return }
        guard let state = states[symbol] else { return }
        guard let income = state.statements[.income]?.value, !income.isEmpty else { return }
        let reports: [String] = income
            .compactMap { FuyaoIndicatorCatalog.report(fiscalYear: $0.fiscalYear, fiscalPeriod: $0.fiscalPeriod) }
            .prefix(Self.indicatorReportLimit)
            .map { $0 }
        // Only a report period that actually landed is remembered. A failed fetch
        // is retried the next time the section opens instead of being marked done.
        let pending = reports.filter { force || !state.attemptedReports.contains($0) }
        guard !pending.isEmpty else { return }
        let captured = epoch
        for report in pending {
            do {
                let set = try await provider.financialIndicators(for: symbol, report: report)
                guard valid(captured) else { return }
                var rows = states[symbol]?.indicators ?? []
                rows.removeAll { $0.report == set.report }
                rows.append(set)
                rows.sort { $0.report > $1.report }
                states[symbol]?.indicators = rows
                states[symbol]?.attemptedReports.insert(set.report)
                states[symbol]?.errors["指标 \(report)"] = nil
            } catch is CancellationError {
                return
            } catch {
                guard valid(captured) else { return }
                states[symbol]?.errors["指标 \(report)"] = FuyaoResearchController.message(error)
                // 限流后停止后续期次，不再制造请求风暴。
                if case ProviderError.rateLimited = error { return }
            }
        }
    }
}
