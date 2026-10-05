import AppKit
import SwiftUI
import PulseCore
import PulseUI

/// Small shared primitives for the tactical pool board.
///
/// Everything here is presentation only: shapes, type scale, and the two
/// visual languages the board needs — a *real* figure (solid) and an
/// *assumed* figure (dashed, labelled, but with fully opaque text). None of
/// these types read a quote, a plan, or a setting, and none of them write
/// anything, so putting them in one file keeps the pool views from each
/// growing their own copy of the same dashed border.

// MARK: - Type scale and metrics

/// The board's one type scale. Sizes below 10 are deliberately absent: the
/// previous surfaces used 8–9pt labels that could not be read at the column
/// widths the four-pool board actually renders at.
enum PoolType {
    /// Screen title. Reduced from 24 so the pools start higher.
    static let title = Font.system(size: 20, weight: .semibold)
    /// Pool column name.
    static let poolTitle = Font.system(size: 13, weight: .semibold)
    /// Card title / instrument name.
    static let cardTitle = Font.system(size: 11, weight: .semibold)
    /// The one number a card leads with.
    static let quantity = Font.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()
    /// Money and price body text.
    static let number = Font.system(size: 12, weight: .semibold).monospacedDigit()
    /// A hypothetical (preview) number. Never smaller than the real one.
    static let assumedNumber = Font.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()
    /// Labels, captions, footnotes.
    static let label = Font.system(size: 10)
    static let labelMedium = Font.system(size: 10, weight: .medium)
    /// Chips and small buttons.
    static let chip = Font.system(size: 11, weight: .medium)
    /// The "hypothetical" badge on a dashed card.
    static let badge = Font.system(size: 10, weight: .semibold)
}

/// Fixed geometry the spec pins down, kept beside the type scale so a card and
/// a chip cannot disagree about how tall they are.
enum PoolMetric {
    /// Minimum hit target for anything clickable on a compact header row.
    static let minimumTarget: CGFloat = 28
    static let chipHeight: CGFloat = 28
    static let chipCorner: CGFloat = 14
    static let cardCorner: CGFloat = 10
    static let cardPadding: CGFloat = 8
    static let cardSpacing: CGFloat = 6
    /// Standard dashed stroke for anything that is not real yet.
    static let assumedDash: [CGFloat] = [5, 3]
    /// Empty pool/section placeholder height.
    static let emptyHeight: CGFloat = 44
    static let columnSpacing: CGFloat = 10
    /// Pool tint fill strength for a pool column's own background.
    static func poolWash(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.08 : 0.05 }
}

// MARK: - Copy

/// The pool surfaces localize through one function so a new string cannot ship
/// in only one language by accident.
func poolCopy(_ chinese: String, _ english: String) -> String {
    PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
}

// MARK: - Plan side

/// Buy/sell side colours, shared by every plan surface.
///
/// A plan's side is an *action* — deploy capital, raise capital — not a P&L
/// reading. It therefore must not borrow `ChangePalette`, whose two colours
/// mean "up" and "down" and swap when 红涨绿跌 is switched. Borrowing them made
/// a planned buy read as a gain and a planned sell as a loss, and made one plan
/// change colour when the user changed how they read quotes.
///
/// Neither hue is in the pool palette (grey/blue/orange) or the status palette
/// (orange margin, green/amber/red conditions), so a side badge, a pool column,
/// and a funding tag can share one card and stay three separate statements.
enum PlanSideStyle {
    /// Teal: "deploy capital in". Separated from the P&L green (#0AA859) by hue
    /// shift, and from strategic-pool blue (#007AFF) by saturation.
    static let buy = adaptive(light: 0x0F766E, dark: 0x2DD4BF)
    /// Magenta-pink: "take capital out". Separated from the P&L red (#F04444),
    /// verification purple (#AF52DE), and the margin orange.
    static let sell = adaptive(light: 0xDB2777, dark: 0xF472B6)

