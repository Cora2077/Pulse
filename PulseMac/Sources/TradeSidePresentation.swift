import AppKit
import SwiftUI
import PulseCore

/// Buy red, sell green: a trade direction is not a gain/loss reading. These
/// adaptive tokens never depend on the user's red-up/green-up quote preference.
enum TradeSideStyle {
    static let buy = adaptive(light: 0xC0392B, dark: 0xFF6B6B)
    static let sell = adaptive(light: 0x0D5A34, dark: 0x4ADE80)

    static func color(for kind: TradePlan.Kind) -> Color { kind == .buy ? buy : sell }
    static func color(for kind: PositionTransaction.Kind) -> Color {
        switch kind {
        case .buy: buy
        case .sell: sell
        case .adjustment: .secondary
        }
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

// Existing plan surfaces share the very same tokens, not a second colour table.
typealias PlanSideStyle = TradeSideStyle

struct TradeKindBadge: View {
    let kind: PositionTransaction.Kind

    private var label: String {
        switch kind {
        case .buy: PulseLocalization.localizedString("transaction.kind.buy")
        case .sell: PulseLocalization.localizedString("transaction.kind.sell")
        case .adjustment: PulseLocalization.localizedString("transaction.kind.adjustment")
        }
    }
    private var color: Color { TradeSideStyle.color(for: kind) }

    var body: some View {
        Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(kind == .adjustment ? 0.12 : 0.15)))
    }
}
