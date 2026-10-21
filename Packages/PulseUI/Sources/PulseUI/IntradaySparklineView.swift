import SwiftUI
import PulseCore

/// Shared by Canvas and coordinate/segment regression checks. A nil shared axis
/// retains trading-minute compression and the US extended-hours wings.
struct IntradaySparklineGeometry {
    struct Point: Equatable {
        let time: Date
        let price: Double
    }
    struct Segment {
        let kind: IntradaySessionKind
        let points: [Point]
    }
    let session: IntradayTradingSession
    let axis: IntradaySharedAxis?
    /// Unmodified provider bars. Quote samples never become fabricated OHLC/volume.
    let candles: [Candle]
    let points: [Point]
    let quotePoint: Point?

    init(candles: [Candle], market: Market, includesExtendedHours: Bool = false,
         sharedAxis: IntradaySharedAxis? = nil, liveQuote: Quote? = nil, now: Date = .now) {
        let trend = IntradayTrendSnapshot(candles: candles, market: market, includesExtendedHours: includesExtendedHours)
        let quote = liveQuote.flatMap { quote -> Quote? in
            guard quote.symbol.market == market, quote.price.isFinite, quote.price > 0,
                  quote.timestamp.timeIntervalSince(now) <= 60,
                  quote.marketState == nil || quote.marketState == .regular else { return nil }
            let frame = IntradayTradingSession(market: market, referenceDate: quote.timestamp)
            let atBoundary = quote.timestamp == frame.morningEnd || quote.timestamp == frame.close
            let regular = TradingCalendar.state(of: market, at: quote.timestamp) == .regular
                || (atBoundary && TradingCalendar.state(of: market, at: quote.timestamp.addingTimeInterval(-1)) == .regular)
            return regular && frame.contains(quote.timestamp) ? quote : nil
        }
        // A new trading day's quote must not be joined onto yesterday's curve.
        let frame = quote.map { $0.timestamp > trend.session.close
            ? IntradayTradingSession(market: market, referenceDate: $0.timestamp, includesExtendedHours: includesExtendedHours)
            : trend.session } ?? trend.session
        session = frame
        let axis = IntradaySharedAxis.supports(market) ? sharedAxis : nil
        self.axis = axis
        self.candles = trend.candles.filter { candle in
            guard frame.contains(candle.time) else { return false }
            if let axis, axis.fraction(for: candle.time) == nil { return false }
            if axis != nil, let morning = frame.morningEnd, let afternoon = frame.afternoonStart,
               candle.time > morning && candle.time < afternoon { return false }
            return true
        }
        var samples = self.candles.map { Point(time: $0.time, price: $0.close) }
        var quotePoint: Point?
        if let quote, frame.contains(quote.timestamp),
           quote.timestamp >= (samples.last?.time ?? frame.open),
           axis == nil || axis?.fraction(for: quote.timestamp) != nil {
            let sample = Point(time: quote.timestamp, price: quote.price)
            if samples.last?.time == sample.time { samples.removeLast() }
            samples.append(sample)
            quotePoint = sample
        }
        points = samples
        self.quotePoint = quotePoint
    }

    func xFraction(for date: Date) -> Double? {
        if let axis { return axis.fraction(for: date) }
        let span = session.axisUpperBound - session.axisLowerBound
        guard span > 0 else { return nil }
        return (session.minuteOffset(for: date) - session.axisLowerBound) / span
    }

    var segments: [Segment] {
        guard let first = points.first else { return [] }
        var result: [Segment] = []
        var current = [first]
        var currentKind = session.sessionKind(for: first.time)
        for candle in points.dropFirst() {
            let previous = current.last!
            let kind = session.sessionKind(for: candle.time)
            let gap = axis == nil
                ? session.minuteOffset(for: candle.time) - session.minuteOffset(for: previous.time)
                : candle.time.timeIntervalSince(previous.time) / 60
            let crossesLunch: Bool
            if axis != nil, let morning = session.morningEnd, let afternoon = session.afternoonStart {
                crossesLunch = previous.time <= morning && candle.time >= afternoon
            } else { crossesLunch = false }
            if crossesLunch || gap > 20 {
                result.append(Segment(kind: currentKind, points: current))
                current = [candle]; currentKind = kind
            } else if kind != currentKind {
                result.append(Segment(kind: currentKind, points: current))
                current = [previous, candle]; currentKind = kind
            } else { current.append(candle) }
        }
        result.append(Segment(kind: currentKind, points: current))
        return result
    }
}