    /// The side colour of a plan kind.
    static func color(for kind: TradePlan.Kind) -> Color {
        kind == .buy ? buy : sell
    }

    /// The side colour of a recorded transaction kind.
    static func color(for kind: PositionTransaction.Kind) -> Color {
        kind == .buy ? buy : sell
    }

    /// AppKit-backed so the value resolves against the appearance in effect at
    /// draw time rather than whichever scheme was current when it was first read.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(planSideRGB: dark)
                : NSColor(planSideRGB: light)
        })
    }
}

private extension NSColor {
    /// `0xRRGGBB`, read in the sRGB space the two hex values above were picked in.
    convenience init(planSideRGB rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Assumption styling

/// Wraps a real figure so it reads as current, and an assumed one so it reads
/// as hypothetical without ever fading its text: the difference is the dashed
/// border, the tint wash, and the "hypothetical" badge — not opacity.
struct PoolAssumedBadge: View {
    let tint: Color

    var body: some View {
        Text(poolCopy("假设", "What if"))
            .font(PoolType.badge)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(tint, in: Capsule())
            .accessibilityLabel(poolCopy("假设数据", "Hypothetical figure"))
    }
}

/// Draws either a solid real border or the dashed hypothetical one, so the two
/// states are one decision per call site rather than a copied StrokeStyle.
struct PoolBorder: ViewModifier {
    let tint: Color
    let corner: CGFloat
    let isAssumed: Bool
    /// Selection/emphasis wins over the assumed dash: a selected hypothetical
    /// card still has to look selected.
    var isEmphasized = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner)
                    .fill(tint.opacity(isAssumed ? 0.04 : 0))
            )
            .overlay {
                RoundedRectangle(cornerRadius: corner)
                    .stroke(
                        tint.opacity(isEmphasized ? 0.9 : (isAssumed ? 0.55 : 0.3)),
                        style: StrokeStyle(
                            lineWidth: isEmphasized ? 1.5 : 1,
                            dash: isAssumed ? PoolMetric.assumedDash : []
                        )
                    )
            }
    }
}

extension View {
    /// Real (solid) or hypothetical (dashed + wash) card chrome.
    func poolBorder(tint: Color, corner: CGFloat = PoolMetric.cardCorner,
                    isAssumed: Bool, isEmphasized: Bool = false) -> some View {
        modifier(PoolBorder(tint: tint, corner: corner, isAssumed: isAssumed, isEmphasized: isEmphasized))
    }

