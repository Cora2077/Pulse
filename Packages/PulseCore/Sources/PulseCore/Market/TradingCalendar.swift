import Foundation

public enum SessionState: String, Sendable {
    case closed, preMarket, regular, lunchBreak, postMarket
    /// US overnight session (Sun 20:00 ET through Fri 04:00 ET, in nightly slices)
    case overnight
}

/// Trading sessions per market (in each exchange's time zone).
/// Sessions still follow the clock; which days have one at all comes from
/// `ExchangeCalendar`, whose verified tables cover a bounded set of years. A
/// year beyond them falls back to the weekday-only rule this type has always
/// used, deliberately rather than by omission — see `ExchangeCalendar`.
public enum TradingCalendar {
    public static func state(of market: Market, at date: Date = .now) -> SessionState {
        if market == .crypto { return .regular }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute else {
            return .closed
        }
        let m = hour * 60 + minute

        // Read exchange-local dates for holiday lookups. Overnight branches
        // below check the date of the session they belong to.
        let compsDay = calendar.dateComponents([.year, .month, .day], from: date)
        let exchangeDay = CalendarDay(
            year: compsDay.year ?? 0,
            month: compsDay.month ?? 0,
            day: compsDay.day ?? 0
        )

        // Metals run almost continuously: Sun 18:00 ET through Fri 17:00 ET, pausing
        // one hour a day for settlement. Like the US overnight session, that reaches
        // outside the Monday–Friday rule below.
        if market == .metal {
            if weekday == 1 { return m >= 18 * 60 ? .regular : .closed }  // Sunday evening opens the week
            guard (2...6).contains(weekday) else { return .closed }       // Saturday has no session
            if m < 17 * 60 { return .regular }
            if weekday == 6 { return .closed }                            // Friday 17:00 closes the week
            return m >= 18 * 60 ? .regular : .closed                      // 17:00–18:00 settlement break
        }

        // Shanghai metals trade a night leg ahead of the day session, so like the
        // US overnight it reaches outside the Monday–Friday rule below. The two
        // exchanges differ slightly — the Gold Exchange opens at 20:00 and settles
        // at 15:30, the Futures Exchange at 21:00 and 15:00 — so the window is
        // their union: an instrument simply has no bars in the part it misses.
        if market == .metalCN {
            if m >= 20 * 60 {
                // A night leg is the *next* day's session, so it exists only when
                // the current day and the one it runs into are both ordinary.
                // Friday into Saturday keeps its leg; a night that would run into
                // a holiday does not, and nothing hops past the holiday to the
                // next weekday.
                guard (2...6).contains(weekday),
                      !ExchangeCalendar.isHoliday(.metalCN, on: exchangeDay),
                      !ExchangeCalendar.isMetalCNNightCancelled(on: exchangeDay),
                      !ExchangeCalendar.isHoliday(.metalCN, on: ExchangeCalendar.nextDay(exchangeDay))
                else { return .closed }
                return .regular
            }
            // The small hours belong to the previous evening's session: Saturday
            // has one because Friday night ran into it, Monday does not — and a
            // holiday cancels it from the evening before it, so the midnight from
            // a holiday eve into the holiday morning stays shut.
            if m < 2 * 60 + 30 {
                guard (3...7).contains(weekday),
                      !ExchangeCalendar.isHoliday(.metalCN, on: exchangeDay),
                      !ExchangeCalendar.isMetalCNNightCancelled(on: ExchangeCalendar.previousDay(exchangeDay)),
                      !ExchangeCalendar.isHoliday(.metalCN, on: ExchangeCalendar.previousDay(exchangeDay))
                else { return .closed }
                return .regular
            }
            guard (2...6).contains(weekday) else { return .closed }
            guard ExchangeCalendar.isTradingDay(.metalCN, on: exchangeDay) else { return .closed }
            if (9 * 60)..<(11 * 60 + 30) ~= m { return .regular }
            if (11 * 60 + 30)..<(13 * 60 + 30) ~= m { return .lunchBreak }
            if (13 * 60 + 30)..<(15 * 60 + 30) ~= m { return .regular }
            return .closed
        }

        // The US overnight session runs Sun 20:00 ET through Fri 04:00 ET, so it is the one
        // stretch that exists outside the Monday–Friday rule below. It is quoted for the
        // *next* session, which is what its holidays have to be checked against.
        if market == .us {
            // Sunday evening 20:00 opens Monday's session, and only if Monday trades.
            if weekday == 1 {
                guard m >= 20 * 60 else { return .closed }
                return ExchangeCalendar.isTradingDay(.us, on: ExchangeCalendar.nextDay(exchangeDay))
                    ? .overnight : .closed
            }
            if (2...6).contains(weekday), m < 4 * 60 {
                // 00:00–04:00 already carries its own session's date, so a holiday
                // morning stays shut; there is no earlier weekday to fall back to.
                return ExchangeCalendar.isTradingDay(.us, on: exchangeDay) ? .overnight : .closed
            }
            if (2...5).contains(weekday), m >= 20 * 60 {
                // Monday–Thursday evenings all trade toward the following calendar
                // day, holiday or not. A holiday Monday evening therefore reopens
                // for an ordinary Tuesday.
                return ExchangeCalendar.isTradingDay(.us, on: ExchangeCalendar.nextDay(exchangeDay))
                    ? .overnight : .closed
            }
        }
        guard (2...6).contains(weekday) else { return .closed }
        // Equities and Tokyo keep their clock sessions only on a trading day;
        // weekends and verified holidays report `.closed`, lunch break included.
        // Metals (`metal`) stay above this: they run their own continuous week.
        guard ExchangeCalendar.isTradingDay(market, on: exchangeDay) else { return .closed }

        switch market {
        case .sh, .sz:
            if (9 * 60 + 15)..<(11 * 60 + 30) ~= m { return .regular }  // Includes the opening call auction
            if (11 * 60 + 30)..<(13 * 60) ~= m { return .lunchBreak }
            if (13 * 60)..<(15 * 60) ~= m { return .regular }
            return .closed
        case .hk:
            // A half day ends the whole session at 12:10 HKT: no lunch break and
            // no afternoon, so every minute from 12:10 is shut. An ordinary day
            // keeps the lunch break and the 16:10 close, closing auction included.
            if let early = ExchangeCalendar.earlyCloseMinutes(.hk, on: exchangeDay) {
                if (9 * 60 + 30)..<early.regular ~= m { return .regular }
                return .closed
            }
            if (9 * 60 + 30)..<(12 * 60) ~= m { return .regular }
            if (12 * 60)..<(13 * 60) ~= m { return .lunchBreak }
            if (13 * 60)..<(16 * 60 + 10) ~= m { return .regular }  // Includes the closing auction
            return .closed
        case .us:
            // A half day moves both edges of the afternoon: the regular session
            // ends at 13:00 ET and after-hours trading runs to 17:00 ET instead
            // of 20:00. Pre-market is unchanged, so a trading date with no
            // verified early close keeps exactly the hours it always had.
            let early = ExchangeCalendar.earlyCloseMinutes(.us, on: exchangeDay)
            let regularClose = early?.regular ?? 16 * 60
            let postClose = early?.extended ?? 20 * 60
            if (4 * 60)..<(9 * 60 + 30) ~= m { return .preMarket }
            if (9 * 60 + 30)..<regularClose ~= m { return .regular }
            if regularClose..<postClose ~= m { return .postMarket }
            return .closed
        case .jp:
            // Tokyo moved its close from 15:00 to 15:30 in November 2024; the
            // 11:30–12:30 lunch break has not changed.
            if (9 * 60)..<(11 * 60 + 30) ~= m { return .regular }
            if (11 * 60 + 30)..<(12 * 60 + 30) ~= m { return .lunchBreak }
            if (12 * 60 + 30)..<(15 * 60 + 30) ~= m { return .regular }
            return .closed
        case .kr, .kq:
            // Seoul runs one continuous session, closing auction included. Its
            // call auctions on either side are not modeled: no wired source
            // publishes them, so claiming the state would outrun the data.
            if (9 * 60)..<(15 * 60 + 30) ~= m { return .regular }
            return .closed
        case .crypto, .metal:
            return .regular
        case .metalCN:
            return .closed  // Handled above; every SHFE branch returns already.
        }
    }