/// Lightweight Canvas chart. A synchronized group must pass one sharedAxis to
/// all rows and its ruler. Unsupported markets keep their independent session.
public struct IntradaySparklineView: View {
    let candles: [Candle]
    let previousClose: Double?
    let market: Market
    let tint: Color
    let includesExtendedHours: Bool
    let sharedAxis: IntradaySharedAxis?
    let liveQuote: Quote?

    public init(candles: [Candle], previousClose: Double? = nil, market: Market, tint: Color,
                includesExtendedHours: Bool = false, referenceMarket: Market? = nil,
                sharedAxis: IntradaySharedAxis? = nil, liveQuote: Quote? = nil) {
        self.candles = candles; self.previousClose = previousClose
        self.market = market; self.tint = tint; self.includesExtendedHours = includesExtendedHours
        self.liveQuote = liveQuote
        // Compatibility for older single-reference callers. The app passes its
        // actual group axis, keeping filters and missing data from changing it.
        self.sharedAxis = sharedAxis ?? referenceMarket.flatMap {
            IntradaySharedAxis(markets: [.sh, .sz, .kr, .kq, .hk, .jp], referenceDate: candles.last?.time ?? .now, reference: $0)
        }
    }

    public var body: some View {
        let geometry = IntradaySparklineGeometry(candles: candles, market: market,
            includesExtendedHours: includesExtendedHours, sharedAxis: sharedAxis, liveQuote: liveQuote)
        Canvas { context, size in
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            if let lunch = geometry.axis?.lunchFractions {
                context.fill(Path(CGRect(x: size.width * lunch.lowerBound, y: 0,
                    width: size.width * (lunch.upperBound - lunch.lowerBound), height: size.height)),
                    with: .color(.orange.opacity(0.13)))
            }
            guard !geometry.points.isEmpty else { return }
            let domain = yDomain(for: geometry.points)
            func point(for candle: IntradaySparklineGeometry.Point) -> CGPoint {
                CGPoint(x: size.width * (geometry.xFraction(for: candle.time) ?? 0),
                    y: size.height * (1 - (candle.price - domain.lowerBound) / (domain.upperBound - domain.lowerBound)))
            }
            let session = geometry.session
            if geometry.axis == nil, session.includesExtendedHours {
                for minute in [0.0, session.totalMinutes] {
                    let x = size.width * (minute - session.axisLowerBound) / (session.axisUpperBound - session.axisLowerBound)
                    var rule = Path()
                    rule.move(to: CGPoint(x: x, y: 0)); rule.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(rule, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
                }
            }
            for segment in geometry.segments {
                let color = segment.kind == .regular ? tint : Color.secondary.opacity(0.75)
                var line = Path()
                line.move(to: point(for: segment.points[0]))
                for candle in segment.points.dropFirst() { line.addLine(to: point(for: candle)) }
                var area = line
                area.addLine(to: CGPoint(x: point(for: segment.points.last!).x, y: size.height))
                area.addLine(to: CGPoint(x: point(for: segment.points[0]).x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.16), color.opacity(0.01)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            if let sample = geometry.quotePoint {
                let endpoint = point(for: sample)
                context.fill(Path(ellipseIn: CGRect(x: endpoint.x - 1.5, y: endpoint.y - 1.5, width: 3, height: 3)), with: .color(tint))
            }
            if let previousClose {
                let y = size.height * (1 - (previousClose - domain.lowerBound) / (domain.upperBound - domain.lowerBound))
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: y)); rule.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(rule, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            }
        }
    }

    private func yDomain(for candles: [IntradaySparklineGeometry.Point]) -> ClosedRange<Double> {
        let closes = candles.map(\.price)
        let baseline = previousClose ?? closes.first ?? 0
        var low = min(closes.min() ?? baseline, baseline), high = max(closes.max() ?? baseline, baseline)
        let padding = max((high - low) * 0.1, high * 0.001, 0.0001)
        low -= padding; high += padding
        return low...high
    }
}
