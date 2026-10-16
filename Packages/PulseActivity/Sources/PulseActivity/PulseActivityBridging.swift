import Foundation

// MARK: - ActivityKit bridging
//
// The types above are plain Swift so the app, the widget extension, tests and a
// push service can all share them. ActivityKit itself only exists on iOS, so the
// conformance and the lifecycle live behind `canImport`.

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// Makes ``PulseActivityAttributes`` usable as an ActivityKit attribute type,
/// with ``PulseActivityState`` as its content state. The two halves are declared
/// in one place so the app and the widget extension cannot disagree about which
/// payload type an activity carries.
extension PulseActivityAttributes: ActivityAttributes {
    public typealias ContentState = PulseActivityState
}

public extension PulseActivityContent {
    /// The ActivityKit form of this content.
    var activityContent: ActivityContent<PulseActivityState> {
        ActivityContent(state: state, staleDate: staleDate, relevanceScore: relevanceScore)
    }
}
#endif

// MARK: - Display formatting
//
// Formatting lives with the payload, not with the views, so the lock screen,
// the island, the watch card and the app all print the same string for the same
// value. Everything here is locale-independent by design: prices use the
// instrument's own grouping, the time is rendered in the market's own zone.

public enum PulseActivityFormat {
    /// Currencies whose smallest unit is the whole unit: no decimals, ever.
    /// This is a property of the *instrument's* quoting convention, not of the
    /// market it happens to trade in. A KOSPI stock is quoted in whole KRW and
    /// stays whole; an index is not a price at all (see ``PulseQuoteUnit``), so
    /// "the market is Korea" must never be what rounds it.
    private static let wholeUnitCurrencies: Set<String> = ["JPY", "KRW"]

    /// Price with the precision the instrument needs.
    ///
    /// * ``PulseQuoteUnit/points`` — index level: **always** two decimals, and
    ///   the whole-unit rule below does not apply. An index is a level, not a
    ///   money amount, so a KOSPI index of 3 245.67 must not be truncated just
    ///   because its market quotes stocks in whole won.
    /// * `JPY` / `KRW` — whole-unit currencies: no decimals.
    /// * everything else — two decimals, except sub-unit quotes (a crypto pair
    ///   at 0.6182), where two would round the value into a different number
    ///   than the source published.
    ///
    /// The magnitude test uses the absolute value so a *negative* change is not
    /// mistaken for a sub-unit quote and padded to `-12.4000`.
    public static func price(_ value: Double, currencyCode: String, unit: PulseQuoteUnit = .currency) -> String {
        let fractionDigits: Int
        if unit == .points {
            fractionDigits = 2
        } else if wholeUnitCurrencies.contains(currencyCode) {
            fractionDigits = 0
        } else {
            fractionDigits = abs(value) < 1 && value != 0 ? 4 : 2
        }
        return number(value, fractionDigits: fractionDigits)
    }

    /// The unit printed beside a number: `点` for an index, the currency code
    /// otherwise. Empty for an unknown/blank code so a surface shows the number
    /// alone rather than a bare space.
    public static func unitLabel(currencyCode: String, unit: PulseQuoteUnit = .currency) -> String {
        unit.label(currencyCode: currencyCode)
    }

    /// A price with its unit attached, e.g. `3,245.67 点` / `68,500 JPY`.
    public static func priceWithUnit(_ value: Double, currencyCode: String, unit: PulseQuoteUnit = .currency) -> String {
        let label = unitLabel(currencyCode: currencyCode, unit: unit)
        let formatted = price(value, currencyCode: currencyCode, unit: unit)
        return label.isEmpty ? formatted : "\(formatted) \(label)"
    }

    /// Signed absolute change, e.g. `+1.20` / `-0.35`.
    public static func change(_ value: Double, currencyCode: String, unit: PulseQuoteUnit = .currency) -> String {
        let sign = value > 0 ? "+" : ""
        return sign + price(value, currencyCode: currencyCode, unit: unit)
    }

    /// Signed percent, e.g. `+1.83%`. Returns `—` when the source had no
    /// previous close to compute it from — never `+0.00%`.
    public static func changePercent(_ value: Double?) -> String {
        guard let value else { return "—" }
        let sign = value > 0 ? "+" : ""
        return sign + number(value, fractionDigits: 2) + "%"
    }

    /// Clock time of the *source* quote, in the market's zone, e.g. `14:32`.
    public static func sourceTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `14:32:05` — used where a minute is not precise enough to be honest.
    public static func sourceTimeWithSeconds(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Which time zone a market key belongs to, without importing the app's
    /// market model. The suffix of the identity text is the source of truth.
    public static func timeZone(forMarketKey symbolKey: String) -> TimeZone {
        if symbolKey.hasSuffix(".SH") || symbolKey.hasSuffix(".SZ") { return TimeZone(identifier: "Asia/Shanghai")! }
        if symbolKey.hasSuffix(".HK") { return TimeZone(identifier: "Asia/Hong_Kong")! }
        if symbolKey.hasSuffix(".T") { return TimeZone(identifier: "Asia/Tokyo")! }
        if symbolKey.hasSuffix(".KS") || symbolKey.hasSuffix(".KQ") { return TimeZone(identifier: "Asia/Seoul")! }
        if symbolKey.contains("/") { return TimeZone(identifier: "UTC")! }
        return TimeZone(identifier: "America/New_York")!
    }

    /// How long ago the source stamped the quote, in Chinese, plus a marker when
    /// the source itself is delayed. Returns `源时间未知` rather than a guess.
    public static func freshness(quoteSourceTime: Date, sourceDelay: TimeInterval?, asOf now: Date) -> String {
        let age = now.timeIntervalSince(quoteSourceTime)
        let delayed = (sourceDelay ?? 0) >= 60
        let base: String
        if age < 0 {
            // A source clock ahead of ours is reported, not rounded away.
            base = "源时间超前"
        } else if age < 60 {
            base = "刚刚"
        } else if age < 3600 {
            base = "\(Int(age / 60)) 分钟前"
        } else if age < 86_400 {
            base = "\(Int(age / 3600)) 小时前"
        } else {
            base = "\(Int(age / 86_400)) 天前"
        }
        return delayed ? base + " · 源延迟" : base
    }

    /// Identity text shortened for the tightest surfaces (watch small card,
    /// island compact). Truncation only — never a different identity.
    public static func compactIdentity(_ identityText: String, limit: Int = 10) -> String {
        guard identityText.count > limit else { return identityText }
        return String(identityText.prefix(limit - 1)) + "…"
    }

    private static func number(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

// MARK: - Session identity

/// Builds the stable session identifier a pause is scoped to.
///
/// A "today pause" must mean "this market's session that is running now", not
/// "this calendar date": a user pausing the US session at 22:00 Beijing time
/// should not accidentally pause the Shanghai session that opens the next
/// morning, and vice versa.
public enum PulseActivitySession {
    /// - Parameters:
    ///   - marketKey: short market key (`us`, `hk`, `sh`, `crypto`…).
    ///   - phase: the phase in progress.
    ///   - now: current instant.
    ///   - timeZone: the market's own zone, which is what makes the day correct.
    public static func identifier(
        marketKey: String,
        phase: PulseMarketPhase,
        now: Date,
        timeZone: TimeZone
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let day = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0
        )
        return "\(marketKey).\(day).\(phase.rawValue)"
    }
}
