import SwiftUI
import PulseCore
import PulseUI

/// 场内基金（ETF / LOF）的业绩与回撤小节。
///
/// 三件事必须说清，否则读者会误读：
/// 1. **收益与回撤都是百分数原值**，不再乘 100；回撤是负值，负号是方向。
/// 2. `adj_nav` 是**复权净值，不是累计净值**，两者不能混称。
/// 3. 同类排名只在来源给出时才显示；缺失就是没有，不补 0 也不猜。
struct FuyaoFundPerformanceView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    @State private var expanded = false

    private var controller: FuyaoFundPerformanceController { appState.research.fundPerformance }
    private var state: FuyaoFundPerformanceController.State { controller.states[symbol] ?? .init() }

    var body: some View {
        DisclosureGroup("业绩与回撤", isExpanded: $expanded) {
            FuyaoFundPerformanceContent(state: state) {
                Task { await controller.load(symbol, force: true) }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
        .task(id: "\(symbol.description)-\(expanded)-\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
            guard expanded, appState.fuyaoResearchAvailable else { return }
            await controller.load(symbol)
        }
    }
}

/// 内容层：只依赖值，便于原生渲染检查复现真实排版。
struct FuyaoFundPerformanceContent: View {
    var state: FuyaoFundPerformanceController.State = .init()
    var onRefresh: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let performance = state.performance {
                navLine(performance)
                periodTable(performance)
                // 部分失败要说"缺的是哪一块"，而不是笼统报错：收益端点失败时，
                // 回撤与净值可能仍然有效，把它们一起标成错误会让人以为整页不可信。
                if !performance.errors.isEmpty {
                    ForEach(performance.errors.keys.sorted(), id: \.self) { key in
                        Text("\(key)本轮未取到（\(performance.errors[key] ?? "获取失败")），其余数据仍为来源原值。")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                footnote
            } else if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(state.loading ? "正在获取业绩…" : "展开后获取。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text("区间收益 · 同类排名 · 最大回撤").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if state.loading { ProgressView().controlSize(.small) }
            Button("刷新", action: onRefresh).controlSize(.small).disabled(state.loading)
        }
    }

    @ViewBuilder
    private func navLine(_ performance: FuyaoFundPerformance) -> some View {
        if let nav = performance.mostRecentNav {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 16) {
                    navItem("单位净值", FuyaoPerformanceFormat.nav(nav.unitNav))
                    navItem("复权净值", FuyaoPerformanceFormat.nav(nav.adjustedNav))
                    Spacer(minLength: 0)
                    Text("净值日 \(ResearchFormat.day(nav.date))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("复权净值用于抹平分红送转造成的断层，不等同于累计净值。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func navItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }
    }

    @ViewBuilder
    private func periodTable(_ performance: FuyaoFundPerformance) -> some View {
        let periods = performance.nonEmptyPeriods
        if periods.isEmpty {
            Text("来源未返回区间收益或回撤。").font(.caption).foregroundStyle(.secondary)
        } else {
            // 宽窗口四列并排；窄窗口收成"周期 + 收益 + 回撤"三列，把同类平均与
            // 排名降为第二行。330pt 里塞四列会直接把回撤列挤出可视区。
            ViewThatFits(in: .horizontal) {
                wideTable(periods)
                narrowTable(periods)
            }
        }
    }

    private func wideTable(_ periods: [FuyaoPerformancePeriod]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("周期").frame(width: 62, alignment: .leading)
                Spacer(minLength: 0)
                columnLabel("收益", width: 60)
                columnLabel("同类平均", width: 64)
                columnLabel("排名", width: 66)
                columnLabel("回撤", width: 60)
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
            ForEach(periods) { period in
                HStack(spacing: 8) {
                    Text(period.window.title)
                        .font(.caption).frame(width: 62, alignment: .leading)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    value(FuyaoPerformanceFormat.percent(period.returnPercent), width: 60,
                          tint: outcomeTint(period))
                    value(FuyaoPerformanceFormat.percent(period.peerAveragePercent), width: 64, muted: true)
                    value(FuyaoPerformanceFormat.rank(period.rank, period.rankTotal), width: 66, muted: true)
                    value(FuyaoPerformanceFormat.drawdown(period.drawdownPercent), width: 60, muted: true)
                }
                .padding(.vertical, 1)
            }
            rankingHint(periods)
        }
    }

    private func narrowTable(_ periods: [FuyaoPerformancePeriod]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(periods) { period in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(period.window.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(FuyaoPerformanceFormat.percent(period.returnPercent))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(outcomeTint(period) ?? AnyShapeStyle(.primary))
                        Text("回撤 " + FuyaoPerformanceFormat.drawdown(period.drawdownPercent))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    let peer = FuyaoPerformanceFormat.percent(period.peerAveragePercent)
                    let rank = FuyaoPerformanceFormat.rank(period.rank, period.rankTotal)
                    if peer != "—" || rank != "—" {
                        Text("同类平均 \(peer) · 排名 \(rank)")
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
            rankingHint(periods)
        }
    }

    /// 只有来源真的给了排名才解释排名口径。
    @ViewBuilder
    private func rankingHint(_ periods: [FuyaoPerformancePeriod]) -> some View {
        if periods.contains(where: { $0.rank != nil }) {
            Text("排名为同类别内名次（越小越靠前）；只列出来源给出的周期。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func columnLabel(_ text: String, width: CGFloat) -> some View {
        Text(text).frame(width: width, alignment: .trailing)
    }

    private func value(_ text: String, width: CGFloat, muted: Bool = false,
                       tint: AnyShapeStyle? = nil) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint ?? (muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
            .frame(width: width, alignment: .trailing)
    }

    /// 只标记"跑赢/跑输同类"，不判断该不该买。
    private func outcomeTint(_ period: FuyaoPerformancePeriod) -> AnyShapeStyle? {
        switch period.exceedsPeer {
        case true: AnyShapeStyle(Color.red)     // 本地习惯：正收益用红
        case false: AnyShapeStyle(Color.green)
        case nil: nil
        }
    }

    private var footnote: some View {
        Text("收益与回撤均为来源的百分数原值（19.66 表示 +19.66%），回撤以负值表示方向。同类平均与排名只在来源给出时显示。")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
