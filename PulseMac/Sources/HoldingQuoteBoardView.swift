import SwiftUI
import PulseCore
import PulseUI

/// A quiet, fixed-order quote list. Daily change is primary; position cost is not required.
struct HoldingQuoteBoardView: View {
    let board: HoldingQuoteBoard
    var palette = ChangePalette()
    var onSelect: (SymbolID) -> Void = { _ in }
    var onShowPlans: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if board.rows.isEmpty {
                Text(copy("当前范围没有持仓，可切换自选查看行情。", "No holdings in this scope. Switch to Watchlist for quotes."))
                    .font(.caption).foregroundStyle(.secondary).padding(16)
            } else {
                ViewThatFits(in: .horizontal) {
                    table(wide: true).frame(minWidth: 650)
                    table(wide: false)
                }
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.07)) }
    }

    private func table(wide: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(copy("名称 / 代码", "Instrument")).frame(maxWidth: .infinity, alignment: .leading)
                if wide { label(copy("行情", "Feed"), width: 52) }
                label(copy("最新价", "Last"), width: wide ? 96 : 72)
                label(copy("涨跌幅", "Change %"), width: 80)
                if wide {
                    label(copy("涨跌额", "Change"), width: 76)
                    label(copy("计划", "Plans"), width: 94)
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 28)
            Divider().opacity(0.6)
            ForEach(board.rows) { row in
                HoldingQuoteRow(row: row, wide: wide, palette: palette) { onSelect(row.symbol) }
                if row.id != board.rows.last?.id { Divider().opacity(0.3).padding(.horizontal, 12) }
            }
        }
    }

    private func label(_ title: String, width: CGFloat) -> some View {
        Text(title).frame(width: width, alignment: .trailing)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(copy("涨跌幅按昨收计算 · 非持仓收益", "Change vs previous close · not holding return"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if board.reachedSymbolCount > 0 {
                Button(action: onShowPlans) {
                    Text(copy("\(board.reachedSymbolCount)只到价 · 核对计划", "\(board.reachedSymbolCount) at target · Check plans"))
                        .font(.system(size: 10, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func copy(_ zh: String, _ en: String) -> String { MainWorkspacePage.copy(zh, en) }
}

private struct HoldingQuoteRow: View {
    let row: HoldingQuoteBoard.Row
    let wide: Bool
    let palette: ChangePalette
    let onSelect: () -> Void
    @State private var hovering = false

    private var direction: Color { row.change.map { palette.color(for: $0) } ?? .primary }
    private var lastText: String {
        row.quote.map { PriceFormatter.price($0.price, market: row.symbol.market) } ?? "—"
    }
    private var percentText: String {
        row.changePercent.map { String(format: "%+.2f%%", $0) } ?? "—"
    }
    private var statusText: String {
        switch row.referenceState {
        case .current: copy("更新", "Updated")
        case .delayed: copy("延迟", "Delayed")
        case .reference: copy("参考", "Reference")
        case .stale: copy("过期", "Stale")
        case .missing: copy("待报价", "No quote")
        }
    }
    private var planText: String {
        switch row.planSignal {
        case .none: "—"
        case .waiting(let count): copy("\(count)条计划", "\(count) plans")
        case .reached: copy("到价待核对", "Check target")
        }
    }
    private var planIcon: String {
        if case .reached = row.planSignal { return "target" }
        return "scope"
    }
    private var planColor: Color {
        if case .reached = row.planSignal { return .orange }
        return .secondary
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .help(row.name)
                    if wide {
                        Text(row.symbol.displayCode).font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary).fixedSize()
                    } else {
                        if row.planSignal != .none {
                            Image(systemName: planIcon).font(.system(size: 9)).foregroundStyle(planColor).help(planText)
                        }
                        if row.referenceState != .current {
                            Text(statusText).font(.system(size: 8))
                                .foregroundStyle(row.referenceState == .stale ? Color.orange : .secondary)
                                .fixedSize().help(provenance)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if wide {
                    Text(statusText).font(.system(size: 9))
                        .foregroundStyle(row.referenceState == .stale ? Color.orange : .secondary)
                        .frame(width: 52, alignment: .trailing).help(provenance)
                }
                Text(lastText).frame(width: wide ? 96 : 72, alignment: .trailing)
                    .foregroundStyle(direction).help(provenance)
                Text(percentText).frame(width: 80, alignment: .trailing).foregroundStyle(direction)
                if wide {
                    Text(row.change.map { PriceFormatter.change($0, market: row.symbol.market) } ?? "—")
                        .frame(width: 76, alignment: .trailing).foregroundStyle(direction)
                    HStack(spacing: 4) {
                        if row.planSignal != .none { Image(systemName: planIcon).font(.system(size: 9)) }
                        Text(planText).font(.system(size: 10))
                    }
                    .foregroundStyle(planColor).frame(width: 94, alignment: .trailing)
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .padding(.horizontal, 12).frame(height: 30)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.045) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(row.name), \(row.symbol.displayCode), \(copy("最新价", "Last")) \(lastText), \(copy("涨跌幅", "Change")) \(percentText), \(statusText), \(planText)")
    }

    private var provenance: String {
        guard let quote = row.quote else { return copy("未取得可用报价", "No usable quote") }
        let source = quote.sourceName ?? quote.sourceID ?? copy("来源未知", "Unknown source")
        let time: String
        if quote.timestamp.timeIntervalSince1970.isFinite {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = row.symbol.market.timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            time = formatter.string(from: quote.timestamp) + " " + row.symbol.market.timeZoneDisplayName
        } else { time = copy("时间未知", "Time unknown") }
        let delay = quote.sourceDelay.flatMap { $0.isFinite && $0 > 0 ? " · " + copy("源延迟", "Feed delay") + " " + String(format: "%.0f", $0) + "s" : nil } ?? ""
        return "\(source) · \(time)\(delay)"
    }

    private func copy(_ zh: String, _ en: String) -> String { MainWorkspacePage.copy(zh, en) }
}
