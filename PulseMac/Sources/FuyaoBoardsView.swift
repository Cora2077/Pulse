import SwiftUI
import PulseCore

struct FuyaoBoardsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var onSelect: (SymbolID) -> Void = { _ in }
    @State private var industry = true
    @State private var search = ""
    @State private var selected: FuyaoBoard?
    private var controller: FuyaoBoardsController { appState.research.boards }
    private var watchSymbols: Set<SymbolID> { Set(appState.watchlist.allItems.map(\.symbol)) }
    private var rows: [FuyaoBoard] {
        (controller.catalogs[industry]?.value ?? []).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.thscode.contains(search)
        }.sorted {
            let a = $0.symbol.flatMap { controller.quotes[$0]?.changePercent }
            let b = $1.symbol.flatMap { controller.quotes[$0]?.changePercent }
            if a != b { return (a ?? -.infinity) > (b ?? -.infinity) }
            return $0.thscode < $1.thscode
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("板块强弱").font(.title2.bold())
                    Text("同花顺行业 / 概念 · 选择板块查看相对强弱和成分股").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { Task {
                    await controller.loadCatalog(industry: industry, force: true)
                    if let selected { await controller.loadDetail(selected, force: true) }
                }}.disabled(!appState.fuyaoResearchAvailable || controller.loadingCatalog.contains(industry))
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !appState.fuyaoResearchAvailable {
                ContentUnavailableView("请连接同花顺扶摇", systemImage: "network", description: Text("在设置中连接并启用扶摇后查看板块数据。"))
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        Picker("分类", selection: $industry) { Text("行业").tag(true); Text("概念").tag(false) }.pickerStyle(.segmented)
                        TextField("搜索板块名称或代码", text: $search).textFieldStyle(.roundedBorder)
                        HStack {
                            Text("\(rows.count) 个板块 · 按当日涨跌排序").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if controller.loadingCatalog.contains(industry) { ProgressView().controlSize(.small) }
                        }
                        if let error = controller.errors[industry] { Text(error).font(.caption).foregroundStyle(.secondary) }
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(rows) { board in
                                    Button { selected = board } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(board.name).font(.system(size: 12, weight: .medium))
                                                if let time = board.symbol.flatMap({ controller.quotes[$0]?.timestamp }) {
                                                    Text("行情 \(ResearchFormat.time(time))").font(.caption2).foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer(minLength: 4)
                                            Text(ResearchFormat.percent(board.symbol.flatMap { controller.quotes[$0]?.changePercent }))
                                                .font(.system(size: 12).monospacedDigit())
                                        }.padding(9).contentShape(Rectangle())
                                            .background(selected?.id == board.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain)
                                }
                                if rows.isEmpty, !controller.loadingCatalog.contains(industry) { Text("没有匹配板块").foregroundStyle(.secondary).padding() }
                            }
                        }
                    }.frame(width: 290)
                    Divider()
                    if let selected {
                        FuyaoBoardDetailContent(board: selected, detail: controller.details[selected.id] ?? .init(),
                            loading: controller.loadingDetails.contains(selected.id), watchSymbols: watchSymbols) { symbol in
                                dismiss(); onSelect(symbol)
                            }.id(selected.id)
                    } else {
                        ContentUnavailableView("选择一个板块", systemImage: "square.grid.3x3", description: Text("查看近 5 / 20 个交易日相对沪深 300 的表现，以及当前成分股。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }.padding(20).frame(minWidth: 850, idealWidth: 1000, minHeight: 560, idealHeight: 680)
            .task(id: "\(industry)-\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
                guard appState.fuyaoResearchAvailable else { return }
                await controller.loadCatalog(industry: industry)
            }
            .task(id: "\(selected?.id ?? "")-\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
                if let selected, appState.fuyaoResearchAvailable { await controller.loadDetail(selected) }
            }
            .onChange(of: industry) { _, _ in selected = nil }
    }
}

struct FuyaoBoardDetailContent: View {
    let board: FuyaoBoard
    let detail: FuyaoBoardsController.Detail
    let loading: Bool
    let watchSymbols: Set<SymbolID>
    var onSelect: (SymbolID) -> Void = { _ in }
    @State private var onlyWatch = false
    private var members: [FuyaoConstituent] { detail.constituents?.value ?? [] }
    private var watchCount: Int { members.filter { $0.symbol.map(watchSymbols.contains) == true }.count }
    private var quoteCount: Int { members.filter { $0.symbol.flatMap { detail.quotes[$0] } != nil }.count }
    private var rows: [FuyaoConstituent] {
        members.filter { !onlyWatch || $0.symbol.map(watchSymbols.contains) == true }.sorted {
            let a = $0.symbol.flatMap { detail.quotes[$0]?.changePercent }
            let b = $1.symbol.flatMap { detail.quotes[$0]?.changePercent }
            return a == b ? $0.thscode < $1.thscode : (a ?? -.infinity) > (b ?? -.infinity)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) { Text(board.name).font(.title3.bold()); Text(board.thscode).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 12) {
                    metric("近 5 日相对沪深 300", value: detail.strength?.fiveDay, own: detail.strength?.boardFiveDay)
                    metric("近 20 日相对沪深 300", value: detail.strength?.twentyDay, own: detail.strength?.boardTwentyDay)
                }
                if let time = detail.strength?.dataTime { Text("计算锚点 \(ResearchFormat.day(time))").font(.caption2).foregroundStyle(.secondary) }
                Text("按相同基准交易日计算；相对值为区间涨幅之差。盘中日线可能尚未收盘。")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("当前成分 \(members.count) 只 · 有报价 \(quoteCount) 只 · 自选 \(watchCount) 只").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Toggle("只看自选", isOn: $onlyWatch).toggleStyle(.checkbox).font(.caption)
                }
                Text(detail.constituents?.dataTime.map { "成分数据 \(ResearchFormat.time($0))" } ?? "来源未提供成分数据日期")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(detail.errors.keys.sorted(), id: \.self) { key in
                    Text("\(key)：\(detail.errors[key] ?? "获取失败")").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rows) { member in
                    Button {
                        if let symbol = member.symbol { onSelect(symbol) }
                    } label: {
                        HStack(spacing: 9) {
                            VStack(alignment: .leading, spacing: 3) { Text(member.name); Text(member.thscode).font(.caption2).foregroundStyle(.secondary) }
                            if member.symbol.map(watchSymbols.contains) == true { Text("自选").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            Text(ResearchFormat.percent(member.symbol.flatMap { detail.quotes[$0]?.changePercent })).monospacedDigit()
                            if member.symbol != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            else { Text("暂不支持").font(.caption2).foregroundStyle(.secondary) }
                        }.font(.system(size: 12)).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(member.symbol == nil)
                    Divider().opacity(0.4)
                }
                if rows.isEmpty, !loading { Text(onlyWatch ? "本板块没有自选交集" : "来源暂无成分股数据").font(.caption).foregroundStyle(.secondary) }
                Text("当前成分股不代表历史归属；行业目录可能包含多个分类层级。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func metric(_ title: String, value: Double?, own: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.2f 个百分点", $0) } ?? "数据不足").font(.system(size: 16, weight: .semibold)).monospacedDigit()
            Text("板块区间涨幅 \(ResearchFormat.percent(own))").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}

enum ResearchFormat {
    static func percent(_ value: Double?) -> String { value.flatMap { $0.isFinite ? String(format: "%+.2f%%", $0) : nil } ?? "—" }
    static func day(_ date: Date) -> String { format(date, pattern: "yyyy-MM-dd") }
    static func time(_ date: Date) -> String { format(date, pattern: "MM-dd HH:mm") }
    static func fullTime(_ date: Date) -> String { format(date, pattern: "yyyy-MM-dd HH:mm") }
    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