    /// The board-wide hypothetical frame: an inset dashed accent rectangle.
    func poolAssumedBoardFrame(_ isAssumed: Bool) -> some View {
        overlay {
            if isAssumed {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, dash: PoolMetric.assumedDash))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Assumed-number formatting

/// Prefixes a hypothetical figure with "≈" so the number itself carries the
/// assumption, not only the surrounding chrome. Never applied to a real figure.
enum PoolAmountText {
    static func assumed(_ text: String) -> String { "≈" + text }

    static func money(_ value: Double, currency: String, assumed isAssumed: Bool) -> String {
        let text = PriceFormatter.money(value, currencyCode: currency)
        return isAssumed ? assumed(text) : text
    }
}

// MARK: - Track gauge

/// The shared horizontal resource track: a rounded trough with per-pool
/// segments, optional hatch fill for planned money, and an optional limit tick.
///
/// `segments` are (pool, value) pairs; a zero-length segment simply draws
/// nothing. The gauge never labels a total — the caller does that — so an
/// unvaluable figure stays a word at the call site.
struct PoolTrackGauge: View {
    struct Segment: Identifiable {
        let pool: PositionPool
        let value: Double
        var id: String { pool.rawValue }
    }

    /// Slot height: 10 for holdings/cash, 6 for the planned-budget trough.
    var height: CGFloat = 10
    /// Draws the budget trough with diagonal hatching rather than a flat fill.
    var hatched = false
    /// Fallback colour when a segment carries no pool (the cash slot).
    var tint: Color?
    var segments: [Segment] = []
    var scale: Double
    /// A dashed outline where a constrained budget ends.
    var limitFraction: Double?
    /// The trough is normally an opaque slot that the segments sit inside. When
    /// this gauge is layered over another track it must paint no background at
    /// all, or it would cover the track underneath.
    var drawsTrack = true

    @Environment(\.colorScheme) private var colorScheme

    private var visible: [Segment] {
        guard scale.isFinite, scale > 0 else { return [] }
        return segments.filter { $0.value.isFinite && $0.value > 0 }
    }

    /// Total of the segments actually drawn, in the same units as `scale`.
    /// Non-finite values are dropped rather than poisoning the sum, and the
    /// result is clamped to `scale` so an over-committed pool cannot paint
    /// outside its slot.
    private var visibleTotal: Double {
        let total = visible.reduce(0) { $0 + $1.value }
        guard total.isFinite, scale.isFinite, scale > 0 else { return 0 }
        return min(total, scale)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if drawsTrack {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                }
                if hatched {
                    // The hatched trough is the budget slot itself and is filled
                    // to the amount it actually holds. Dividing by `scale` — not
                    // by itself — keeps it the same length as the solid track,
                    // which is the whole point of showing them together.
                    HatchPattern()
                        .stroke(.primary.opacity(0.25), lineWidth: 1)
                        .frame(width: proxy.size.width * Self.fraction(visibleTotal, scale: scale), height: height)
                        .clipShape(RoundedRectangle(cornerRadius: height / 2))
                } else {
                    HStack(spacing: 1.5) {
                        ForEach(visible) { segment in
                            Rectangle()
                                .fill(segment.pool == .unassigned ? (tint ?? segment.pool.tint) : segment.pool.tint)
                                .frame(width: width(segment.value, in: max(0, proxy.size.width - CGFloat(max(0, visible.count - 1)) * 1.5)))
                        }
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: height / 2))
                }
                if let limitFraction, limitFraction.isFinite {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.secondary)
                        .frame(width: 1, height: height + 2)
                        .offset(x: max(0, min(proxy.size.width - 1, proxy.size.width * limitFraction)))
                }
            }
        }
        .frame(height: height)
    }

    static func fraction(_ value: Double, scale: Double) -> Double {
        guard scale.isFinite, scale > 0, value.isFinite else { return 0 }
        return max(0, min(1, value / scale))
    }

    private func width(_ value: Double, in total: CGFloat) -> CGFloat {
        total * Self.fraction(value, scale: scale)
    }
}

/// Diagonal hatch used by the planned-budget trough.
private struct HatchPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let step: CGFloat = 6
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        return path
    }
}

// MARK: - Action chip

