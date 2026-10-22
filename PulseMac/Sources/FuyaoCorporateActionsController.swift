import Foundation
import Observation
import PulseCore

/// 除权除息事件的本地缓存与计划口径提示。
///
/// 这一层**只读**：它把上游事件搬进内存与一个小型持久缓存，算出"哪条计划需要
/// 复核"，然后把结果交给界面。它不改计划、不改成交、不碰账本，也不写同步文件。
///
/// 两个刻意的边界：
/// 1. **按标的串行补齐**。端点每次只接受一个 thscode，扇出会直接撞上节流预算；
///    这里一次只跑一个请求，其余排队，并把在途状态暴露给界面。
/// 2. **失败不污染已成功的副本**。某只标的拉取失败时，它上一次成功的事件序列
///    继续有效（分红一年只变几次），只是标记为过期；从不因为一次失败就清空。
@MainActor
@Observable
final class FuyaoCorporateActionsController {
    /// 一只标的的缓存条目：事件序列 + 拉取时间 + 最近一次失败。
    struct Entry {
        var series: FuyaoCorporateActionSeries
        var attemptedAt: Date
        var lastError: String?
    }

    private(set) var entries: [SymbolID: Entry] = [:]
    /// 正在拉取的标的，供界面显示"补齐中"。
    private(set) var loading: Set<SymbolID> = []
    /// 全景错误：只在一只标的**从未成功过**、因此连兜底副本都没有时才写。
    /// 单标的的刷新失败记在 `entries[symbol].lastError` 上——把一只票的权限问题
    /// 报成"整个来源不可用"会误导用户去换 Key。
    private(set) var lastError: String?
    private(set) var epoch = 0

    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var queue: [SymbolID] = []
    @ObservationIgnored private var queued: Set<SymbolID> = []

    /// 内存新鲜度：一天。事件本身一年只变几次，但除权日前一天可能刚发布。
    static let memoryTTL: TimeInterval = 24 * 60 * 60
    /// 持久化新鲜度：七天，避免每次冷启动重拉。
    static let persistedTTL: TimeInterval = 7 * 24 * 60 * 60
    /// 持久缓存上限：超过就丢最旧的，绝不无限增长。
    static let persistedLimit = 200
    private static let storageKey = "pulse.fuyao.corporateActions.v2"

    private struct Archive: Codable {
        var fetchedAt: [SymbolID: Date]
        var series: [SymbolID: FuyaoCorporateActionSeries]
    }

    init(provider: FuyaoProvider, available: @escaping () -> Bool, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.available = available
        self.defaults = defaults
        loadPersisted()
    }

    // MARK: - 读取

    func series(for symbol: SymbolID) -> FuyaoCorporateActionSeries? {
        entries[symbol]?.series
    }

    /// 某只标的最新一次除权（含未来预告），供个股页展示。
    func latestAction(for symbol: SymbolID) -> FuyaoCorporateAction? {
        entries[symbol]?.series.actions.first
    }

    /// 该标的是否已有一份可用副本（无论是否过期）。
    func hasData(for symbol: SymbolID) -> Bool { entries[symbol] != nil }

    /// 需要复核的计划。只统计已有事件序列的标的：没有数据不等于没有除权。
    func notices(plans: [(symbol: SymbolID, plan: TradePlan)], asOf: Date = .now) -> [FuyaoPlanPriceBasisNotice] {
        let known = plans.filter { entries[$0.symbol] != nil }
        return FuyaoPlanPriceBasisNotice.notices(plans: known, series: entries.mapValues(\.series), asOf: asOf)
    }

    /// 单条计划命中的提示；没有缓存、不是活跃计划或未命中都返回 nil。
    func notice(for plan: TradePlan, symbol: SymbolID, asOf: Date = .now) -> FuyaoPlanPriceBasisNotice? {
        guard entries[symbol] != nil else { return nil }
        return FuyaoPlanPriceBasisNotice
            .notices(plans: [(symbol, plan)], series: entries.mapValues(\.series), asOf: asOf)
            .first
    }

    // MARK: - 加载

    /// 单只标的：未过期就跳过；`force` 忽略内存新鲜度。
    func load(_ symbol: SymbolID, force: Bool = false) async {
        guard available(), Self.supports(symbol) else { return }
        if !force, let entry = entries[symbol],
           Date.now.timeIntervalSince(entry.attemptedAt) < Self.memoryTTL { return }
        enqueue([symbol], force: force)
        await task?.value
    }

