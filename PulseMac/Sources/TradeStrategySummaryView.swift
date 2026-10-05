import SwiftUI
import PulseCore
import PulseUI

struct TradeStrategySummaryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let query: String
    let selectedMonth: Date?
    private var summaries: [TradeStrategySummary] {
        TradeStrategySummary.make(from: appState.watchlist.tradeHistoryItems, query: query, selectedMonth: selectedMonth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("策略分析").font(.system(size: 23, weight: .semibold))
                    Text("完整开仓 → 平仓为一轮，分批卖出仍算一个样本")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if summaries.isEmpty {
                ContentUnavailableView("还没有完整交易轮次", systemImage: "chart.bar.xaxis",
                    description: Text("在复盘中填写策略标签；完整平仓后即可比较。校准和未平仓记录不计入样本。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(summaries) { row in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(row.strategy).font(.headline)
                                    Text(row.currencyCode).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(row.sampleCount) 轮").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack(alignment: .top, spacing: 24) {
                                    metric("已实现盈亏", row.realizedPnL.map {
                                        PriceFormatter.signedMoney($0, currencyCode: row.currencyCode)
                                    } ?? "—", color: row.realizedPnL.map { appState.palette.color(isUp: $0 >= 0) } ?? .secondary)
                                    metric("胜率", percent(row.winPercent))
                                    metric("平均盈利 / 平均亏损", row.payoffRatio.map { String(format: "%.2f", $0) } ?? "—")
                                    metric("按计划执行", percent(row.followedPlanPercent))
                                    Spacer(minLength: 0)
                                }
                                if row.missingFeeCount > 0 {
                                    Text("\(row.missingFeeCount) 笔费用未记或无效，盈亏可能不完整")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07)) }
                        }
                    }
                }
            }
            Text("沿用账本已记费用，不重复扣费；按平仓月份筛选、分币种统计。轮次内多个标签归入混合策略，未填归入未分类。样本少时结果参考价值有限。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24).frame(minWidth: 680, idealWidth: 760, minHeight: 420, idealHeight: 560)
    }

    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    private func metric(_ name: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(color)
        }
    }
}