    /// Whether this market is currently worth refreshing at high frequency.
    /// Overnight counts as inactive here: most sources have nothing new then, and the ones
    /// that do (Longbridge) declare it via `ProviderDescriptor.overnightMarkets`.
    public static func isActive(_ market: Market, at date: Date = .now) -> Bool {
        switch state(of: market, at: date) {
        case .regular, .preMarket, .postMarket: true
        case .closed, .lunchBreak, .overnight: false
        }
    }

    public static func anyActive(_ markets: some Sequence<Market>, at date: Date = .now) -> Bool {
        markets.contains { isActive($0, at: date) }
    }

    /// The trading day a moment belongs to, read in the market's own time zone.
    /// The US overnight session runs from 20:00 ET into the small hours, so it
    /// belongs to the session that follows it rather than the date it starts on.
    /// Metals keep their exchange calendar day: that is how both of their sources
    /// report them, whatever hour of the continuous session a bar falls in.
    public static func tradingDay(of market: Market, at date: Date) -> CalendarDay {
        let day = CalendarDay(date, in: market.timeZone)
        guard market == .us, state(of: market, at: date) == .overnight else { return day }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let hour = calendar.component(.hour, from: date)
        // The 00:00–04:00 slice already carries the session's own date.
        guard hour >= 20, let next = calendar.date(byAdding: .day, value: 1, to: date) else { return day }
        return CalendarDay(next, in: market.timeZone)
    }
}

/// A calendar day identity: which day something happened on, not when. Days
/// read in different time zones (a trade date entered locally, a session date
/// read in the exchange's zone) compare directly instead of being turned back
/// into instants that would answer a different question.
public struct CalendarDay: Comparable, Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0
        )
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