    /// 批量补齐（工作台/计划页展开时）。已新鲜、已在队列里的会被跳过。
    func load(symbols: [SymbolID], force: Bool = false) async {
        guard available() else { return }
        let needed = symbols.filter { symbol in
            guard Self.supports(symbol) else { return false }
            if force { return true }
            guard let entry = entries[symbol] else { return true }
            return Date.now.timeIntervalSince(entry.attemptedAt) >= Self.memoryTTL
        }
        guard !needed.isEmpty else { return }
        enqueue(needed, force: force)
        await task?.value
    }

    /// 刷新全部已缓存标的（设置页的手动刷新）。
    func refreshAll() async {
        enqueue(entries.keys.sorted { $0.description < $1.description }, force: true)
        await task?.value
    }

    func reset() {
        epoch += 1
        task?.cancel(); task = nil
        queue = []; queued = []
        loading = []
        entries = [:]
        lastError = nil
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// 凭据/数据源开关变化：清空但不删持久档案之外的东西——这里选择全部清空，
    /// 因为换 Key 后能否读取是未知的，留着旧副本会让人以为仍然有效。
    func availabilityChanged() {
        guard !available() else { return }
        reset()
    }

    // MARK: - 队列

    private func enqueue(_ symbols: [SymbolID], force: Bool) {
        for symbol in symbols where !queued.contains(symbol) {
            if !force, let entry = entries[symbol],
               Date.now.timeIntervalSince(entry.attemptedAt) < Self.memoryTTL { continue }
            queued.insert(symbol)
            queue.append(symbol)
        }
        guard task == nil, !queue.isEmpty else { return }
        let captured = epoch
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.epoch == captured { self.task = nil } }
            while !self.queue.isEmpty {
                if Task.isCancelled || self.epoch != captured { return }
                let symbol = self.queue.removeFirst()
                self.queued.remove(symbol)
                guard self.available() else { return }
                self.loading.insert(symbol)
                await self.fetchOne(symbol, captured: captured)
                self.loading.remove(symbol)
                // 限流后队列已清空，这里再查一次即可退出。
                if self.queue.isEmpty { break }
            }
            self.savePersisted()
        }
    }

    /// 拉取一只标的。调用方负责 `loading` 的进入与退出，这样循环里不会出现
    /// 在 `while` 内使用 `defer`（那只在函数返回时执行一次）的经典错误。
    private func fetchOne(_ symbol: SymbolID, captured: Int) async {
        do {
            let series = try await provider.corporateActions(for: symbol)
            guard epoch == captured, !Task.isCancelled else { return }
            entries[symbol] = Entry(series: series, attemptedAt: .now, lastError: nil)
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            guard epoch == captured else { return }
            let message = FuyaoResearchController.message(error)
            if var existing = entries[symbol] {
                // 保留上一次成功的事件序列，只更新尝试时间与错误。
                existing.attemptedAt = .now
                existing.lastError = message
                entries[symbol] = existing
            } else {
                // 从未成功过：记一个空序列会让人以为"确认没有除权"，
                // 所以此处不留条目，只报错。
                lastError = message
            }
            // 限流：清空剩余队列，不再制造请求风暴。只认 `.rateLimited`
            // （429 或业务 code=4001 都已被 provider 归到这一种情况）。
            if case ProviderError.rateLimited = error {
                queued.subtract(queue)
                queue.removeAll()
            }
        }
    }

    // MARK: - 持久化

    private func loadPersisted() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        let now = Date.now
        for (symbol, series) in archive.series {
            guard let fetched = archive.fetchedAt[symbol],
                  now.timeIntervalSince(fetched) < Self.persistedTTL else { continue }
            entries[symbol] = Entry(series: series, attemptedAt: fetched, lastError: nil)
        }
    }

    private func savePersisted() {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        // 只保留最近的 N 条，按尝试时间降序。
        let ordered = entries.sorted { $0.value.attemptedAt > $1.value.attemptedAt }.prefix(Self.persistedLimit)
        var archive = Archive(fetchedAt: [:], series: [:])
        for (symbol, entry) in ordered {
            archive.series[symbol] = entry.series
            archive.fetchedAt[symbol] = entry.attemptedAt
        }
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: - 支持范围

    /// 只有沪深普通股票有分红送转。指数、板块、基金、美股都不在本端点范围内。
    static func supports(_ symbol: SymbolID) -> Bool {
        (symbol.market == .sh || symbol.market == .sz)
            && symbol.indexID == nil
            && symbol.sectorIndex == nil
            && symbol.metalID == nil
            && symbol.cryptoPair == nil
    }
}