/// One actionable count above the board. Clicking toggles a highlight filter
/// only — it never changes a total, a plan, or a setting.
struct PoolActionChip: View {
    let systemImage: String
    let title: String
    let count: Int
    var tint: Color = .orange
    var isSelected: Bool
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(PoolType.chip)
                Text("\(count)").font(PoolType.chip.monospacedDigit())
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: PoolMetric.chipHeight)
            .background(.primary.opacity(0.05), in: Capsule())
            .overlay {
                Capsule().stroke(isSelected ? tint.opacity(0.9) : tint.opacity(0.28),
                                 lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(title) \(count)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The collapsed currency pill: one line of holdings + remaining budget.
struct PoolCurrencyPill: View {
    let code: String
    let holdings: Double?
    let remaining: Double?
    let isCashUnknown: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(code).font(.system(size: 10, weight: .bold, design: .rounded))
                if let holdings {
                    Text(poolCopy("持仓 ", "Held ") + PriceFormatter.money(holdings, currencyCode: code))
                        .font(PoolType.labelMedium.monospacedDigit())
                } else {
                    Text(poolCopy("持仓 —", "Held —")).font(PoolType.labelMedium).foregroundStyle(.tertiary)
                }
                Text("·").foregroundStyle(.tertiary)
                if isCashUnknown {
                    Text(poolCopy("现金未录", "Cash not recorded"))
                        .font(PoolType.labelMedium).foregroundStyle(.orange)
                } else if let remaining, remaining < 0 {
                    // A negative "左余" reads like debt. Report it the same way
                    // the action chip does: a shortfall, in the warning colour.
                    Text(poolCopy("缺口 ", "Short ") + PriceFormatter.money(abs(remaining), currencyCode: code))
                        .font(PoolType.labelMedium.monospacedDigit()).foregroundStyle(.orange)
                } else if let remaining {
                    Text(poolCopy("余量 ", "Left ") + PriceFormatter.money(remaining, currencyCode: code))
                        .font(PoolType.labelMedium.monospacedDigit())
                } else {
                    Text(poolCopy("余量 —", "Left —")).font(PoolType.labelMedium).foregroundStyle(.tertiary)
                }
                Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: PoolMetric.minimumTarget)
            .background(.primary.opacity(0.05), in: Capsule())
            .overlay { Capsule().stroke(.primary.opacity(0.08), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(poolCopy("\(code) 资金明细", "\(code) capital detail"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Warnings

/// The single compressed warning entry point. Every always-on banner the board
/// used to carry (sync conflict, reconciliation, budget notice) folds into this
/// one chip plus its popover, so the pools keep the top of the screen while
/// every one of those actions stays reachable.
struct PoolWarningChip: View {
    let count: Int
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold))
                Text(poolCopy("警示", "Warnings")).font(PoolType.chip)
                Text("\(count)").font(PoolType.chip.monospacedDigit())
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .frame(height: PoolMetric.chipHeight)
            .background(Color.orange.opacity(0.08), in: Capsule())
            .overlay { Capsule().stroke(Color.orange.opacity(isOpen ? 0.9 : 0.3), lineWidth: isOpen ? 1.5 : 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(poolCopy("同步冲突、核对与预算提示", "Sync conflicts, reconciliation, and budget notices"))
    }
}

/// One line inside the warning list. Text is a plain label; the action button
/// is separate so a warning is never a hidden click target.
struct PoolWarningRow: View {
    let systemImage: String
    let text: String
    var actionTitle: String?
    var help: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .frame(width: 14)
            Text(text)
                .font(PoolType.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .help(help ?? actionTitle)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Node/path styling

/// One step in the plan-lineage chain, drawn as a tinted dot on a vertical
/// rule. Shared by the lineage panel so the "condition → plan → fill → now →
/// remaining" sequence keeps one visual grammar.
struct PoolLineageNode<Content: View>: View {
    let tint: Color
    /// Dashed when the step has not happened yet (a remaining intention).
    var isAssumed = false
    var isLast = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isAssumed ? AnyShapeStyle(.background) : AnyShapeStyle(tint))
                    .overlay {
                        Circle().stroke(tint, style: StrokeStyle(lineWidth: 1.5, dash: isAssumed ? [2, 2] : []))
                    }
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)
                if !isLast {
                    Rectangle()
                        .fill(tint.opacity(0.5))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 8)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Small shared labels

/// An inline "label value" pair used across the capital panel and lineage.
struct PoolLabeledValue: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var assumed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(PoolType.label).foregroundStyle(.secondary)
            Text(assumed ? PoolAmountText.assumed(value) : value)
                .font(assumed ? PoolType.assumedNumber : PoolType.number)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// A short tinted status pill. Every use pairs it with a symbol so state is
/// never carried by colour alone.
struct PoolStatusPill: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).font(PoolType.labelMedium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(tint.opacity(0.1), in: Capsule())
    }
}
