import SwiftUI
import PulseCore
import PulseUI

/// 个股情报页的「除权除息」小节。
///
/// 只转述上游事件，并明确写出**配股不在本数据内**——`corporate-actions` 端点只有
/// 每股现金分红与每股送股比两个字段，配股比例/价格只出现在全市场 Parquet dump 里。
/// 把"没有配股记录"读成"没有配股"会直接误导口径判断。
struct FuyaoCorporateActionsView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    @State private var expanded = false

    private var controller: FuyaoCorporateActionsController { appState.research.corporateActions }
    private var entry: FuyaoCorporateActionsController.Entry? { controller.entries[symbol] }

    var body: some View {
        DisclosureGroup("除权除息", isExpanded: $expanded) {
            content.padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
        .task(id: "\(symbol.description)-\(expanded)-\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
            guard expanded, appState.fuyaoResearchAvailable else { return }
            await controller.load(symbol)
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近 3 次分红与送转").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if controller.loading.contains(symbol) { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await controller.load(symbol, force: true) } }
                    .controlSize(.small).disabled(controller.loading.contains(symbol))
            }
            if let entry {
                if entry.series.actions.isEmpty {
                    Text("来源未返回该标的的除权除息记录。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(entry.series.actions.prefix(3))) { action in
                        row(action)
                        Divider().opacity(0.4)
                    }
                }
                Text("仅含现金分红与送股；配股不在本数据内。除权日按 Asia/Shanghai 解释。")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(entry.lastError.map { "上次刷新失败：\($0)；以上为 \(ResearchFormat.time(entry.series.fetchedAt)) 的副本。" }
                     ?? "获取于 \(ResearchFormat.fullTime(entry.series.fetchedAt))")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if controller.loading.contains(symbol) {
                Text("正在获取除权数据…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(controller.lastError ?? "暂无除权数据，展开后重试。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ action: FuyaoCorporateAction) -> some View {
        FuyaoCorporateActionRow(action: action)
    }
}

/// 一次除权除息事件的展示行。
///
/// 抽成独立组件是为了让原生渲染检查检查**真实的**这一行，而不是自测里另画一个
/// "同形"的替身——替身一旦和真实实现分叉（例如用 `%.4g` 截掉精度），渲染图就会
/// 显示一个应用中并不存在的数字。
struct FuyaoCorporateActionRow: View {
    let action: FuyaoCorporateAction

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ResearchFormat.day(action.exDate))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                Spacer(minLength: 4)
                if action.hasCash {
                    Text("每股派 \(Self.amount(action.cashPerShare))")
                        .font(.system(size: 11)).monospacedDigit()
                }
                if action.hasBonus {
                    Text("每股送 \(Self.ratioText(action.bonusPerShare))")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let cash = action.cashPerShare, action.hasBonus, let bonus = action.bonusPerShare {
                Text("即每 10 股派 \(Self.amount(cash * 10)) 元、送 \(Self.bonusPerTen(bonus)) 股")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 分红金额按来源精度展示：去掉末尾多余的零，但不做任何舍入。
    static func amount(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return trimmed(value, maxFractionDigits: 6) + " 元"
    }

    static func ratioText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return trimmed(value, maxFractionDigits: 6) + " 股"
    }

    static func bonusPerTen(_ bonus: Double) -> String {
        trimmed(bonus * 10, maxFractionDigits: 6)
    }

    /// 定点输出后去掉多余的尾零；不做舍入（`NumberFormatter` 会四舍五入，这里不用）。
    static func trimmed(_ value: Double, maxFractionDigits: Int) -> String {
        var text = String(format: "%.\(maxFractionDigits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}
