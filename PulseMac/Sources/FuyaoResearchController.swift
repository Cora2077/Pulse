import Foundation
import Observation
import PulseCore

/// Public market research stays separate from the account ledger and quote loop.
@MainActor
@Observable
final class FuyaoResearchController {
    struct Intelligence {
        var type: InstrumentType?
        var news: FuyaoTimed<[FuyaoNewsItem]>?
        var anomalies: FuyaoTimed<[FuyaoAnomaly]>?
        var ranking: FuyaoTimed<[FuyaoRankPoint]>?
        var hotStock: FuyaoHotStock?
        var hotListTime: Date?
        var hotListLoaded = false
        var errors: [String: String] = [:]
        var loading = false
        var attemptedAt: Date?
    }

    private(set) var intelligence: [SymbolID: Intelligence] = [:]
    private(set) var generation = 0
    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private var tasks: [SymbolID: Task<Void, Never>] = [:]
    @ObservationIgnored private var hotList: FuyaoTimed<[FuyaoHotStock]>?
    @ObservationIgnored private var hotListTask: Task<FuyaoTimed<[FuyaoHotStock]>, Error>?
    @ObservationIgnored lazy var boards = FuyaoBoardsController(provider: provider, available: available)
    @ObservationIgnored lazy var holdings = FuyaoHoldingsController(provider: provider, available: available)
    @ObservationIgnored lazy var sentiment = FuyaoSentimentController(provider: provider, available: available)
    @ObservationIgnored lazy var financials = FuyaoFinancialsController(provider: provider, available: available)
    /// 除权事件与研究缓存同生命周期：换源、换 Key、停用都会清空它。
    @ObservationIgnored lazy var corporateActions = FuyaoCorporateActionsController(provider: provider, available: available)
    @ObservationIgnored lazy var dragonTiger = FuyaoDragonTigerController(provider: provider, available: available)
    @ObservationIgnored lazy var fundPerformance = FuyaoFundPerformanceController(provider: provider, available: available)
    @ObservationIgnored lazy var ipo = FuyaoIPOController(provider: provider, available: available)

    init(provider: FuyaoProvider, available: @escaping () -> Bool) {
        self.provider = provider
        self.available = available
    }

    func reset() {
        boards.reset()
        holdings.reset()
        sentiment.reset()
        financials.reset()
        corporateActions.reset()
        dragonTiger.reset()
        fundPerformance.reset()
        ipo.reset()
        generation += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        hotListTask?.cancel()
        hotListTask = nil
        hotList = nil
        intelligence.removeAll()
    }

