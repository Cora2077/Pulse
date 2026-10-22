import Foundation
import Observation
import PulseCore

/// 龙虎榜与异动监控的缓存。
///
/// 三个刻意的边界：
/// 1. **`all` / `org` / `hot_money` 三份缓存互相独立**。它们不是同一份数据的筛选，
///    `hot_money` 的股票表本来就是空数组，共用缓存会让"切换页签"看起来像没数据。
/// 2. **业务日期只能从响应读**。省略 `date` 时上游给的是上一个交易日，本地算不出；
///    界面显示 `trade_date`，不显示自己的推断。
/// 3. **不做跨区间相加**。模型层已经把 `range_days` 暴露给界面，这一层不提供任何
///    "总净买入"之类的汇总数字，避免把当日榜与三日榜叠成一份。
@MainActor
@Observable
final class FuyaoDragonTigerController {
    struct State {
        var day: FuyaoDragonTigerDay?
        var error: String?
        /// 最近一次成功获取的时间，用于"数据时间"与"获取时间"分开显示。
        var fetchedAt: Date?
    }

    /// 三张榜单各自的缓存。
    private(set) var days: [FuyaoDragonTigerBoard: State] = [:]
    /// 异动监控。`current` 与 `history` 分开缓存。
    private(set) var monitors: [FuyaoAbnormalMonitorState: MonitorState] = [:]
    private(set) var loadingBoards: Set<FuyaoDragonTigerBoard> = []
    private(set) var loadingMonitors: Set<FuyaoAbnormalMonitorState> = []
    private(set) var epoch = 0

    struct MonitorState {
        var page: FuyaoAbnormalMonitorPage?
        var error: String?
        var fetchedAt: Date?
    }

    @ObservationIgnored private let provider: FuyaoProvider
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    /// 榜单 5 分钟：龙虎榜是收盘后发布，日内不会变。
    static let boardTTL: TimeInterval = 300
    /// 监控也是 5 分钟。
    static let monitorTTL: TimeInterval = 300

    init(provider: FuyaoProvider, available: @escaping () -> Bool) {
        self.provider = provider
        self.available = available
    }

    func reset() {
        epoch += 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        days = [:]
        monitors = [:]
        loadingBoards = []
        loadingMonitors = []
    }

    private func valid(_ captured: Int) -> Bool { captured == epoch && available() && !Task.isCancelled }

    // MARK: - 榜单

    func load(board: FuyaoDragonTigerBoard, date: Date? = nil, force: Bool = false) async {
        guard available() else { return }
        // 同一 board 只缓存一个日期：界面切换日期时进另一条键。
        let key = "board-\(board.rawValue)-\(date.map(ResearchKey.day) ?? "latest")"
        if let task = tasks[key] { await task.value; return }
        if !force, date == nil, let state = days[board], let at = state.fetchedAt,
           Date.now.timeIntervalSince(at) < Self.boardTTL { return }
        let captured = epoch
        loadingBoards.insert(board)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == captured {
                    self.loadingBoards.remove(board)
                    self.tasks[key] = nil
                }
            }
            do {
                let day = try await self.provider.dragonTiger(board: board, date: date)
                guard self.valid(captured) else { return }
                self.days[board] = State(day: day, error: nil, fetchedAt: day.fetchedAt)
            } catch is CancellationError {
                return
            } catch {
                guard self.valid(captured) else { return }
                // 保留上一次成功的数据，只把错误标出来。
                var state = self.days[board] ?? State()
                state.error = FuyaoResearchController.message(error)
                self.days[board] = state
            }
        }
        tasks[key] = task
        await task.value
    }

    // MARK: - 异动监控

    func loadMonitors(state: FuyaoAbnormalMonitorState = .current, page: Int = 1, force: Bool = false) async {
        guard available() else { return }
        let key = "monitor-\(state.rawValue)-\(page)"
        if let task = tasks[key] { await task.value; return }
        if !force, page == 1, let cached = monitors[state], let at = cached.fetchedAt,
           Date.now.timeIntervalSince(at) < Self.monitorTTL { return }
        let captured = epoch
        loadingMonitors.insert(state)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == captured {
                    self.loadingMonitors.remove(state)
                    self.tasks[key] = nil
                }
            }
            do {
                let requestedPage = page
                let result = try await self.provider.abnormalMonitors(state: state, page: requestedPage)
                guard self.valid(captured) else { return }
                self.monitors[state] = MonitorState(page: result, error: nil, fetchedAt: result.fetchedAt)
            } catch is CancellationError {
                return
            } catch {
                guard self.valid(captured) else { return }
                var cached = self.monitors[state] ?? MonitorState()
                cached.error = FuyaoResearchController.message(error)
                self.monitors[state] = cached
            }
        }
        tasks[key] = task
        await task.value
    }

    // MARK: - 派生

    /// 命中自选 / 持仓的当日榜记录。
    ///
    /// 只取当日榜区间：三日榜说的是"最近三天累计"，把它混进"今天这只票上龙虎榜了"
    /// 会改变语义。区间未知的行也不进来，因为无法判断它说的是哪一段。
    func watchHits(board: FuyaoDragonTigerBoard, symbols: Set<SymbolID>) -> [FuyaoDragonTigerRow] {
        guard let day = days[board]?.day else { return [] }
        return day.stockRows.filter { row in
            guard row.range == .day, let symbol = row.symbol else { return false }
            return symbols.contains(symbol)
        }
    }

    /// 命中自选 / 持仓的监控记录（含仍在监控中的）。
    func monitorHits(symbols: Set<SymbolID>) -> [FuyaoAbnormalMonitor] {
        guard let page = monitors[.current]?.page else { return [] }
        return page.records.filter { record in
            guard let symbol = record.symbol else { return false }
            return symbols.contains(symbol)
        }
    }

    /// 机构净买入靠前的股票（仅当日榜）。
    func topInstitutionalNet(count: Int) -> [FuyaoDragonTigerRow] {
        days[.all]?.day?.topInstitutionalNet(count: count, range: .day) ?? []
    }

    /// 游资净买入靠前的名称（来自游资榜）。
    func topHotMoney(count: Int) -> [FuyaoHotMoney] {
        Array((days[.hotMoney]?.day?.hotMoneyRows ?? []).prefix(count))
    }
}

/// 只用于缓存键的日期格式化，避免把展示格式混进缓存身份。
private enum ResearchKey {
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
