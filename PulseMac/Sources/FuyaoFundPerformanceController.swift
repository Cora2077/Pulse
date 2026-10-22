import Foundation
import Observation
import PulseCore

/// 基金（ETF / LOF）业绩与回撤的缓存。
///
/// 只有场内基金适用：`performance/*` 三个端点都只接受基金代码。指数与股票不进来，
/// 由调用方按 `InstrumentType` 过滤——这里再判断一次是为了防住误调用。
@MainActor
@Observable
final class FuyaoFundPerformanceController {
    struct State {
        var performance: FuyaoFundPerformance?
        var error: String?
        var loading = false
        var attemptedAt: Date?
    }

    private(set) var states: [SymbolID: State] = [:]
    private(set) var epoch = 0

    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private var tasks: [SymbolID: Task<Void, Never>] = [:]

    /// 净值与业绩按小时刷新：净值每天才更新一次，业绩季度才变。
    static let ttl: TimeInterval = 60 * 60

    init(provider: FuyaoProvider, available: @escaping () -> Bool) {
        self.provider = provider
        self.available = available
    }

    func reset() {
        epoch += 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        states = [:]
    }

    private func valid(_ captured: Int) -> Bool { captured == epoch && available() && !Task.isCancelled }

    /// 只有场内基金能查业绩。
    static func supports(_ symbol: SymbolID) -> Bool {
        (symbol.market == .sh || symbol.market == .sz)
            && symbol.indexID == nil
            && symbol.sectorIndex == nil
            && symbol.metalID == nil
            && symbol.cryptoPair == nil
    }

    func load(_ symbol: SymbolID, force: Bool = false) async {
        guard available(), Self.supports(symbol) else { return }
        if let task = tasks[symbol] { await task.value; return }
        if !force, let attempt = states[symbol]?.attemptedAt,
           Date.now.timeIntervalSince(attempt) < Self.ttl,
           states[symbol]?.performance != nil { return }
        let captured = epoch
        var state = states[symbol] ?? State()
        state.loading = true
        state.error = nil
        states[symbol] = state
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == captured {
                    self.states[symbol]?.loading = false
                    self.states[symbol]?.attemptedAt = .now
                    self.tasks[symbol] = nil
                }
            }
            do {
                let result = try await self.provider.fundPerformance(for: symbol)
                guard self.valid(captured) else { return }
                self.states[symbol]?.performance = result
            } catch is CancellationError {
                return
            } catch {
                guard self.valid(captured) else { return }
                // 失败保留上一次成功的数据：业绩不会因为一次网络抖动而变成"没有"。
                self.states[symbol]?.error = FuyaoResearchController.message(error)
            }
        }
        tasks[symbol] = task
        await task.value
    }
}