    /// A caller leaving the page does not cancel another window's shared load.
    /// Credential/source changes cancel every outstanding load through reset().
    func loadIntelligence(_ symbol: SymbolID, force: Bool = false) async {
        guard available(), (symbol.market == .sh || symbol.market == .sz) else { return }
        if let task = tasks[symbol] { await task.value; return }
        if !force, let attempted = intelligence[symbol]?.attemptedAt,
           Date.now.timeIntervalSince(attempted) < 120 { return }
        let epoch = generation
        var state = intelligence[symbol] ?? Intelligence()
        state.loading = true
        state.errors = [:]
        intelligence[symbol] = state
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchIntelligence(symbol, epoch: epoch)
            guard self.generation == epoch else { return }
            self.intelligence[symbol]?.loading = false
            self.intelligence[symbol]?.attemptedAt = .now
            self.tasks[symbol] = nil
        }
        tasks[symbol] = task
        await task.value
    }

    private func canPublish(_ epoch: Int) -> Bool {
        generation == epoch && available() && !Task.isCancelled
    }

    private func fetchIntelligence(_ symbol: SymbolID, epoch: Int) async {
        do {
            let type = try await provider.researchInstrumentType(for: symbol)
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.type = type
            guard type == .equity else { return }
        } catch {
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.errors["标的类型"] = Self.message(error)
            return
        }
        do {
            let news = try await provider.stockNews(for: symbol)
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.news = news
        } catch {
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.errors["新闻"] = Self.message(error)
            if FuyaoResearchError.isRateLimited(error) { return }
        }
        do {
            let rows = try await provider.anomalies(for: symbol)
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.anomalies = rows
        } catch {
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.errors["异动"] = Self.message(error)
            if FuyaoResearchError.isRateLimited(error) { return }
        }
        do {
            let list = try await loadHotList()
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.hotStock = list.value.first { Self.matches($0.thscode, symbol) }
            intelligence[symbol]?.hotListTime = list.dataTime
            intelligence[symbol]?.hotListLoaded = true
        } catch {
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.errors["热榜"] = Self.message(error)
            if FuyaoResearchError.isRateLimited(error) { return }
        }
        do {
            let end = Date.now
            let rows = try await provider.rankTrend(for: symbol, start: end.addingTimeInterval(-7 * 86_400), end: end)
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.ranking = rows
        } catch {
            guard canPublish(epoch) else { return }
            intelligence[symbol]?.errors["排名走势"] = Self.message(error)
        }
    }

    private func loadHotList() async throws -> FuyaoTimed<[FuyaoHotStock]> {
        if let hotList, Date.now.timeIntervalSince(hotList.fetchedAt) < 120 { return hotList }
        if let hotListTask { return try await hotListTask.value }
        let epoch = generation
        let task = Task { try await provider.hotStocks() }
        hotListTask = task
        do {
            let list = try await task.value
            guard canPublish(epoch) else { throw CancellationError() }
            hotList = list
            hotListTask = nil
            return list
        } catch {
            if generation == epoch { hotListTask = nil }
            throw error
        }
    }

    /// Freeze only data this process already observed. Recording a fill never
    /// issues a research request, changes a condition, or rewrites old context.
    func captureContext(for key: FuyaoContextKey, at date: Date) -> FuyaoMarketContext {
        func recent<T: Sendable & Codable & Hashable>(_ batch: FuyaoTimed<T>?, age: TimeInterval = 900) -> FuyaoTimed<T>? {
            guard let batch, batch.fetchedAt <= date,
                  date.timeIntervalSince(batch.fetchedAt) <= age,
                  batch.dataTime.map({ $0 <= date }) ?? true else { return nil }
            return batch
        }
        let state = intelligence[key.symbol]
        let news = recent(state?.news).map { batch in
            FuyaoTimed(value: Array(batch.value.filter { $0.publishedAt.map { $0 <= date } ?? true }.prefix(3)),
                dataTime: batch.dataTime, fetchedAt: batch.fetchedAt)
        }
        let anomalies = recent(state?.anomalies).map {
            FuyaoTimed(value: Array($0.value.prefix(1)), dataTime: $0.dataTime, fetchedAt: $0.fetchedAt)
        }
        let heat = recent(hotList)?.value.first { Self.matches($0.thscode, key.symbol) }
        let statistics = recent(sentiment.latest.statistics)
        let catalog = boards.catalogs.values.flatMap(\.value)
        var capturedBoards: [FuyaoMarketContext.Board] = []
        for board in catalog.sorted(by: { $0.thscode < $1.thscode }) {
            guard let detail = boards.details[board.thscode],
                  let members = recent(detail.constituents),
                  members.value.contains(where: { $0.symbol == key.symbol }),
                  let strength = detail.strength, let time = strength.dataTime, time <= date else { continue }
            capturedBoards.append(.init(name: board.name, thscode: board.thscode, strength: strength))
            if capturedBoards.count == 3 { break }
        }
        return .init(key: key, capturedAt: date, news: news, anomalies: anomalies, hotStock: heat,
            hotDataTime: heat == nil ? nil : hotList?.dataTime, statistics: statistics, boards: capturedBoards)
    }

    static func matches(_ code: String, _ symbol: SymbolID) -> Bool {
        code == symbol.code + (symbol.market == .sh ? ".SH" : ".SZ")
    }

    static func message(_ error: Error) -> String {
        guard let error = error as? ProviderError else { return "获取失败，请稍后重试" }
        switch error {
        case .rateLimited: return "请求受限，稍后再试"
        case .clientError(let status, _):
            if status == 401 { return "授权不可用，请检查扶摇设置" }
            if status == 403 { return "当前接口权限不可用" }
            if status == 404 { return "来源暂无可用数据" }
            return "请求未被来源接受"
        default: return "获取失败，请稍后重试"
        }
    }
}

private enum FuyaoResearchError {
    static func isRateLimited(_ error: Error) -> Bool {
        guard let error = error as? ProviderError else { return false }
        if case .rateLimited = error { return true }
        return false
    }
}
