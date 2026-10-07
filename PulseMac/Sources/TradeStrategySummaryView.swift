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
                    Text(PulseLocalization.localizedString("strategy.title")).font(.system(size: 23, weight: .semibold))
                    Text(PulseLocalization.localizedString("strategy.subtitle"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(PulseLocalization.localizedString("strategy.done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if summaries.isEmpty {
                ContentUnavailableView(PulseLocalization.localizedString("strategy.empty.title"), systemImage: "chart.bar.xaxis",
                    description: Text(PulseLocalization.localizedString("strategy.empty.body")))
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
                                    Text(PulseLocalization.localizedString("strategy.sampleCount", row.sampleCount)).font(.caption).foregroundStyle(.secondary)
                                }
                                HStack(alignment: .top, spacing: 24) {
                                    metric(PulseLocalization.localizedString("strategy.metric.realized"), row.realizedPnL.map {
                                        PriceFormatter.signedMoney($0, currencyCode: row.currencyCode)
                                    } ?? "—", color: row.realizedPnL.map { appState.palette.color(isUp: $0 >= 0) } ?? .secondary)
                                    metric(PulseLocalization.localizedString("strategy.metric.winRate"), percent(row.winPercent))
                                    metric(PulseLocalization.localizedString("strategy.metric.payoff"), row.payoffRatio.map { String(format: "%.2f", $0) } ?? "—")
                                    metric(PulseLocalization.localizedString("strategy.metric.onPlan"), percent(row.followedPlanPercent))
                                    Spacer(minLength: 0)
                                }
                                if row.missingFeeCount > 0 {
                                    Text(PulseLocalization.localizedString("strategy.missingFees", row.missingFeeCount))
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
            Text(PulseLocalization.localizedString("strategy.footnote"))
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
