import SwiftUI
import PulseCore

/// Lightweight Canvas rendering of the same canonical trading-session geometry used by
/// `IntradayChartView`. It is suitable for dense list rows and off-screen share images.
///
/// With `includesExtendedHours` (US only) the pre/post-market wings render in the same
/// muted gray as the detail chart, separated by hairlines at the 9:30 / 16:00 boundaries —
/// without an x-axis those two cues are all that distinguishes the sessions.
public struct IntradaySparklineView: View {
    let candles: [Candle]
    let previousClose: Double?
    let market: Market
    let tint: Color
    let includesExtendedHours: Bool
    /// The market whose clock this line is positioned against. Nil (the default)
    /// draws the line on its own exchange's session, which is what every existing
    /// caller wants.
    ///
    /// Pass a reference market to place this line on someone else's axis: the
    /// session's boundaries are re-read in the reference zone, so a Korean bar
    /// stamped 15:12 Seoul and a Chinese bar stamped 14:12 Beijing both land on
    /// the same fraction of the plot width. The bars themselves are untouched —
    /// only the x-axis they are measured against moves.
    let referenceMarket: Market?

    public init(
        candles: [Candle],
        previousClose: Double? = nil,
        market: Market,
        tint: Color,
        includesExtendedHours: Bool = false,
        referenceMarket: Market? = nil
    ) {
        self.candles = candles
        self.previousClose = previousClose
        self.market = market
        self.tint = tint
        self.includesExtendedHours = includesExtendedHours
        self.referenceMarket = referenceMarket
    }

    private static let wingTint = Color.secondary.opacity(0.75)

    /// The session a line is drawn against: its own, or `referenceMarket`'s clock
    /// when one is given.
    ///
    /// Static and separate from `body` because this is the one decision that has
    /// to be right — every x position in the plot is derived from it — and it
    /// needs to be testable without rendering a Canvas. `nonisolated` because it
    /// touches no view state, only the session it is handed.
    nonisolated static func plotSession(
        of session: IntradayTradingSession,
        referenceMarket: Market?
    ) -> IntradayTradingSession {
        guard let referenceMarket, referenceMarket != session.market else { return session }
        return session.projected(to: referenceMarket)
    }

    /// The clock window this row is plotted against, shared by every row in an
    /// aligned group.
    ///
    /// Without a reference market the window is the session's own bounds, which
    /// is exactly the axis the unaligned rows have always used — a row drawn on
    /// its own session is unchanged.
    nonisolated static func axisBounds(
        of session: IntradayTradingSession,
        referenceMarket: Market?
    ) -> (start: Double, end: Double) {
        guard let referenceMarket else {
            let lower = minuteOfDay(session.preOpen ?? session.open, in: session.market.timeZone)
            let upper = minuteOfDay(session.postClose ?? session.close, in: session.market.timeZone)
            return (lower, upper)
        }
        return IntradayTradingSession.axisBounds(
            for: [session], reference: referenceMarket
        )
    }

    /// Minutes past midnight in the zone the window is read in.
    private nonisolated static func minuteOfDay(_ date: Date, in zone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(components.hour ?? 0) * 60
            + Double(components.minute ?? 0)
            + Double(components.second ?? 0) / 60
    }

