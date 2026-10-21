import SwiftUI
import PulseCore

/// The exact same plot rectangle as the rows; callers own column insets.
public struct IntradayAxisRuler: View {
    let axis: IntradaySharedAxis
    public init(axis: IntradaySharedAxis) { self.axis = axis }

    public var body: some View {
        Canvas { context, size in
            if let lunch = axis.lunchFractions {
                context.fill(Path(CGRect(x: size.width * lunch.lowerBound, y: 0,
                    width: size.width * (lunch.upperBound - lunch.lowerBound), height: size.height)),
                    with: .color(.orange.opacity(0.13)))
            }
            for minute in axis.tickMinutes {
                guard let fraction = axis.fraction(minute: minute) else { continue }
                let x = size.width * fraction
                var rule = Path()
                rule.move(to: CGPoint(x: x, y: 0)); rule.addLine(to: CGPoint(x: x, y: 3))
                context.stroke(rule, with: .color(.secondary.opacity(0.45)), lineWidth: 0.5)
            }
            for minute in Self.visibleTicks(axis: axis, width: size.width) {
                guard let fraction = axis.fraction(minute: minute) else { continue }
                let x = size.width * fraction
                let title = String(format: "%02d:%02d", Int(minute) / 60, Int(minute) % 60)
                let text = Text(title).font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                // Clamp labels, never the tick itself: the line remains at the exact instant.
                context.draw(text, at: CGPoint(x: min(max(x, 13), max(size.width - 13, 13)), y: 9))
            }
        }
        .frame(height: 16)
        .allowsHitTesting(false)
        .accessibilityLabel("北京时间同步轴")
    }

    nonisolated static func visibleTicks(axis: IntradaySharedAxis, width: CGFloat) -> [Double] {
        guard width >= 28 else { return [] }
        if width < 60 { return [axis.referenceOpenMinute] }
        let first = axis.startMinute, last = axis.endMinute
        var chosen = Array(Set([axis.referenceOpenMinute, last]))
        // The A-share open is the key comparison point. At popover width, prefer
        // 09:30 to an 08:00 label that would hide the Chinese curve's true start.
        let candidates = (axis.lunchMinutes.map { [$0.lowerBound, $0.upperBound] } ?? [])
            + [first] + axis.tickMinutes
        func labelX(_ minute: Double) -> Double {
            let x = Double(width) * (axis.fraction(minute: minute) ?? 0)
            return min(max(x, 13), max(Double(width) - 13, 13))
        }
        for minute in candidates where !chosen.contains(minute) {
            if chosen.allSatisfy({ abs(labelX($0) - labelX(minute)) >= 28 }) { chosen.append(minute) }
        }
        return chosen.sorted()
    }
}
