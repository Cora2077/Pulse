import SwiftUI
import PulseCore
import PulseUI

/// 计划价格口径提示：一条计划在除权之前设价，除权后不复权序列出现断层。
///
/// 这里刻意只做一件事——把已经发生的除权事实与"请复核"放在一起，然后停下。
/// 它不提供"自动改价"按钮，也不计算除权后应该等于多少：那会替用户做交易判断，
/// 而且配股不在数据源里，任何自动换算都会在配股场景下算错。
struct FuyaoPlanPriceBasisNoticeView: View {
    let notice: FuyaoPlanPriceBasisNotice
    /// 卡片里紧凑显示，详情页展开说明。
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            Label {
                Text(compact ? "除权后请复核触发价" : "该计划的触发价设定于除权之前")
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
            } icon: {
                Image(systemName: "exclamationmark.triangle").font(.system(size: compact ? 9 : 10))
            }
            .foregroundStyle(.orange)
            if !compact {
                Text(Self.explanation(notice.action))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !compact {
                Text("不复权价格序列在该日出现断层，触发价相对位置已改变。本应用不会自动改价。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 0 : 8)
        .background(compact ? Color.clear : Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 7))
        .help(Self.help(notice.action))
    }

    /// 事实陈述：日期 + 上游给出的两个原始数值。没有推断、没有换算。
    static func explanation(_ action: FuyaoCorporateAction) -> String {
        var parts: [String] = []
        if let cash = action.cashPerShare, action.hasCash {
            parts.append("每股派 \(Self.number(cash)) 元")
        }
        if let bonus = action.bonusPerShare, action.hasBonus {
            parts.append("每股送 \(Self.number(bonus)) 股")
        }
        let detail = parts.isEmpty ? "该日除权除息" : parts.joined(separator: "、")
        return "\(ResearchFormat.day(action.exDate)) 除权：\(detail)。"
    }

    static func help(_ action: FuyaoCorporateAction) -> String {
        """
        除权除息日：\(ResearchFormat.fullTime(action.exDate))
        每股现金分红（税前）：\(action.cashPerShare.map { String(format: "%.6g 元", $0) } ?? "未提供")
        每股送股比例：\(action.bonusPerShare.map { String(format: "%.6g", $0) } ?? "未提供")

        配股不在本数据源内。这里只提示复核，不会修改计划价格。
        """
    }

    private static func number(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}

/// 某个标的的全部复核提示（工作台与计划列表用）。只读，无操作按钮。
struct FuyaoPlanPriceBasisNoticeList: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    let plans: [TradePlan]

    private var controller: FuyaoCorporateActionsController { appState.research.corporateActions }

    var body: some View {
        let notices = controller.notices(plans: plans.map { (symbol, $0) })
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notices) { notice in
                    FuyaoPlanPriceBasisNoticeView(notice: notice, compact: true)
                }
            }
            .task(id: "\(symbol.description)-\(appState.fuyaoResearchAvailable)-\(appState.research.generation)") {
                guard appState.fuyaoResearchAvailable else { return }
                await controller.load(symbol)
            }
        }
    }
}