    public var body: some View {
        let trend = IntradayTrendSnapshot(
            candles: candles,
            market: market,
            includesExtendedHours: includesExtendedHours
        )
        // Session used for two things: the axis the row is drawn against, and the
        // gap/segment splitting that decides where the line breaks. With a
        // reference market the row is measured against a shared clock window, so
        // two sessions of different lengths place the same instant at the same x.
        let session = Self.plotSession(
            of: trend.session, referenceMarket: referenceMarket
        )
        let bounds = Self.axisBounds(of: trend.session, referenceMarket: referenceMarket)
        Canvas { context, size in
            guard trend.candles.count > 1 else { return }
            let domain = yDomain(for: trend.candles)
            let axisSpan = session.axisUpperBound - session.axisLowerBound

            func xPosition(forMinute minute: Double) -> CGFloat {
                size.width * CGFloat((minute - session.axisLowerBound) / axisSpan)
            }

            /// x by absolute clock in the window's zone, which is the only reading
            /// that lines two rows up. Falls back to the session's own offset when
            /// a bar sits outside the window, so a stray bar still draws at the
            /// edge rather than vanishing.
            func xPosition(for candle: Candle) -> CGFloat {
                if let fraction = session.axisFraction(
                    for: candle.time, reference: session.market, bounds: bounds
                ) {
                    return size.width * CGFloat(fraction)
                }
                return xPosition(forMinute: session.minuteOffset(for: candle.time))
            }

            func point(for candle: Candle) -> CGPoint {
                let x = xPosition(for: candle)
                let y = 1 - (candle.close - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
                return CGPoint(x: x, y: size.height * CGFloat(y))
            }

            // Session separators on the 9:30 / 16:00 boundaries, standing in for the
            // detail chart's boundary gridlines.
            if session.includesExtendedHours {
                for minute in [0, session.totalMinutes] {
                    let x = xPosition(forMinute: minute)
                    var rule = Path()
                    rule.move(to: CGPoint(x: x, y: 0))
                    rule.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(
                        rule,
                        with: .color(.secondary.opacity(0.18)),
                        style: StrokeStyle(lineWidth: 0.5)
                    )
                }
            }

            for segment in lineSegments(trend.candles, session: session) {
                let color = segment.kind == .regular ? tint : Self.wingTint
                var line = Path()
                line.move(to: point(for: segment.candles[0]))
                for candle in segment.candles.dropFirst() {
                    line.addLine(to: point(for: candle))
                }

                var area = line
                area.addLine(to: CGPoint(x: point(for: segment.candles.last!).x, y: size.height))
                area.addLine(to: CGPoint(x: point(for: segment.candles[0]).x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.16), color.opacity(0.01)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
                context.stroke(
                    line,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                )
            }

            if let previousClose {
                let normalizedY = 1 - (previousClose - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
                let y = size.height * CGFloat(normalizedY)
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: y))
                rule.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    rule,
                    with: .color(.secondary.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
                )
            }
        }
    }

    private func yDomain(for candles: [Candle]) -> ClosedRange<Double> {
        let closes = candles.map(\.close)
        let baseline = previousClose ?? closes.first ?? 0
        var lo = min(closes.min() ?? baseline, baseline)
        var hi = max(closes.max() ?? baseline, baseline)
        let pad = max((hi - lo) * 0.1, hi * 0.001, 0.0001)
        lo -= pad
        hi += pad
        return lo...hi
    }

    private struct Segment {
        let kind: IntradaySessionKind
        let candles: [Candle]
    }

    /// Gaps are measured in trading minutes: the collapsed lunch break spans ~0 trading
    /// minutes and stays continuous, while genuine data holes still break the line.
    /// Segments also split at session boundaries so the wings render gray; the boundary
    /// candle repeats in both segments to keep the line itself continuous.
    private func lineSegments(_ candles: [Candle], session: IntradayTradingSession) -> [Segment] {
        guard let first = candles.first else { return [] }
        let breakMinutes: Double = 20
        var segments: [Segment] = []
        var current = [first]
        var currentKind = session.sessionKind(for: first.time)
        for candle in candles.dropFirst() {
            let kind = session.sessionKind(for: candle.time)
            let previous = current.last
            let gap = previous.map {
                session.minuteOffset(for: candle.time) - session.minuteOffset(for: $0.time)
            } ?? 0
            if kind != currentKind {
                segments.append(Segment(kind: currentKind, candles: current))
                current = (gap <= breakMinutes ? previous.map { [$0] } ?? [] : []) + [candle]
                currentKind = kind
            } else if gap > breakMinutes {
                segments.append(Segment(kind: currentKind, candles: current))
                current = [candle]
            } else {
                current.append(candle)
            }
        }
        segments.append(Segment(kind: currentKind, candles: current))
        return segments
    }
}
