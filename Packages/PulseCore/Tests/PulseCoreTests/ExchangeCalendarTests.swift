import Foundation
import Testing
@testable import PulseCore

/// Bounded exchange-calendar coverage. Every table here is hand-transcribed from
/// an exchange notice, so these tests pin the exact dates and, just as
/// importantly, the ordinary days beside them.
///
/// Instants are built from `DateComponents` in the market's own zone — or, where
/// the point of the test is the zone itself, from explicit UTC components — so
/// nothing depends on where the device thinks it is.
@Suite("Exchange calendar")
struct ExchangeCalendarTests {
    // MARK: - Helpers

    private func instant(
        _ market: Market,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        return try #require(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }

    private func calendarDay(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    /// A `Date` built from explicit UTC components, so an absolute instant can be
    /// stated without going through any exchange calendar.
    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0
    ) throws -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        return try #require(utc.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }

    private func state(_ market: Market, _ year: Int, _ month: Int, _ day: Int,
                       _ hour: Int, _ minute: Int = 0) throws -> SessionState {
        TradingCalendar.state(of: market, at: try instant(market, year, month, day, hour, minute))
    }

    // MARK: - Mainland China, 2026

    @Test("Mainland 2026 closures cover each listed range")
    func chinaClosures() {
        for (month, dateDay) in [
            (1, 1), (1, 3), (2, 15), (2, 23), (4, 4), (4, 6), (5, 1), (5, 5),
            (6, 19), (6, 21), (9, 25), (9, 27), (10, 1), (10, 7),
        ] {
            #expect(ExchangeCalendar.isHoliday(.sh, on: calendarDay(2026, month, dateDay)))
            #expect(ExchangeCalendar.isHoliday(.sz, on: calendarDay(2026, month, dateDay)))
            #expect(ExchangeCalendar.isHoliday(.metalCN, on: calendarDay(2026, month, dateDay)))
            #expect(!ExchangeCalendar.isTradingDay(.sh, on: calendarDay(2026, month, dateDay)))
        }
        // The days on either side of Spring Festival are ordinary.
        #expect(ExchangeCalendar.isTradingDay(.sh, on: calendarDay(2026, 2, 13)))
        #expect(ExchangeCalendar.isTradingDay(.sh, on: calendarDay(2026, 2, 24)))
        #expect(ExchangeCalendar.isTradingDay(.sz, on: calendarDay(2026, 10, 8)))
        #expect(!ExchangeCalendar.isHoliday(.sh, on: calendarDay(2026, 8, 19)))
    }

    @Test("A mainland holiday closes the whole clock session, lunch included")
    func chinaHolidaySession() throws {
        #expect(try state(.sh, 2026, 10, 1, 9, 15) == .closed)
        #expect(try state(.sh, 2026, 10, 1, 10, 0) == .closed)
        #expect(try state(.sh, 2026, 10, 1, 11, 45) == .closed)
        #expect(try state(.sh, 2026, 10, 1, 13, 30) == .closed)
        #expect(try state(.sz, 2026, 2, 17, 10, 0) == .closed)
        // The ordinary neighbours keep their sessions.
        #expect(try state(.sh, 2026, 2, 24, 10, 0) == .regular)
        #expect(try state(.sh, 2026, 2, 24, 11, 45) == .lunchBreak)
    }

    /// The SSE notice designates make-up workdays, but the exchanges do not open
    /// on them: a Saturday stays shut however the civil calendar labels it.
    @Test("Make-up work Saturdays stay closed")
    func civilMakeUpSaturdays() {
        // 2026-02-28 (Spring Festival) and 2026-10-10 (National Day) are 调休
        // working days that are still weekends at the exchange.
        #expect(ExchangeCalendar.weekday(calendarDay(2026, 2, 28)) == 7)
        #expect(ExchangeCalendar.weekday(calendarDay(2026, 10, 10)) == 7)
        #expect(!ExchangeCalendar.isTradingDay(.sh, on: calendarDay(2026, 2, 28)))
        #expect(!ExchangeCalendar.isTradingDay(.sz, on: calendarDay(2026, 10, 10)))
        #expect(!ExchangeCalendar.isTradingDay(.sh, on: calendarDay(2026, 2, 22)))   // Sunday inside the range
        #expect(ExchangeCalendar.isHoliday(.sh, on: calendarDay(2026, 2, 22)))        // and it is listed too
    }

    /// Weekday and day-stepping come from a UTC-pinned Gregorian calendar, so
    /// these answers hold wherever the device thinks it is. The century cases
    /// matter: 1900 is not a leap year and 2000 is.
    @Test("Weekdays and weekends fall out of the calendar itself")
    func weekdayArithmetic() {
        #expect(ExchangeCalendar.weekday(calendarDay(2026, 1, 1)) == 5)   // Thursday
        #expect(ExchangeCalendar.weekday(calendarDay(2027, 1, 1)) == 6)   // Friday
        #expect(ExchangeCalendar.weekday(calendarDay(2028, 1, 1)) == 7)   // Saturday
        #expect(ExchangeCalendar.weekday(calendarDay(2000, 2, 29)) == 3)  // leap Tuesday
        #expect(ExchangeCalendar.weekday(calendarDay(2028, 2, 29)) == 3)  // leap Tuesday
        #expect(ExchangeCalendar.weekday(calendarDay(1900, 3, 1)) == 5)   // 1900 was not a leap year
        #expect(ExchangeCalendar.weekday(calendarDay(2000, 3, 1)) == 4)   // 2000 was
        #expect(ExchangeCalendar.isWeekend(calendarDay(2026, 8, 22)))     // Saturday
        #expect(ExchangeCalendar.isWeekend(calendarDay(2026, 8, 23)))     // Sunday
        #expect(!ExchangeCalendar.isWeekend(calendarDay(2026, 8, 21)))    // Friday
        // A year rolls over both ways, and February 29 exists only in 2028.
        #expect(ExchangeCalendar.nextDay(calendarDay(2026, 12, 31)) == calendarDay(2027, 1, 1))
        #expect(ExchangeCalendar.nextDay(calendarDay(2028, 2, 28)) == calendarDay(2028, 2, 29))
        #expect(ExchangeCalendar.nextDay(calendarDay(2028, 2, 29)) == calendarDay(2028, 3, 1))
        #expect(ExchangeCalendar.nextDay(calendarDay(2027, 2, 28)) == calendarDay(2027, 3, 1))
        #expect(ExchangeCalendar.previousDay(calendarDay(2026, 1, 1)) == calendarDay(2025, 12, 31))
        #expect(ExchangeCalendar.previousDay(calendarDay(2028, 3, 1)) == calendarDay(2028, 2, 29))
        #expect(ExchangeCalendar.previousDay(calendarDay(2027, 3, 1)) == calendarDay(2027, 2, 28))
        #expect(ExchangeCalendar.previousDay(calendarDay(2026, 3, 1)) == calendarDay(2026, 2, 28))
        #expect(ExchangeCalendar.previousDay(calendarDay(2026, 8, 22)) == calendarDay(2026, 8, 21))
        // A weekend day steps to the next week either way.
        #expect(ExchangeCalendar.nextDay(calendarDay(2026, 8, 21)) == calendarDay(2026, 8, 22))
        #expect(ExchangeCalendar.nextDay(calendarDay(2026, 8, 23)) == calendarDay(2026, 8, 24))
    }

    // MARK: - Shanghai metals

    /// A listed holiday shuts the day session and its surrounding night legs.
    @Test("A mainland holiday shuts Shanghai metals, night legs included")
    func metalCNHoliday() throws {
        // Thursday 2026-10-01, National Day: day session and the night that
        // would open the 2nd are both shut.
        #expect(try state(.metalCN, 2026, 10, 1, 10, 0) == .closed)
        #expect(try state(.metalCN, 2026, 10, 1, 15, 0) == .closed)
        #expect(try state(.metalCN, 2026, 10, 1, 21, 0) == .closed)
        // Eve: Friday 2026-09-25 is mid-Autumn, so Thursday's night leg is gone
        // and the midnight into the holiday morning stays shut.
        #expect(try state(.metalCN, 2026, 9, 24, 20, 0) == .closed)
        #expect(try state(.metalCN, 2026, 9, 24, 21, 0) == .closed)
        #expect(try state(.metalCN, 2026, 9, 25, 1, 0) == .closed)
        #expect(try state(.metalCN, 2026, 9, 25, 2, 29) == .closed)
        #expect(try state(.metalCN, 2026, 9, 25, 10, 0) == .closed)
        // Friday's night does not run into the holiday weekend either.
        #expect(try state(.metalCN, 2026, 9, 25, 21, 0) == .closed)
        #expect(try state(.metalCN, 2026, 9, 26, 1, 0) == .closed)
        // Resume on Monday the 28th, whose own night leg opens that evening.
        #expect(try state(.metalCN, 2026, 9, 28, 1, 0) == .closed)   // Sunday small hours
        #expect(try state(.metalCN, 2026, 9, 28, 9, 0) == .regular)
        #expect(try state(.metalCN, 2026, 9, 28, 21, 0) == .regular)
        #expect(try state(.metalCN, 2026, 9, 29, 1, 0) == .regular)
    }

    /// An ordinary Friday's night leg still runs into an ordinary Saturday, and
    /// nothing hops across a holiday to find a later weekday.
    @Test("Ordinary Friday nights keep their Saturday small hours")
    func metalCNOrdinaryWeek() throws {
        #expect(try state(.metalCN, 2026, 8, 21, 21, 0) == .regular)  // Fri night
        #expect(try state(.metalCN, 2026, 8, 22, 1, 0) == .regular)   // Sat, from Fri night
        #expect(try state(.metalCN, 2026, 8, 22, 10, 0) == .closed)
        #expect(try state(.metalCN, 2026, 8, 23, 21, 0) == .closed)   // Sun night
        #expect(try state(.metalCN, 2026, 8, 24, 1, 0) == .closed)    // Mon small hours
        #expect(try state(.metalCN, 2026, 8, 24, 9, 0) == .regular)
        #expect(try state(.metalCN, 2026, 8, 24, 11, 45) == .lunchBreak)
    }

    @Test("The last Friday before Spring Festival has no Shanghai night session")
    func metalCNPreHolidayFriday() throws {
        // SHFE/SGE explicitly cancel Feb 13 evening despite Feb 14 being outside
        // the holiday range. Feb 13 daytime remains an ordinary trading session.
        #expect(try state(.metalCN, 2026, 2, 13, 10, 0) == .regular)
        #expect(try state(.metalCN, 2026, 2, 13, 20, 0) == .closed)
        #expect(try state(.metalCN, 2026, 2, 13, 21, 0) == .closed)
        #expect(try state(.metalCN, 2026, 2, 14, 0, 0) == .closed)
        #expect(try state(.metalCN, 2026, 2, 14, 2, 29) == .closed)
        // The previous ordinary Friday retains its night and Saturday small hours.
        #expect(try state(.metalCN, 2026, 2, 6, 20, 0) == .regular)
        #expect(try state(.metalCN, 2026, 2, 7, 1, 0) == .regular)
    }

    // MARK: - United States

    @Test("NYSE 2026 holidays and their ordinary neighbours")
    func usHolidays2026() {
        for (month, dateDay) in [
            (1, 1), (1, 19), (2, 16), (4, 3), (5, 25),
            (6, 19), (7, 3), (9, 7), (11, 26), (12, 25),
        ] {
            #expect(ExchangeCalendar.isHoliday(.us, on: calendarDay(2026, month, dateDay)))
            #expect(!ExchangeCalendar.isTradingDay(.us, on: calendarDay(2026, month, dateDay)))
        }
        #expect(ExchangeCalendar.isTradingDay(.us, on: calendarDay(2026, 7, 2)))
        #expect(ExchangeCalendar.isTradingDay(.us, on: calendarDay(2026, 7, 6)))
        #expect(ExchangeCalendar.isTradingDay(.us, on: calendarDay(2026, 12, 28)))
    }

    @Test("NYSE 2027 holidays, Christmas Eve included")
    func usHolidays2027() {
        for (month, dateDay) in [
            (1, 1), (1, 18), (2, 15), (3, 26), (5, 31),
            (6, 18), (7, 5), (9, 6), (11, 25), (12, 24),
        ] {
            #expect(ExchangeCalendar.isHoliday(.us, on: calendarDay(2027, month, dateDay)))
        }
        #expect(ExchangeCalendar.isTradingDay(.us, on: calendarDay(2027, 12, 23)))
        #expect(ExchangeCalendar.isTradingDay(.us, on: calendarDay(2027, 12, 27)))
        #expect(ExchangeCalendar.earlyCloseMinutes(.us, on: calendarDay(2027, 11, 26))?.regular == 13 * 60)
    }

    @Test("NYSE 2028 holidays")
    func usHolidays2028() {
        for (month, dateDay) in [
            (1, 17), (2, 21), (4, 14), (5, 29), (6, 19),
            (7, 4), (9, 4), (11, 23), (12, 25),
        ] {
            #expect(ExchangeCalendar.isHoliday(.us, on: calendarDay(2028, month, dateDay)))
        }
        #expect(ExchangeCalendar.earlyCloseMinutes(.us, on: calendarDay(2028, 7, 3))?.regular == 13 * 60)
        #expect(ExchangeCalendar.earlyCloseMinutes(.us, on: calendarDay(2028, 11, 24))?.extended == 17 * 60)
    }

    /// 2026-07-04 is a Saturday, so the NYSE observed Independence Day on the
    /// Friday. Nothing here derives that — the 3rd is simply listed — which is
    /// the point: a rule-based calendar gets this class of date wrong quietly.
    @Test("Saturday July 4 2026 is observed on Friday July 3")
    func independenceDayObserved() throws {
        #expect(ExchangeCalendar.weekday(calendarDay(2026, 7, 4)) == 7)
        #expect(ExchangeCalendar.isHoliday(.us, on: calendarDay(2026, 7, 3)))
        #expect(try state(.us, 2026, 7, 3, 10, 0) == .closed)
        #expect(try state(.us, 2026, 7, 3, 17, 0) == .closed)
    }

    /// No general federal observance rule: Saturday 2028-01-01 is not pulled back
    /// onto Friday 2027-12-31, which the NYSE trades normally.
    @Test("Friday December 31 2027 is open despite Saturday New Year's Day")
    func newYearNotObservedEarly() throws {
        #expect(ExchangeCalendar.weekday(calendarDay(2028, 1, 1)) == 7)
        #expect(!ExchangeCalendar.isHoliday(.us, on: calendarDay(2027, 12, 31)))
        #expect(ExchangeCalendar.isTradingDay(.us, on: calendarDay(2027, 12, 31)))
        #expect(ExchangeCalendar.earlyCloseMinutes(.us, on: calendarDay(2027, 12, 31)) == nil)
        #expect(try state(.us, 2027, 12, 31, 9, 30) == .regular)
        #expect(try state(.us, 2027, 12, 31, 15, 59) == .regular)
        #expect(try state(.us, 2027, 12, 31, 17, 0) == .postMarket)
    }

    /// 2026-11-27: regular trading ends at 13:00 ET, after-hours at 17:00 ET.
    @Test("A US half day shortens regular and after-hours trading")
    func usHalfDay() throws {
        let early = try #require(ExchangeCalendar.earlyCloseMinutes(.us, on: calendarDay(2026, 11, 27)))
        #expect(early.regular == 13 * 60)
        #expect(early.extended == 17 * 60)

        #expect(try state(.us, 2026, 11, 27, 9, 30) == .regular)
        #expect(try state(.us, 2026, 11, 27, 12, 59) == .regular)
        #expect(try state(.us, 2026, 11, 27, 13, 0) == .postMarket)
        #expect(try state(.us, 2026, 11, 27, 16, 59) == .postMarket)
        #expect(try state(.us, 2026, 11, 27, 17, 0) == .closed)
        #expect(try state(.us, 2026, 11, 27, 19, 0) == .closed)
        // Pre-market is untouched by the early close.
        #expect(try state(.us, 2026, 11, 27, 4, 0) == .preMarket)

        // An ordinary Friday keeps 16:00/20:00, and no early-close table entry.
        #expect(ExchangeCalendar.earlyCloseMinutes(.us, on: calendarDay(2026, 11, 20)) == nil)
        #expect(try state(.us, 2026, 11, 20, 16, 0) == .postMarket)
        #expect(try state(.us, 2026, 11, 20, 19, 59) == .postMarket)
        #expect(try state(.us, 2026, 11, 20, 20, 0) == .closed)
    }

    /// The classification uses the *exchange's* calendar day, not the UTC day the
    /// instant also falls on. Both cases below are stated as absolute UTC
    /// instants with their exchange-local date and expected session pinned, so a
    /// regression that read the wrong zone would fail rather than agree.
    @Test("An instant is classified by its exchange day, not the device day")
    func timeZoneInstantMapping() throws {
        // 2026-10-01 01:30 UTC is 2026-09-30 21:30 in New York. The exchange day
        // is the 30th — an ordinary Wednesday — and 21:30 is the overnight leg
        // that belongs to Thursday the 1st, which trades normally.
        let usOvernight = try utcDate(2026, 10, 1, 1, 30)
        #expect(CalendarDay(usOvernight, in: Market.us.timeZone) == calendarDay(2026, 9, 30))
        #expect(CalendarDay(usOvernight, in: try #require(TimeZone(identifier: "UTC")))
            == calendarDay(2026, 10, 1))
        #expect(ExchangeCalendar.weekday(calendarDay(2026, 9, 30)) == 4)   // Wednesday
        #expect(ExchangeCalendar.isTradingDay(.us, on: calendarDay(2026, 10, 1)))
        #expect(TradingCalendar.state(of: .us, at: usOvernight) == .overnight)

        // 2026-09-30 17:00 UTC is already 2026-10-01 01:00 on the mainland, and
        // the 1st is a listed National Day holiday: the session is shut even
        // though the UTC date says September.
        let chinaHoliday = try utcDate(2026, 9, 30, 17, 0)
        #expect(CalendarDay(chinaHoliday, in: Market.sh.timeZone) == calendarDay(2026, 10, 1))
        #expect(CalendarDay(chinaHoliday, in: try #require(TimeZone(identifier: "UTC")))
            == calendarDay(2026, 9, 30))
        #expect(ExchangeCalendar.isHoliday(.sh, on: calendarDay(2026, 10, 1)))
        #expect(TradingCalendar.state(of: .sh, at: chinaHoliday) == .closed)
        // A UTC-date reading would have called it an ordinary Wednesday session.
        #expect(ExchangeCalendar.weekday(calendarDay(2026, 9, 30)) == 4)
        #expect(ExchangeCalendar.isTradingDay(.sh, on: calendarDay(2026, 9, 30)))
    }

    // MARK: - US overnight

    /// The overnight session is quoted for the day it runs into, so its holidays
    /// are the *next* day's and nothing hops forward to a later weekday.
    @Test("The overnight target day decides")
    func overnightTargetDay() throws {
        // Monday 2026-01-19 is MLK Day: the Sunday evening before it is shut,
        // and so are the holiday's own small hours.
        #expect(ExchangeCalendar.weekday(calendarDay(2026, 1, 18)) == 1)
        #expect(try state(.us, 2026, 1, 18, 19, 59) == .closed)
        #expect(try state(.us, 2026, 1, 18, 20, 0) == .closed)
        #expect(try state(.us, 2026, 1, 19, 1, 0) == .closed)
        #expect(try state(.us, 2026, 1, 19, 3, 59) == .closed)
        // The holiday evening reopens for an ordinary Tuesday.
        #expect(try state(.us, 2026, 1, 19, 20, 0) == .overnight)
        #expect(try state(.us, 2026, 1, 20, 1, 0) == .overnight)
        #expect(try state(.us, 2026, 1, 20, 9, 30) == .regular)

        // Sunday 2026-01-18's evening was shut for the holiday; an ordinary
        // Sunday opens for its Monday, and an ordinary Thursday night runs into
        // an ordinary Friday.
        #expect(try state(.us, 2026, 1, 11, 20, 0) == .overnight)   // Sun → Mon 12th
        #expect(try state(.us, 2026, 1, 15, 20, 0) == .overnight)   // Thu → Fri 16th
        // Thursday 2026-11-26 is Thanksgiving, but an overnight leg is judged by
        // the day it runs *into*: Friday the 27th is a trading day (an early
        // close), so the holiday evening reopens and carries on through the
        // small hours of the 27th.
        #expect(try state(.us, 2026, 11, 26, 20, 0) == .overnight)
        #expect(try state(.us, 2026, 11, 27, 1, 0) == .overnight)
        // The following Sunday evening opens for an ordinary Monday.
        #expect(try state(.us, 2026, 11, 29, 20, 0) == .overnight)
        // Friday night has no overnight leg at all, holiday or not.
        #expect(try state(.us, 2026, 1, 16, 20, 0) == .closed)
        #expect(try state(.us, 2026, 1, 17, 1, 0) == .closed)
    }

    /// `tradingDay` keeps the attribution it always had for a session that is
    /// really open, and falls back to the plain calendar day otherwise.
    @Test("Overnight trading-day attribution is unchanged")
    func overnightTradingDayAttribution() throws {
        // Thursday 20:00 ET belongs to Friday's session.
        #expect(TradingCalendar.tradingDay(of: .us, at: try instant(.us, 2026, 1, 15, 20, 0))
            == calendarDay(2026, 1, 16))
        // The small hours already carry their own date.
        #expect(TradingCalendar.tradingDay(of: .us, at: try instant(.us, 2026, 1, 16, 1, 0))
            == calendarDay(2026, 1, 16))
        // The Sunday evening before MLK Day is closed, so nothing is attributed
        // to the holiday.
        #expect(TradingCalendar.tradingDay(of: .us, at: try instant(.us, 2026, 1, 18, 20, 0))
            == calendarDay(2026, 1, 18))
        // The holiday evening reopens and does attribute to Tuesday.
        #expect(TradingCalendar.tradingDay(of: .us, at: try instant(.us, 2026, 1, 19, 20, 0))
            == calendarDay(2026, 1, 20))
    }

    /// A half day shortens its own clock sessions but leaves the overnight legs
    /// around it to their target days: the leg into the half day trades, the leg
    /// into the full holiday before it does not.
    @Test("A half day does not disturb the overnight legs around it")
    func halfDayOvernight() throws {
        // Wednesday 2026-11-25 evening runs into Thanksgiving — a full holiday,
        // so the leg is shut however ordinary the Wednesday itself was.
        #expect(try state(.us, 2026, 11, 25, 20, 0) == .closed)
        // Thursday's evening runs into Friday the 27th, which *does* trade: the
        // half day is an early close, not a closure, so the leg opens and its
        // small hours belong to it.
        #expect(try state(.us, 2026, 11, 26, 20, 0) == .overnight)
        #expect(try state(.us, 2026, 11, 27, 1, 0) == .overnight)
        // The half day itself: regular to 13:00, after-hours to 17:00.
        #expect(try state(.us, 2026, 11, 27, 9, 30) == .regular)
        #expect(try state(.us, 2026, 11, 27, 13, 0) == .postMarket)
        #expect(try state(.us, 2026, 11, 27, 17, 0) == .closed)
        // Friday evening has no overnight leg to run, early close or not.
        #expect(try state(.us, 2026, 11, 27, 20, 0) == .closed)
        // Sunday's evening then opens for an ordinary Monday.
        #expect(try state(.us, 2026, 11, 29, 20, 0) == .overnight)
        #expect(try state(.us, 2026, 11, 30, 1, 0) == .overnight)
        #expect(try state(.us, 2026, 11, 30, 16, 0) == .postMarket)   // back to 20:00
    }

    // MARK: - Japan

    @Test("Tokyo 2026 holidays")
    func japanHolidays2026() {
        for (month, dateDay) in [
            (1, 1), (1, 2), (1, 3), (1, 12), (2, 11), (2, 23), (3, 20), (4, 29),
            (5, 3), (5, 4), (5, 5), (5, 6), (7, 20), (8, 11),
            (9, 21), (9, 22), (9, 23), (10, 12), (11, 3), (11, 23), (12, 31),
        ] {
            #expect(ExchangeCalendar.isHoliday(.jp, on: calendarDay(2026, month, dateDay)))
            #expect(!ExchangeCalendar.isTradingDay(.jp, on: calendarDay(2026, month, dateDay)))
        }
        #expect(ExchangeCalendar.isTradingDay(.jp, on: calendarDay(2026, 8, 10)))
        #expect(ExchangeCalendar.isTradingDay(.jp, on: calendarDay(2026, 8, 12)))
        #expect(ExchangeCalendar.isTradingDay(.jp, on: calendarDay(2026, 12, 30)))
    }

    @Test("Tokyo 2027 holidays")
    func japanHolidays2027() {
        for (month, dateDay) in [
            (1, 1), (1, 2), (1, 3), (1, 11), (2, 11), (2, 23), (3, 21), (3, 22),
            (4, 29), (5, 3), (5, 4), (5, 5), (7, 19), (8, 11),
            (9, 20), (9, 23), (10, 11), (11, 3), (11, 23), (12, 31),
        ] {
            #expect(ExchangeCalendar.isHoliday(.jp, on: calendarDay(2027, month, dateDay)))
        }
        // Sep 20 and Sep 23 are the listed holidays; the 21st and 22nd between
        // them are not, and stay ordinary trading days here.
        #expect(ExchangeCalendar.isTradingDay(.jp, on: calendarDay(2027, 9, 21)))
        #expect(ExchangeCalendar.isTradingDay(.jp, on: calendarDay(2027, 9, 22)))
        #expect(ExchangeCalendar.isTradingDay(.jp, on: calendarDay(2027, 3, 23)))
    }

    @Test("A Tokyo holiday has no session at all")
    func japanHolidaySession() throws {
        #expect(try state(.jp, 2026, 8, 11, 9, 0) == .closed)
        #expect(try state(.jp, 2026, 8, 11, 12, 0) == .closed)
        #expect(try state(.jp, 2026, 1, 2, 10, 0) == .closed)
        #expect(try state(.jp, 2026, 12, 31, 10, 0) == .closed)
        // An ordinary Wednesday keeps its lunch break and 15:30 close.
        #expect(try state(.jp, 2026, 8, 12, 10, 0) == .regular)
        #expect(try state(.jp, 2026, 8, 12, 11, 45) == .lunchBreak)
        #expect(try state(.jp, 2026, 8, 12, 15, 29) == .regular)
        #expect(try state(.jp, 2026, 8, 12, 15, 30) == .closed)
    }

    // MARK: - Hong Kong

    /// HKEX circular CT/075/25: every listed closure and ordinary neighbours.
    @Test("HKEX 2026 holidays and their ordinary neighbours")
    func hongKongHolidays2026() {
        for (month, dateDay) in [
            (1, 1), (2, 17), (2, 18), (2, 19), (4, 3), (4, 6), (4, 7), (5, 1),
            (5, 25), (6, 19), (7, 1), (10, 1), (10, 19), (12, 25),
        ] {
            #expect(ExchangeCalendar.isHoliday(.hk, on: calendarDay(2026, month, dateDay)))
            #expect(!ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2026, month, dateDay)))
        }
        // Weekday closures that only the table knows: Ching Ming's and Chung
        // Yeung's observed days and the Easter run.
        #expect(ExchangeCalendar.isHoliday(.hk, on: calendarDay(2026, 4, 6)))
        #expect(ExchangeCalendar.isHoliday(.hk, on: calendarDay(2026, 4, 7)))
        #expect(ExchangeCalendar.isHoliday(.hk, on: calendarDay(2026, 10, 19)))
        #expect(ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2026, 2, 13)))
        #expect(ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2026, 2, 20)))
        #expect(ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2026, 10, 2)))
        // The weekdays after Christmas retain their ordinary sessions.
        #expect(ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2026, 12, 28)))
        #expect(ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2026, 12, 30)))
    }

    /// A Hong Kong half day closes the whole session at 12:10 HKT, closing
    /// auction included, with no lunch break and no afternoon.
    @Test("A Hong Kong half day ends at 12:10 with no afternoon")
    func hongKongHalfDay() throws {
        // Lunar New Year's Eve, Christmas Eve and New Year's Eve 2026.
        for morning in [(2, 16), (12, 24), (12, 31)] {
            let (month, dateDay) = morning
            #expect(ExchangeCalendar.earlyCloseMinutes(.hk, on: calendarDay(2026, month, dateDay))?.regular
                == 12 * 60 + 10)
            #expect(ExchangeCalendar.earlyCloseMinutes(.hk, on: calendarDay(2026, month, dateDay))?.extended
                == 12 * 60 + 10)
            #expect(ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2026, month, dateDay)))
            // The morning is ordinary trading up to the close.
            #expect(try state(.hk, 2026, month, dateDay, 9, 30) == .regular)
            #expect(try state(.hk, 2026, month, dateDay, 11, 45) == .regular)
            #expect(try state(.hk, 2026, month, dateDay, 12, 9) == .regular)
            // 12:10 is shut, and so is everything the ordinary day would run.
            #expect(try state(.hk, 2026, month, dateDay, 12, 10) == .closed)
            #expect(try state(.hk, 2026, month, dateDay, 12, 30) == .closed)
            #expect(try state(.hk, 2026, month, dateDay, 13, 0) == .closed)
            #expect(try state(.hk, 2026, month, dateDay, 16, 9) == .closed)
        }
        // The session opens no earlier than usual.
        #expect(try state(.hk, 2026, 2, 16, 9, 29) == .closed)
        #expect(try state(.hk, 2026, 2, 16, 4, 0) == .closed)
    }

    /// The ordinary session beside a half day is untouched: 09:30–12:00, lunch,
    /// then 13:00–16:10 with the closing auction included.
    @Test("An ordinary Hong Kong day keeps its lunch break and 16:10 close")
    func hongKongOrdinarySession() throws {
        // Friday 2026-02-13 sits just before the Lunar New Year run.
        #expect(ExchangeCalendar.earlyCloseMinutes(.hk, on: calendarDay(2026, 2, 13)) == nil)
        #expect(try state(.hk, 2026, 2, 13, 9, 29) == .closed)
        #expect(try state(.hk, 2026, 2, 13, 9, 30) == .regular)
        #expect(try state(.hk, 2026, 2, 13, 11, 59) == .regular)
        #expect(try state(.hk, 2026, 2, 13, 12, 0) == .lunchBreak)
        #expect(try state(.hk, 2026, 2, 13, 12, 59) == .lunchBreak)
        #expect(try state(.hk, 2026, 2, 13, 13, 0) == .regular)
        #expect(try state(.hk, 2026, 2, 13, 16, 9) == .regular)
        #expect(try state(.hk, 2026, 2, 13, 16, 10) == .closed)
        // Thursday 2026-11-26 is a US holiday but an ordinary Hong Kong day.
        #expect(try state(.hk, 2026, 11, 26, 11, 45) == .regular)
        #expect(try state(.hk, 2026, 11, 26, 12, 30) == .lunchBreak)
        #expect(try state(.hk, 2026, 11, 26, 15, 0) == .regular)
    }

    @Test("A Hong Kong holiday has no session at all")
    func hongKongHolidaySession() throws {
        #expect(try state(.hk, 2026, 10, 1, 9, 30) == .closed)
        #expect(try state(.hk, 2026, 10, 1, 11, 0) == .closed)
        #expect(try state(.hk, 2026, 10, 1, 14, 0) == .closed)
        #expect(try state(.hk, 2026, 2, 18, 10, 0) == .closed)
        #expect(try state(.hk, 2026, 4, 7, 10, 0) == .closed)
        #expect(try state(.hk, 2026, 12, 25, 10, 0) == .closed)
        // A weekend stays shut regardless of the table.
        #expect(try state(.hk, 2026, 2, 21, 10, 0) == .closed)
        #expect(try state(.hk, 2026, 2, 22, 10, 0) == .closed)
    }

    /// 2026-09-30 17:00 UTC is 2026-10-01 01:00 in Hong Kong, and the 1st is a
    /// listed closure: the exchange day decides, not the UTC date.
    @Test("Hong Kong reads its own date for a holiday boundary")
    func hongKongTimeZoneBoundary() throws {
        let instant = try utcDate(2026, 9, 30, 17, 0)
        #expect(CalendarDay(instant, in: Market.hk.timeZone) == calendarDay(2026, 10, 1))
        #expect(ExchangeCalendar.isHoliday(.hk, on: calendarDay(2026, 10, 1)))
        #expect(TradingCalendar.state(of: .hk, at: instant) == .closed)
        // The UTC date — and Hong Kong's own previous day — would have traded.
        #expect(ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2026, 9, 30)))
        #expect(try state(.hk, 2026, 9, 30, 10, 0) == .regular)
    }

    /// Hong Kong's table is 2026 only, so 2027 falls back to the weekday rule
    /// rather than borrowing the dates next door.
    @Test("An unknown Hong Kong year falls back to the weekday rule")
    func hongKongUnknownYearFallback() throws {
        #expect(ExchangeCalendar.coveredYears[.hk] == 2026...2026)
        for (month, dateDay) in [
            (1, 1), (2, 17), (4, 6), (5, 1), (7, 1), (10, 1), (12, 25),
        ] {
            #expect(!ExchangeCalendar.isHoliday(.hk, on: calendarDay(2027, month, dateDay)))
        }
        #expect(ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2027, 10, 1)))
        #expect(try state(.hk, 2027, 10, 1, 10, 0) == .regular)
        // Weekends still close in a year with no table.
        #expect(!ExchangeCalendar.isTradingDay(.hk, on: calendarDay(2027, 10, 2)))  // Saturday
    }

    // MARK: - Korea

    @Test("KRX 2026 government, election and exchange closures apply to both boards")
    func koreaHolidays2026() throws {
        for market in [Market.kr, .kq] {
            for (month, dateDay) in [
                (1, 1), (2, 16), (2, 17), (2, 18), (3, 2),
                (5, 1), (5, 5), (5, 25), (6, 3), (7, 17), (8, 17),
                (9, 24), (9, 25), (10, 5), (10, 9), (12, 25), (12, 31),
            ] {
                #expect(ExchangeCalendar.isHoliday(market, on: calendarDay(2026, month, dateDay)))
                #expect(try state(market, 2026, month, dateDay, 12, 0) == .closed)
            }
            // A Saturday Memorial Day does not create an extra Monday closure.
            #expect(try state(market, 2026, 6, 5, 10, 0) == .regular)
            #expect(try state(market, 2026, 6, 8, 10, 0) == .regular)
            #expect(try state(market, 2026, 10, 6, 9, 0) == .regular)
            #expect(try state(market, 2026, 10, 6, 15, 29) == .regular)
            #expect(try state(market, 2026, 10, 6, 15, 30) == .closed)
        }
    }

    // MARK: - Covered-year bounds

    @Test("Unknown years fall back to the weekday-only rule")
    func unknownYearFallback() throws {
        // 2025-12-25 and 2029-01-01 are holidays in reality but outside every
        // table here, so the weekday rule stands rather than a guess.
        #expect(!ExchangeCalendar.isHoliday(.us, on: calendarDay(2025, 12, 25)))
        #expect(ExchangeCalendar.isTradingDay(.us, on: calendarDay(2025, 12, 25)))
        #expect(try state(.us, 2025, 12, 25, 10, 0) == .regular)
        #expect(!ExchangeCalendar.isHoliday(.jp, on: calendarDay(2029, 1, 1)))
        #expect(try state(.jp, 2029, 1, 1, 10, 0) == .regular)
        #expect(!ExchangeCalendar.isHoliday(.sh, on: calendarDay(2027, 10, 1)))
        #expect(try state(.sh, 2027, 10, 1, 10, 0) == .regular)
        // Weekends still close, in any year.
        #expect(try state(.us, 2025, 12, 27, 10, 0) == .closed)
    }

    @Test("Unknown Korea years keep the weekday rule")
    func koreaUnknownYearFallback() throws {
        for market in [Market.kr, .kq] {
            #expect(ExchangeCalendar.coveredYears[market] == 2026...2026)
            #expect(!ExchangeCalendar.isHoliday(market, on: calendarDay(2027, 1, 1)))
            #expect(try state(market, 2027, 1, 1, 10, 0) == .regular)
            #expect(try state(market, 2027, 1, 2, 10, 0) == .closed)
            #expect(ExchangeCalendar.earlyCloseMinutes(market, on: calendarDay(2027, 1, 1)) == nil)
        }
    }

    /// Crypto has no closing bell. Generic metal quotes keep their current
    /// continuous-week schedule without borrowing an equity holiday calendar.
    @Test("Crypto trades every day and metals keep their continuous week")
    func cryptoAndMetal() throws {
        // Crypto has no holidays and no closing bell — and weekends are not an
        // exception: the check answers before the weekend rule can run.
        for quietDay in [calendarDay(2026, 1, 1), calendarDay(2026, 12, 25),
                         calendarDay(2026, 7, 4), calendarDay(2028, 1, 1),
                         calendarDay(2026, 1, 3), calendarDay(2026, 1, 4),
                         calendarDay(2026, 8, 22), calendarDay(2026, 8, 23)] {
            #expect(!ExchangeCalendar.isHoliday(.crypto, on: quietDay))
            #expect(ExchangeCalendar.isTradingDay(.crypto, on: quietDay))
        }
        // Saturday and Sunday specifically, with the weekend rule confirmed to
        // be firing on the same days for an exchange that has one.
        #expect(ExchangeCalendar.isWeekend(calendarDay(2026, 1, 3)))
        #expect(ExchangeCalendar.isWeekend(calendarDay(2026, 1, 4)))
        #expect(!ExchangeCalendar.isTradingDay(.us, on: calendarDay(2026, 1, 3)))
        #expect(try state(.crypto, 2026, 1, 1, 3, 0) == .regular)
        #expect(try state(.crypto, 2026, 12, 25, 15, 0) == .regular)
        #expect(try state(.crypto, 2026, 1, 3, 12, 0) == .regular)
        #expect(try state(.crypto, 2026, 1, 4, 3, 0) == .regular)

        // No verified venue calendar is assigned to these generic metal quotes.
        #expect(!ExchangeCalendar.isHoliday(.metal, on: calendarDay(2026, 12, 25)))
        #expect(try state(.metal, 2026, 12, 25, 10, 0) == .regular)
        #expect(try state(.metal, 2026, 12, 26, 10, 0) == .closed)
        #expect(try state(.metal, 2026, 12, 27, 18, 0) == .regular)
    }
}
