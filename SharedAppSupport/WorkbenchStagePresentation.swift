import Foundation
import PulseCore
import PulseUI

/// Market filters describe assets, never brokerage accounts. Macro watchlist
/// indices do not fabricate an overseas asset book. This is a read-only view.
struct WorkbenchMarketContext {
    let markets: [Market]
    let scopes: [WorkbenchScope]
    let isAssetBased: Bool

    init(items: [WatchItem]) {
        let assetMarkets = Set(items.filter {
            $0.supportsPosition && ($0.hasPositionHistory || $0.plans.contains { $0.status == .active })
        }.map(\.symbol.market))
        isAssetBased = !assetMarkets.isEmpty
        let watched = Set(items.filter(\.supportsPosition).map(\.symbol.market))
        let relevant = assetMarkets.isEmpty ? watched : assetMarkets
        // An empty Chinese-language workbench is not evidence of a US/HK book.
        markets = relevant.isEmpty ? [.sh, .sz] : Market.allCases.filter { relevant.contains($0) }
        var supported: [WorkbenchScope] = []
        if markets.contains(where: \.isChinaA) { supported.append(.chinaA) }
        if markets.contains(.hk) { supported.append(.hongKong) }
        if markets.contains(.us) { supported.append(.unitedStates) }
        let hasOther = markets.contains { !$0.isChinaA && $0 != .hk && $0 != .us }
        scopes = supported.count == 1 && !hasOther ? supported : [.all] + supported
    }

    func resolvedScope(_ selection: WorkbenchScope) -> WorkbenchScope {
        scopes.contains(selection) ? selection : (scopes.first ?? .all)
    }

    func clockMarkets(for scope: WorkbenchScope) -> [Market] {
        markets.filter { resolvedScope(scope).contains($0) }
    }

    var label: String {
        let suffix = isAssetBased ? "资产" : "关注市场"
        if scopes == [.chinaA] { return "A 股" + suffix }
        if scopes == [.hongKong] { return "港股" + suffix }
        if scopes == [.unitedStates] { return "美股" + suffix }
        return markets.map(\.displayName).joined(separator: " / ") + " · " + suffix
    }
}

/// Stage-specific tasks over the unchanged factual board. Switching stages
/// changes the actual list and actions, not the financial source or its totals.
struct WorkbenchStagePresentation {
    struct Metric: Identifiable {
        let id: String
        let label: String
        let value: Int
        let unit: String
        let icon: String
        var text: String { "\(label) \(value) \(unit)" }
    }

    let phase: WorkbenchPhase
    let tasks: [WorkbenchTask]
    let metrics: [Metric]
    let activePlanCount: Int
    let todayFillCount: Int
    let checkpointCount: Int

    var title: String {
        switch phase {
        case .preMarket: "盘前准备"
        case .intraday: "盘中跟进"
        case .postMarket: "盘后复盘"
        }
    }
    var taskTitle: String {
        switch phase {
        case .preMarket: "准备清单"
        case .intraday: "当前跟进"
        case .postMarket: "待复盘与复查"
        }
    }
    var subtitle: String {
        switch phase {
        case .preMarket: "先检查待执行计划、触发条件与临近事件，再核对资金。"
        case .intraday: "跟进有效行情下的到价和待核对事项，只记录真实成交。"
        case .postMarket: "复盘今天已记录的买卖，处理到期复查，再安排后续计划。"
        }
    }
    var emptyText: String {
        switch phase {
        case .preMarket: "暂无待准备的计划或临近事件。可以先检查持仓与可用资金。"
        case .intraday: "暂无到价或待核对的盘中事项。休市、缺失或过期行情不作为到价信号。"
        case .postMarket:
            todayFillCount == 0 ? "今天尚未记录成交；更早的记录从历史复盘入口补齐。"
                : "今天已记录的成交均已复盘，当前没有到期复查。"
        }
    }
    var allowsPlanFillAction: Bool { phase == .intraday }
    var showsCashTasks: Bool { phase == .preMarket }

