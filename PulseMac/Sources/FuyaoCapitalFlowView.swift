import SwiftUI
import PulseCore
import PulseUI

/// 龙虎榜与异动监控的详情窗口。
///
/// 表格按**上榜区间分段**，段头写明"三日榜金额不与当日榜相加"——这是这份数据
/// 最容易算错的地方。区间未知的行单独成段，不并进当日榜。
struct FuyaoCapitalFlowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var onSelect: (SymbolID) -> Void = { _ in }

    @State private var board: FuyaoDragonTigerBoard = .all
    @State private var useHistoryDate = false
    @State private var date = Date.now
    @State private var showsMonitors = false

    private var controller: FuyaoDragonTigerController { appState.research.dragonTiger }
    private var symbols: Set<SymbolID> { Set(appState.watchlist.allItems.map(\.symbol)) }
    private var state: FuyaoDragonTigerController.State { controller.days[board] ?? .init() }
    private var requestedDate: Date? { useHistoryDate ? date : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !appState.fuyaoResearchAvailable {
                ContentUnavailableView("请连接同花顺扶摇", systemImage: "network",
                                       description: Text("在设置中连接并启用扶摇后查看龙虎榜与监控记录。"))
                Spacer()
            } else {
                controls
                Divider()
                ScrollView { list }.frame(maxHeight: .infinity)
                footnote
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .task(id: "\(board.rawValue)-\(requestedDate?.description ?? "latest")-\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
            guard appState.fuyaoResearchAvailable else { return }
            await controller.load(board: board, date: requestedDate)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("资金与监管").font(.title2.bold())
                Text("龙虎榜按上榜区间分段；三日榜金额不与当日榜相加。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.loadingBoards.contains(board) { ProgressView().controlSize(.small) }
            Button("刷新") {
                Task {
                    await controller.load(board: board, date: requestedDate, force: true)
                    await controller.loadMonitors(force: true)
                }
            }
            .disabled(!appState.fuyaoResearchAvailable)
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("榜单", selection: $board) {
                ForEach(FuyaoDragonTigerBoard.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            Toggle("历史日期", isOn: $useHistoryDate).toggleStyle(.checkbox).font(.caption)
            if useHistoryDate {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).frame(width: 120)
                Text("只能查一年内的交易日；非交易日会被来源拒绝。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("监管记录", isOn: $showsMonitors).toggleStyle(.switch).controlSize(.small)
        }
    }

    @ViewBuilder private var list: some View {
        FuyaoCapitalFlowContent(
            day: state.day,
            loading: controller.loadingBoards.contains(board),
            error: state.error,
            watchSymbols: symbols,
            showsHotMoney: board == .hotMoney,
            onSelect: { symbol in dismiss(); onSelect(symbol) }
        )
    }

    private var footnote: some View {
        Text("龙虎榜为收盘后发布的数据；同一股票可能同时出现在当日榜与三日榜。榜单与监控仅为来源记录，不构成因果解释或交易建议。")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return String(format: "%+.2f%%", fraction * 100)
    }
}

/// 龙虎榜内容本身，与外壳（窗口、日期选择、刷新）分离。
///
/// 分成两层是为了让原生渲染检查能直接构造这一层——外壳依赖 `AppState`，
/// 而内容只需要值，于是渲染图检查的就是实际用于显示的同一份代码。
struct FuyaoCapitalFlowContent: View {
    let day: FuyaoDragonTigerDay?
    var loading = false
    var error: String? = nil
    var watchSymbols: Set<SymbolID> = []
    var showsHotMoney = false
    var onSelect: (SymbolID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let day {
                metrics(day)
                if showsHotMoney {
                    if day.hotMoneyRows.isEmpty { empty("来源未返回游资榜记录。") }
                    ForEach(day.hotMoneyRows) { money in
                        hotMoneySection(money)
                    }
                } else {
                    rangeSections(day)
                }
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(loading ? "正在获取…" : "暂无数据").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metrics(_ day: FuyaoDragonTigerDay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 20) {
                metric("交易日期", ResearchFormat.day(day.tradeDate))
                metric("记录数", day.recordCount.map(String.init) ?? "—")
                metric("股票数", day.stockCount.map(String.init) ?? "—")
                if let time = day.dataTime { metric("数据时间", ResearchFormat.time(time)) }
                Spacer()
            }
            .font(.caption)
            // 列头只出现一次。逐行重复会让表格读起来像每行都有自己的单位。
            columnHeader
        }
    }

    /// 金额列的表头。与 `rowView` 的列宽必须一致，否则数字会对不齐。
    private var columnHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Spacer(minLength: 0)
            columnLabel("净买入", width: 76)
            columnLabel("机构", width: 76)
            columnLabel("涨跌", width: 58)
        }
        .font(.system(size: 9)).foregroundStyle(.tertiary)
        .padding(.top, 2)
    }

    private func columnLabel(_ text: String, width: CGFloat) -> some View {
        Text(text).frame(width: width, alignment: .trailing)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    @ViewBuilder private func rangeSections(_ day: FuyaoDragonTigerDay) -> some View {
        let grouped = day.rowsByRange
        ForEach([FuyaoDragonTigerRange.day, .threeDay], id: \.rawValue) { range in
            if let rows = grouped[range], !rows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    sectionHeader(range.title, detail: range == .threeDay
                                  ? "最近三个交易日累计，金额不可与当日榜相加"
                                  : "当日数据")
                    ForEach(rows) { row in rowView(row) }
                }
            }
        }
        let unknown = day.rowsWithUnknownRange
        if !unknown.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("区间未知", detail: "来源未给出上榜区间，无法与当日榜或三日榜比较")
                ForEach(unknown) { row in rowView(row) }
            }
        }
        if grouped.isEmpty && unknown.isEmpty {
            empty("来源未返回股票维度记录。")
        }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func rowView(_ row: FuyaoDragonTigerRow) -> some View {
        let isWatch = row.symbol.map { watchSymbols.contains($0) } == true
        return Button {
            if let symbol = row.symbol { onSelect(symbol) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // 名称在左、数值在右，两者都用 firstTextBaseline 对齐；名称列只有
                // 真正存在来源理由时才多占一行，否则空 VStack 会在行间留下空隙。
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(row.symbol == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        if isWatch {
                            Text("自选").font(.system(size: 8))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                        }
                        if row.thscode == nil {
                            Text("代码缺失").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                    if let reason = row.limitReason, !reason.isEmpty {
                        Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                // 缺身份的行走成灰阶：它仍然是榜单记录，只是不能点击跳转。
                let muted = row.symbol == nil
                value(FuyaoCapitalFlowCard.money(row.netValue), width: 76, muted: muted)
                value(FuyaoCapitalFlowCard.money(row.orgNetValue), width: 76, muted: muted)
                value(FuyaoCapitalFlowView.percent(row.changeFraction), width: 58, muted: muted)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.symbol == nil)
    }

    private func value(_ text: String, width: CGFloat, muted: Bool = false) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .frame(width: width, alignment: .trailing)
    }

    private func hotMoneySection(_ money: FuyaoHotMoney) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(money.name, detail: "聚合净买入 \(FuyaoCapitalFlowCard.money(money.buying))")
            if money.rows.isEmpty { empty("该游资本日无关联股票记录。") }
            ForEach(money.rows) { row in rowView(row) }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
