import SwiftUI
import PulseCore
import PulseUI

/// 今日工作台的「资金与监管」摘要卡。
///
/// 只回答两个问题：今天谁在被机构买、自选里谁上了榜或被监控。它不解释原因、
/// 不预测次日、也不把当日榜和三日榜的金额加在一起。
struct FuyaoCapitalFlowCard: View {
    @Environment(AppState.self) private var appState
    var onOpen: () -> Void

    private var controller: FuyaoDragonTigerController { appState.research.dragonTiger }
    private var symbols: Set<SymbolID> { Set(appState.watchlist.allItems.map(\.symbol)) }
    private var state: FuyaoDragonTigerController.State { controller.days[.all] ?? .init() }

    var body: some View {
        Button(action: onOpen) {
            content.padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .task(id: "\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
            guard appState.fuyaoResearchAvailable else { return }
            while !Task.isCancelled {
                await controller.load(board: .all)
                await controller.load(board: .hotMoney)
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    @ViewBuilder private var content: some View {
        FuyaoCapitalFlowSummary(
            state: state,
            topInstitutional: controller.topInstitutionalNet(count: 5),
            watchHitCount: controller.watchHits(board: .all, symbols: symbols).count,
            monitored: controller.monitorHits(symbols: symbols),
            loading: controller.loadingBoards.contains(.all)
        )
    }

    static func money(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        if magnitude >= 100_000_000 { return String(format: "%@%.2f 亿", sign, magnitude / 100_000_000) }
        if magnitude >= 10_000 { return String(format: "%@%.0f 万", sign, magnitude / 10_000) }
        return String(format: "%@%.0f", sign, magnitude)
    }
}

/// 资金与监管卡的内容层：只依赖值，便于原生渲染检查复现真实排版。
struct FuyaoCapitalFlowSummary: View {
    var state: FuyaoDragonTigerController.State = .init()
    var topInstitutional: [FuyaoDragonTigerRow] = []
    var watchHitCount = 0
    var monitored: [FuyaoAbnormalMonitor] = []
    var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("资金与监管", systemImage: "arrow.left.arrow.right").font(.system(size: 12, weight: .semibold))
                if let date = state.day?.tradeDate {
                    Text(ResearchFormat.day(date)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            if let day = state.day {
                if !topInstitutional.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("机构净买入（当日榜）").font(.caption2).foregroundStyle(.secondary)
                        ForEach(topInstitutional) { row in
                            hit(name: row.name, value: FuyaoCapitalFlowCard.money(row.orgNetValue),
                                badge: row.symbol != nil)
                        }
                    }
                }
                if watchHitCount > 0 {
                    Text("自选命中 \(watchHitCount) 只（当日榜）").font(.caption2).foregroundStyle(.orange)
                }
                let ongoing = monitored.filter(\.isOngoing).count
                if ongoing > 0 {
                    Text("自选/持仓中 \(ongoing) 只处于监控中").font(.caption2).foregroundStyle(.orange)
                } else if !monitored.isEmpty {
                    Text("自选/持仓有 \(monitored.count) 条历史监控记录")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if topInstitutional.isEmpty && watchHitCount == 0 && monitored.isEmpty {
                    Text("当日无机构净买入记录，自选未上榜也未在监控中。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(day.dataTime.map { "同花顺扶摇 · 数据 " + ResearchFormat.time($0) }
                     ?? "同花顺扶摇 · 未提供数据时间")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(loading ? "正在获取龙虎榜…" : "暂无龙虎榜数据，点击查看或刷新")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hit(name: String, value: String, badge: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(.system(size: 11)).lineLimit(1)
            if badge {
                Text("自选").font(.system(size: 8, weight: .medium))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            }
            Spacer(minLength: 4)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// 交易复盘详情里的「当日资金面」小节。
///
/// 与复盘背景快照刻意不同：这里是**实时查询**，因为龙虎榜在收盘后才发布，
/// 而背景快照保存的是"记录那一刻已经观察到的"东西。把盘后数据塞进快照会
/// 让现场记录带上不存在的信息。
struct FuyaoJournalCapitalFlow: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    @State private var expanded = false

    private var controller: FuyaoDragonTigerController { appState.research.dragonTiger }
    private var rows: [FuyaoDragonTigerRow] {
        controller.days[.all]?.day?.rows(for: symbol) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup("当日资金面（收盘后发布）", isExpanded: $expanded) {
                content.padding(.top, 6)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(symbol.description)-\(expanded)-\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
            guard expanded, appState.fuyaoResearchAvailable else { return }
            await controller.load(board: .all)
        }
    }

    @ViewBuilder private var content: some View {
        if !appState.fuyaoResearchAvailable {
            Text("需连接同花顺扶摇。").font(.caption).foregroundStyle(.secondary)
        } else if let day = controller.days[.all]?.day {
            if rows.isEmpty {
                Text("该标的在 \(ResearchFormat.day(day.tradeDate)) 的龙虎榜中无记录。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // 当日榜与三日榜分别列出：两者的金额不可相加。
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.range?.title ?? "区间未知")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(row.range == .threeDay ? .secondary : .primary)
                        Text("净买入 \(FuyaoCapitalFlowCard.money(row.netValue))")
                            .font(.caption).monospacedDigit()
                        if let org = row.orgNetValue {
                            Text("机构 \(FuyaoCapitalFlowCard.money(org))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Text("数据日期 \(ResearchFormat.day(day.tradeDate))；三日榜为区间累计，不与当日榜相加。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        } else if let error = controller.days[.all]?.error {
            Text(error).font(.caption).foregroundStyle(.secondary)
        } else {
            Text(controller.loadingBoards.contains(.all) ? "正在获取…" : "展开后获取。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
