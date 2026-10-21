import Foundation

/// One group-wide wall-clock window. Build it once from group membership and
/// pass the same value to the ruler and every eligible row, including empty rows.
public struct IntradaySharedAxis: Sendable, Hashable {
    public let reference: Market
    public let startMinute: Double
    public let endMinute: Double
    public let referenceOpenMinute: Double
    public let lunchMinutes: ClosedRange<Double>?
    public let tickMinutes: [Double]

    public static func supports(_ market: Market) -> Bool {
        switch market {
        case .sh, .sz, .hk, .jp, .kr, .kq: true
        default: false
        }
    }

    public init?(markets: [Market], referenceDate: Date, reference: Market = .sh) {
        let markets = Set(markets.filter(Self.supports))
        guard !markets.isEmpty, Self.supports(reference) else { return nil }
        self.reference = reference
        let sessions = markets.map { IntradayTradingSession(market: $0, referenceDate: referenceDate) }
        let bounds = IntradayTradingSession.axisBounds(for: sessions, reference: reference)
        startMinute = bounds.start
        endMinute = bounds.end
        let frame = IntradayTradingSession(market: reference, referenceDate: referenceDate)
        referenceOpenMinute = Self.minute(frame.open, in: reference)
        if let morning = frame.morningEnd, let afternoon = frame.afternoonStart {
            lunchMinutes = Self.minute(morning, in: reference)...Self.minute(afternoon, in: reference)
        } else { lunchMinutes = nil }
        tickMinutes = Array(Set([bounds.start, Self.minute(frame.open, in: reference),
            Self.minute(frame.close, in: reference), bounds.end]
            + [frame.morningEnd, frame.afternoonStart].compactMap { $0.map { Self.minute($0, in: reference) } }))
            .sorted()
    }

    public func fraction(for date: Date) -> Double? { fraction(minute: Self.minute(date, in: reference)) }

    public func fraction(minute: Double) -> Double? {
        guard minute.isFinite, minute >= startMinute, minute <= endMinute, endMinute > startMinute else { return nil }
        return (minute - startMinute) / (endMinute - startMinute)
    }

    public var lunchFractions: ClosedRange<Double>? {
        guard let lunchMinutes, let start = fraction(minute: lunchMinutes.lowerBound),
              let end = fraction(minute: lunchMinutes.upperBound) else { return nil }
        return start...end
    }

    private static func minute(_ date: Date, in market: Market) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(parts.hour ?? 0) * 60 + Double(parts.minute ?? 0) + Double(parts.second ?? 0) / 60
    }
}