    init(board: WorkbenchBoard, phase: WorkbenchPhase, items: [WatchItem],
         historyItems: [WatchItem], entries: [TradePlanEntry], now: Date,
         name: (SymbolID) -> String) {
        self.phase = phase
        let scoped = Set(items.map(\.symbol))
        let active = entries.filter { scoped.contains($0.symbol) && $0.plan.status == .active && $0.remainingQuantity > 0 }
        activePlanCount = active.count
        // Same complete, account-scoped population as WorkbenchBoard's review
        // count: WatchlistStore.tradeHistoryItems includes current AND retained
        // entries with transactions. Do not substitute only removed symbols.
        let history = Dictionary(historyItems.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        todayFillCount = history.values.reduce(0) { count, item in
            count + item.transactions.filter {
                $0.kind != .adjustment && WorkbenchBoard.isOnRecordedDay($0, now: now)
            }.count
        }
        let reviewItems = Dictionary((items + historyItems).map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        let today = Calendar.current.startOfDay(for: now)
        checkpointCount = reviewItems.values.reduce(0) { count, item in
            count + item.transactions.filter { transaction in
                transaction.kind != .adjustment && transaction.review?.nextReviewDate.map {
                    Calendar.current.startOfDay(for: $0) <= today
                } == true
            }.count
        }
        let base = Dictionary(board.tasks.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        switch phase {
        case .preMarket:
            let plans = Dictionary(grouping: active, by: \.symbol)
            let preparation = Set(plans.keys).union(board.tasks.filter {
                $0.conditionCount > 0 || $0.eventCount > 0 || !$0.verifications.isEmpty
            }.map(\.symbol))
            let rows = preparation.map { symbol -> WorkbenchTask in
                let existing = base[symbol]
                let entries = plans[symbol] ?? []
                var reasons: [String] = []
                if !entries.isEmpty { reasons.append("\(entries.count) 条计划待准备") }
                if let count = existing?.conditionCount, count > 0 { reasons.append("\(count) 条条件待核对") }
                if existing?.eventCount ?? 0 > 0 { reasons.append("临近事件") }
                if existing?.verifications.isEmpty == false { reasons.append("持仓条件核对") }
                return WorkbenchTask(symbol: symbol, name: name(symbol), reached: false,
                    conditionCount: existing?.conditionCount ?? 0, eventCount: existing?.eventCount ?? 0,
                    reasons: reasons, plans: entries.map { entry in
                        .init(id: entry.id,
                            detail: WorkbenchBoard.planIdentity(entry) + " · 待执行 " + PriceFormatter.quantity(entry.remainingQuantity),
                            entry: entry)
                    }, reviewTransactionIDs: [], dueReviewText: nil,
                    verifications: existing?.verifications ?? [])
            }
            tasks = WorkbenchBoard.order(rows, phase: .preMarket)
            metrics = [
                .init(id: "plans", label: "待准备", value: active.count, unit: "条计划", icon: "list.bullet.clipboard"),
                .init(id: "conditions", label: "待核对", value: board.plansToReviewCount, unit: "条计划", icon: "checklist"),
                .init(id: "events", label: "临近事件", value: rows.reduce(0) { $0 + $1.eventCount }, unit: "项", icon: "calendar")
            ]
        case .intraday:
            tasks = board.tasks.filter {
                $0.reached || $0.conditionCount > 0 || $0.eventCount > 0 || !$0.verifications.isEmpty
            }.map { task in
                var reasons: [String] = []
                if task.reached { reasons.append("已到价（不代表成交）") }
                if task.conditionCount > 0 { reasons.append("\(task.conditionCount) 条条件待核对") }
                if task.eventCount > 0 { reasons.append("临近事件") }
                if !task.verifications.isEmpty { reasons.append("持仓条件核对") }
                return WorkbenchTask(symbol: task.symbol, name: task.name, reached: task.reached,
                    conditionCount: task.conditionCount, eventCount: task.eventCount, reasons: reasons,
                    plans: task.plans, reviewTransactionIDs: [], dueReviewText: nil,
                    verifications: task.verifications)
            }
            metrics = [
                .init(id: "reached", label: "当前到价", value: board.reachedSymbolCount, unit: "个标的", icon: "target"),
                .init(id: "conditions", label: "待核对", value: board.plansToReviewCount, unit: "条计划", icon: "checklist"),
                .init(id: "risks", label: "风险提醒", value: board.defenses.filter(\.isWarning).count, unit: "项", icon: "shield.lefthalf.filled")
            ]
        case .postMarket:
            tasks = board.tasks.filter { !$0.reviewTransactionIDs.isEmpty || $0.checkpointID != nil }.map { task in
                var reasons: [String] = []
                if !task.reviewTransactionIDs.isEmpty { reasons.append("今日成交待复盘") }
                if task.checkpointID != nil { reasons.append("复查检查点到期") }
                return WorkbenchTask(symbol: task.symbol, name: task.name, reached: false,
                    conditionCount: 0, eventCount: 0, reasons: reasons, plans: [],
                    reviewTransactionIDs: task.reviewTransactionIDs, dueReviewText: task.dueReviewText,
                    checkpointID: task.checkpointID)
            }
            metrics = [
                .init(id: "fills", label: "今日成交", value: todayFillCount, unit: "笔", icon: "list.bullet.rectangle"),
                .init(id: "reviews", label: "待复盘", value: board.todayReviewCount, unit: "笔", icon: "square.and.pencil"),
                .init(id: "checkpoints", label: "到期复查", value: checkpointCount, unit: "笔", icon: "clock.arrow.circlepath")
            ]
        }
    }

    /// Select a useful initial work stage from the actual asset exchanges, not
    /// from a fictitious US/HK account. Manual stage selection remains manual.
    static func suggestedPhase(markets: [Market], at date: Date) -> WorkbenchPhase {
        let states = markets.map { TradingCalendar.state(of: $0, at: date) }
        if states.contains(.regular) || states.contains(.lunchBreak) { return .intraday }
        if states.contains(.preMarket) || states.contains(.overnight) { return .preMarket }
        if states.contains(.postMarket) { return .postMarket }
        let market = markets.first ?? .sh
        let day = CalendarDay(date, in: market.timeZone)
        guard ExchangeCalendar.isTradingDay(market, on: day) else { return .postMarket }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let opening = market.isChinaA ? 9 * 60 + 15 : market == .hk || market == .us ? 9 * 60 + 30 : 9 * 60
        return minutes < opening ? .preMarket : .postMarket
    }
}
