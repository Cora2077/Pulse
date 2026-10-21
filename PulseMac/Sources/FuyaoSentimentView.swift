import SwiftUI
import PulseCore

struct FuyaoSentimentCard: View {
    @Environment(AppState.self) private var appState
    var onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            FuyaoSentimentSummary(state: appState.research.sentiment.latest)
                .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .task(id: "\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
                guard appState.fuyaoResearchAvailable else { return }
                while !Task.isCancelled {
                    await appState.research.sentiment.load()
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                }
            }
    }
}
struct FuyaoSentimentSummary: View {
    let state: FuyaoSentimentController.State
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("A 股市场情绪", systemImage: "waveform.path.ecg").font(.system(size: 12, weight: .semibold))
                if let date = state.statistics?.value.tradeDate { Text(ResearchFormat.day(date)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if state.loading { ProgressView().controlSize(.small) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            if let stats = state.statistics?.value {
                HStack(spacing: 22) {
                    metric("涨停", stats.limitUp.map(String.init) ?? "—")
                    metric("跌停", state.pools[.down]?.value.total.map(String.init) ?? "—")
                    metric("炸板", state.pools[.broken]?.value.total.map(String.init) ?? "—")
                    metric("封板率", stats.sealRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                    Spacer(minLength: 0)
                }
                if !stats.tiers.isEmpty {
                    Text(stats.tiers.map { "\($0.boardNumber) 板 \($0.count) 家" }.joined(separator: "  ·  "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(stats.dataTime.map { "同花顺扶摇 · 采样 " + ResearchFormat.time($0) } ?? "同花顺扶摇 · 未提供采样时间")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(state.loading ? "正在获取市场统计…" : state.errors["统计"] ?? "暂无市场统计，点击查看或刷新")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit() }
    }
}

struct FuyaoSentimentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var onSelect: (SymbolID) -> Void = { _ in }
    @State private var kind: FuyaoLimitKind = .up
    @State private var onlyWatch = false
    @State private var historical = false
    @State private var date = Date.now
    private var requestedDate: Date? { historical ? date : nil }
    private var controller: FuyaoSentimentController { appState.research.sentiment }
    private var state: FuyaoSentimentController.State { controller.states[controller.key(requestedDate)] ?? .init() }
    private var watch: Set<SymbolID> { Set(appState.watchlist.allItems.map(\.symbol)) }
    private var rows: [FuyaoLimitStock] {
        (state.pools[kind]?.value.stocks ?? []).filter { !onlyWatch || $0.symbol.map(watch.contains) == true }
            .sorted { ($0.consecutiveDays ?? 0) == ($1.consecutiveDays ?? 0) ? $0.thscode < $1.thscode : ($0.consecutiveDays ?? 0) > ($1.consecutiveDays ?? 0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("市场情绪与涨跌停").font(.title2.bold()); Spacer()
                Button("刷新") { Task { await controller.load(date: requestedDate, force: true) } }.disabled(state.loading)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !appState.fuyaoResearchAvailable { Text("请在设置中连接并启用同花顺扶摇。").foregroundStyle(.secondary); Spacer() }
            else {
                HStack {
                    Toggle("查询历史", isOn: $historical).toggleStyle(.checkbox)
                    if historical { DatePicker("日期", selection: $date, in: Date.now.addingTimeInterval(-364 * 86_400)...Date.now, displayedComponents: .date).labelsHidden() }
                    Spacer()
                    Toggle("只看自选", isOn: $onlyWatch).toggleStyle(.checkbox)
                }.font(.caption)
                FuyaoSentimentSummary(state: state)
                Picker("股票池", selection: $kind) { ForEach(FuyaoLimitKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                if let pool = state.pools[kind]?.value {
                    Text("\(ResearchFormat.day(pool.tradeDate)) · 已载 \(pool.stocks.count) / \(pool.total.map(String.init) ?? "未知") 只；自选筛选仅覆盖已载数据。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(rows) { row in
                            Button { if let symbol = row.symbol { dismiss(); onSelect(symbol) } } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(row.name).fontWeight(.medium); Text(row.thscode).foregroundStyle(.secondary); if row.symbol.map(watch.contains) == true { Text("自选").foregroundStyle(.secondary) } }
                                        if let reason = row.reason, !reason.isEmpty { Text("来源解读：" + reason).foregroundStyle(.secondary).lineLimit(3) }
                                    }
                                    Spacer()
                                    Text(row.boardText ?? "")
                                    Text(ResearchFormat.percent(row.changePercent)).monospacedDigit()
                                }.font(.system(size: 12)).contentShape(Rectangle()).padding(.vertical, 5)
                            }.buttonStyle(.plain).disabled(row.symbol == nil)
                            Divider().opacity(0.4)
                        }
                        if rows.isEmpty, !state.loading { Text("已载数据中暂无匹配股票").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if state.pools[kind]?.value.hasMore == true {
                    Button("加载下一页") { Task { await controller.more(kind: kind, date: requestedDate) } }.disabled(state.loading)
                }
                ForEach(state.errors.keys.sorted(), id: \.self) { key in Text("\(key)：\(state.errors[key] ?? "获取失败")").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(22).frame(minWidth: 720, idealWidth: 900, minHeight: 530, idealHeight: 680)
            .task(id: "\(controller.key(requestedDate))-\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
                await controller.load(date: requestedDate)
            }
    }
}
