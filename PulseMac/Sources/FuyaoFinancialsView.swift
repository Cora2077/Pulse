import SwiftUI
import PulseCore
import PulseUI

struct FuyaoFinancialsView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    @State private var expanded = false
    private var state: FuyaoFinancialsController.State { appState.research.financials.states[symbol] ?? .init() }
    var body: some View {
        DisclosureGroup("财报与估值", isExpanded: $expanded) {
            FuyaoFinancialsContent(state: state) { Task { await appState.research.financials.load(symbol, force: true) } }
                .padding(.top, 8)
        }.font(.system(size: 12, weight: .medium))
            .task(id: "\(symbol.description)-\(expanded)-\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
                guard expanded, appState.fuyaoResearchAvailable else { return }
                await appState.research.financials.load(symbol)
            }
    }
}
struct FuyaoFinancialsContent: View {
    let state: FuyaoFinancialsController.State
    var onRefresh: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("整体合并报表 · 最新估值").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if state.loading { ProgressView().controlSize(.small) }
                Button("刷新财报", action: onRefresh).controlSize(.small).disabled(state.loading)
            }
            if let batch = state.valuation {
                if let value = batch.value {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 10) {
                        valuation("PE TTM", value.peTTM); valuation("PE MRQ", value.peMRQ); valuation("PB MRQ", value.pbMRQ)
                        valuation("PS TTM", value.psTTM); valuation("PCF TTM", value.pcfTTM)
                    }
                    Text(batch.dataTime.map { "估值数据 " + ResearchFormat.time($0) } ?? "来源未提供估值时间")
                        .font(.caption2).foregroundStyle(.secondary)
                } else { Text("来源暂无该股票的估值快照").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(FuyaoStatementKind.allCases, id: \.self) { kind in
                if let series = state.statements[kind] {
                    statement(kind, rows: series.value)
                }
            }
            ForEach(state.errors.keys.sorted(), id: \.self) { key in Text("\(key)：\(state.errors[key] ?? "获取失败")").font(.caption).foregroundStyle(.secondary) }
            Text("利润表与现金流量表按年初至报告期末累计展示；资产负债表为期末值。同比仅比较同币种、上年同期，基期非正或缺失时不计算。最新估值不代表历史分位；披露日期未知的记录需另行核实。")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func valuation(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value.map { String(format: "%.2f", $0) } ?? "—").font(.system(size: 14, weight: .medium)).monospacedDigit() }
    }
    @ViewBuilder private func statement(_ kind: FuyaoStatementKind, rows: [FuyaoFinancialPeriod]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            Text(kind.title).font(.system(size: 12, weight: .semibold))
            if let latest = rows.first {
                Text("报告期 \(String(latest.fiscalYear)) \(latest.fiscalPeriod)（\(ResearchFormat.day(latest.periodEnd))） · 披露 \(latest.disclosedAt.map(ResearchFormat.day) ?? "日期未知")")
                    .font(.caption2).foregroundStyle(.secondary)
                let fields = fields(kind)
                ForEach(fields, id: \.0) { key, title in
                    HStack {
                        Text(title).font(.caption)
                        Spacer()
                        Text(amount(latest.values[key], currency: latest.currency)).font(.system(size: 12).monospacedDigit())
                        Text(latest.yearOverYear(key, in: rows).map { "同比 " + ResearchFormat.percent($0) } ?? "同比 —")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                    }
                }
                DisclosureGroup("查看最近 \(rows.count) 期") {
                    ForEach(rows) { row in
                        HStack(alignment: .top) {
                            Text("\(String(row.fiscalYear)) \(row.fiscalPeriod)").frame(width: 75, alignment: .leading)
                            Text(fields.map { $0.1 + " " + amount(row.values[$0.0], currency: row.currency) }.joined(separator: " · "))
                            Spacer()
                            Text("披露 " + (row.disclosedAt.map(ResearchFormat.day) ?? "未知")).foregroundStyle(.secondary)
                        }.font(.caption2).padding(.vertical, 4)
                    }
                }.font(.caption)
            } else { Text("来源暂无可用报告").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func fields(_ kind: FuyaoStatementKind) -> [(String, String)] {
        switch kind { case .income: [("revenue", "营业收入"), ("parentProfit", "归母净利润")]
        case .balance: [("receivables", "应收账款"), ("assets", "总资产"), ("liabilities", "总负债")]
        case .cashFlow: [("operatingCashFlow", "经营现金流净额")] }
    }
    private func amount(_ value: Double?, currency: String?) -> String {
        guard let value else { return "—" }
        guard let currency, !currency.isEmpty else { return String(format: "%.2f（币种未知）", value) }
        return PriceFormatter.money(value, currencyCode: currency)
    }
}
