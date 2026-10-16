import SwiftUI
import PulseActivity

/// Pulse's visual constants, as used on the lock screen, in the Dynamic Island
/// and on the watch smart-stack card.
///
/// Kept local to the widget extension on purpose: the extension renders inside a
/// different process with a different environment (rendering modes, tinting,
/// no app-level appearance settings), so it should not inherit the Mac app's
/// chart palette by accident. The *numbers* match the app's brand.
public enum PulseWidgetStyle {
    /// FFF brand blue for the waveform mark and the live accent.
    public static let brandBlue = Color(red: 0.20, green: 0.52, blue: 0.98)
    /// Red-up / green-down, the A-share convention used across Pulse.
    public static let up = Color(red: 0.94, green: 0.26, blue: 0.27)
    public static let down = Color(red: 0.04, green: 0.66, blue: 0.35)

    public static func color(for direction: PulseChangeDirection) -> Color {
        switch direction {
        case .up: up
        case .down: down
        case .flat: .secondary
        }
    }

    /// The color a status badge uses, independent of price direction.
    public static func color(for status: PulseActivityStatus) -> Color {
        switch status {
        case .live: brandBlue
        case .stale: .orange
        case .marketClosed: .secondary
        case .pausedToday, .disabled, .permissionRequired, .remoteUnavailable, .noCandidate: .secondary
        }
    }
}

/// A compact FFF waveform mark drawn as a `Shape` so it can be tinted by the
/// system's rendering mode (vibrant lock screen, accented watch card) without
/// losing its silhouette.
///
/// The path is a simplified single-stroke trace: flat lead-in, a small dip, the
/// tall spike, a deep trough, then the recovery — the same read as the app's
/// canonical mark, at sizes where the full curve would turn to mush.
public struct PulseWaveGlyph: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }

        path.move(to: point(0, 0.62))
        path.addLine(to: point(0.14, 0.62))
        path.addLine(to: point(0.22, 0.78))
        path.addLine(to: point(0.32, 0.30))
        path.addLine(to: point(0.42, 0.92))
        path.addLine(to: point(0.54, 0.18))
        path.addLine(to: point(0.66, 0.74))
        path.addLine(to: point(0.76, 0.52))
        path.addLine(to: point(1.0, 0.52))
        return path
    }
}

/// The waveform mark with the live segment in brand blue.
public struct PulseWaveMark: View {
    private let tint: Color
    private let liveTint: Color?

    public init(tint: Color = PulseWidgetStyle.brandBlue, liveTint: Color? = nil) {
        self.tint = tint
        self.liveTint = liveTint
    }

    public var body: some View {
        PulseWaveGlyph()
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .overlay(alignment: .trailing) {
                if let liveTint {
                    Circle()
                        .fill(liveTint)
                        .frame(width: 4, height: 4)
                        .offset(x: 1)
                }
            }
            .aspectRatio(2.4, contentMode: .fit)
    }
}
