import SwiftUI
import PulseCore
import PulseUI

/// 事件日历页的「打新」分组。
///
/// 三条展示规则来自契约：申购代码与交易代码**分开显示**（科创板常见 787xxx 对
/// 688xxx）；未定的上市日与发行价写"待定"，不补 0；北交所标的能看但不能加入自选
/// （本 App 没有该市场身份）。
struct FuyaoIPOListView: View {
    @Environment(AppState.self) private var appState
    var onSelect: (SymbolID) -> Void = { _ in }

    private var controller: FuyaoIPOController { appState.research.ipo }

    var body: some View {
        FuyaoIPOListContent(
            calendar: controller.calendar,
            loading: controller.loading,
            error: controller.lastError,
            enabled: appState.fuyaoResearchAvailable,
            onRefresh: { Task { await controller.load(force: true) } },
            onSelect: onSelect
        )
        .task(id: "\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
            guard appState.fuyaoResearchAvailable else { return }
            await controller.load()
        }
    }
}

/// 内容层：只依赖值，便于原生渲染检查。
struct FuyaoIPOListContent: View {
    var calendar: FuyaoIPOCalendar?
    var loading = false
    var error: String?
    var enabled = true
    var onRefresh: () -> Void = {}
    var onSelect: (SymbolID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !enabled {
                note("需连接同花顺扶摇。")
            } else if let calendar {
                if !calendar.hasData {
                    // 区分"确实没有"与"全部失败"：后者不该说成没有新股。
                    note(calendar.anySucceeded ? "当前没有待申购、可申购或待上市的新股。" : "本轮未能获取打新数据。")
                } else {
                    ForEach(FuyaoIPOStage.allCases) { stage in
                        let rows = calendar.entries(stage: stage)
                        if !rows.isEmpty { stageSection(stage, rows: rows) }
                    }
                }
                ForEach(Array(calendar.errors.keys).sorted { $0.sortOrder < $1.sortOrder }, id: \.self) { stage in
                    if let message = calendar.errors[stage] {
                        note("\(stage.title)本轮未取到（\(message)），其余阶段仍为来源原值。", tone: .orange)
                    }
                }
                note("仅覆盖沪深与北交所公开日历；不含中签率与申购上限（来源不提供）。")
            } else if let error {
                note(error)
            } else {
                note(loading ? "正在获取打新日历…" : "展开后获取。")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("打新日历").font(.system(size: 12, weight: .semibold))
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button("刷新", action: onRefresh).controlSize(.small).disabled(loading || !enabled)
        }
    }

    @ViewBuilder
    private func stageSection(_ stage: FuyaoIPOStage, rows: [FuyaoIPOEntry]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(stage.title) · \(rows.count)").font(.caption2).foregroundStyle(.secondary).padding(.top, 3)
            ForEach(rows) { entry in
                Button {
                    if let symbol = entry.symbol { onSelect(symbol) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(entry.market.title).font(.system(size: 8))
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(.secondary)
                                // 没有身份的行不可点击；直接说明原因，否则看起来只是坏了。
                                if entry.symbol == nil {
                                    Text("不可加入自选").font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            // 申购代码与交易代码不同时，两列都给；这是打新最容易搞错的地方。
                            Text(codeLine(entry)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(FuyaoIPOFormat.day(entry.subscriptionDate))
                                .font(.caption.monospacedDigit())
                            Text("上市 " + FuyaoIPOFormat.day(entry.listingDate))
                                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        }
                        Text(FuyaoIPOFormat.price(entry.issuePrice))
                            .font(.caption.monospacedDigit())
                            .frame(width: 66, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 京市与缺代码的行没有身份：可查看但不可跳转/加入自选。
                .disabled(entry.symbol == nil)
            }
        }
    }

    private func codeLine(_ entry: FuyaoIPOEntry) -> String {
        if entry.hasDistinctSubscriptionCode, let subscription = entry.subscriptionCode {
            return "申购 \(subscription) · 交易 \(entry.ticker)"
        }
        return entry.ticker
    }

    private func note(_ text: String, tone: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2).foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
    }
}
