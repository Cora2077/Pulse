import Foundation

/// Published exchange closures and early closes for the covered years below.
/// Queries use the exchange-local `CalendarDay` supplied by `TradingCalendar`;
/// UTC is used only for local weekday and date arithmetic. There is no fetch.
/// Years without a table retain the previous weekday-only policy.
public enum ExchangeCalendar {
    // MARK: - Public queries

    /// The weekday-and-holiday policy for a day session. Crypto always trades;
    /// continuous and overnight windows are handled by `TradingCalendar.state`.
    public static func isTradingDay(_ market: Market, on day: CalendarDay) -> Bool {
        if market == .crypto { return true }
        guard !isHoliday(market, on: day) else { return false }
        // Civil make-up workdays do not reopen an exchange on the weekend.
        return !isWeekend(day)
    }

    /// Whether `day` is one of the market's verified full closures. Crypto has
    /// none; markets without a table for `day`'s year have none either.
    public static func isHoliday(_ market: Market, on day: CalendarDay) -> Bool {
        switch market {
        case .crypto:
            return false  // quoted around the clock, every day of the year
        case .us:
            return usHolidays.contains(day)
        case .metal:
            // Generic precious-metal quotes have no verified venue calendar here.
            // TradingCalendar retains their existing continuous-week schedule.
            return false
        case .sh, .sz, .metalCN:
            // The published 2026 SSE, SHFE and SGE closure dates agree.
            return chinaHolidays.contains(day)
        case .jp:
            return japanHolidays.contains(day)
        case .hk:
            return hongKongHolidays.contains(day)
        case .kr, .kq:
            return koreaHolidays2026.contains(day)
        }
    }

    /// Minutes past midnight, in the market's own zone, at which an early close
    /// ends each of the day's sessions. `nil` on an ordinary day, and on a full
    /// holiday (which has no session to shorten).
    ///
    /// - `regular`: the regular session's close — 13:00 ET on a US half day, and
    ///   12:10 HKT on a Hong Kong half day.
    /// - `extended`: the end of the session that follows. 17:00 ET for US
    ///   after-hours; Hong Kong has no post-market session, so it repeats 12:10.
    public static func earlyCloseMinutes(
        _ market: Market,
        on day: CalendarDay
    ) -> (regular: Int, extended: Int)? {
        switch market {
        case .us:
            return usEarlyCloses[day]
        case .hk:
            // 12:10 HKT, the closing auction included: trading ends there and no
            // after-hours session runs, which is what `extended` repeats.
            guard hongKongHalfDays.contains(day) else { return nil }
            return (12 * 60 + 10, 12 * 60 + 10)
        default:
            return nil
        }
    }

    /// The evening dates explicitly cancelled by SHFE and SGE holiday notices.
    /// This lookup affects only Shanghai metals, not US overnight trading.
    static func isMetalCNNightCancelled(on day: CalendarDay) -> Bool {
        metalCNCancelledNights.contains(day)
    }

    // MARK: - Basic day arithmetic

    /// A Gregorian calendar pinned to UTC. Every question below is about a
    /// civil date, never an instant, so the zone is fixed and no device setting
    /// can move an answer; `CalendarDay` already carries the exchange's date.
    private static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(from day: CalendarDay) -> Date? {
        gregorianUTC.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day
        ))
    }

    private static func day(from date: Date) -> CalendarDay {
        let parts = gregorianUTC.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    /// Saturday or Sunday in the proleptic Gregorian calendar. Independent of
    /// any time zone, because the day itself is already the exchange's.
    public static func isWeekend(_ day: CalendarDay) -> Bool {
        switch weekday(day) {
        case 1, 7: true
        default: false
        }
    }

    /// 1 = Sunday … 7 = Saturday, the proleptic Gregorian week `Foundation`'s
    /// Gregorian `Calendar` reports.
    public static func weekday(_ day: CalendarDay) -> Int {
        guard let date = date(from: day) else { return 0 }
        return gregorianUTC.component(.weekday, from: date)
    }

    /// The day after `day`, by calendar rules rather than by a caller's clock,
    /// so this cannot drift across a DST change or a device's own zone.
    static func nextDay(_ day: CalendarDay) -> CalendarDay {
        guard let date = date(from: day),
              let next = gregorianUTC.date(byAdding: .day, value: 1, to: date)
        else { return day }
        return self.day(from: next)
    }

    /// The day before `day`, by the same rules. Used by the Shanghai metals
    /// small hours, which belong to the evening session that opened yesterday.
    static func previousDay(_ day: CalendarDay) -> CalendarDay {
        guard let date = date(from: day),
              let previous = gregorianUTC.date(byAdding: .day, value: -1, to: date)
        else { return day }
        return self.day(from: previous)
    }

    // MARK: - Covered years

    /// The years each market's table actually covers. Kept next to the data so
    /// the bound is reviewable rather than implied; nothing reads it at runtime.
    ///
    /// - `us`: NYSE, 2026–2028
    /// - `sh`/`sz`/`metalCN`: SSE, SHFE and SGE, 2026
    /// - `jp`: Tokyo Stock Exchange, 2026–2027
    /// - `hk`: HKEX securities market, 2026
    /// - `kr`/`kq`: Korea Exchange, 2026
    ///
    /// Generic precious-metal quotes have no covered holiday calendar here.
    public static let coveredYears: [Market: ClosedRange<Int>] = [
        .us: 2026...2028,
        .sh: 2026...2026,
        .sz: 2026...2026,
        .metalCN: 2026...2026,
        .jp: 2026...2027,
        .hk: 2026...2026,
        .kr: 2026...2026,
        .kq: 2026...2026,
    ]

    // MARK: - Mainland China (sh / sz / metalCN), 2026

    /// 2026 closures of the mainland cash and Shanghai metals markets.
    ///
    /// Source: Shanghai Stock Exchange 2026 holiday arrangement,
    /// https://www.sse.com.cn/disclosure/announcement/general/c/c_20251222_10802507.shtml
    /// Shanghai metals closures and cancelled night sessions:
    /// https://www.shfe.com.cn/services/calenderandholidays/holiday/
    /// https://www.sge.com.cn/jjsnotice/10007108
    ///
    /// The listed ranges include weekends; civil make-up Saturdays stay closed.
    /// SHFE and SGE publish the same holiday runs. Their notices separately
    /// cancel the last evening before each holiday, including Friday Feb 13
    /// before the Spring Festival closure begins on Sunday Feb 15.
    static let chinaHolidays2026: Set<CalendarDay> = days([
        // New Year
        (1, 1), (1, 2), (1, 3),
        // Spring Festival
        (2, 15), (2, 16), (2, 17), (2, 18), (2, 19),
        (2, 20), (2, 21), (2, 22), (2, 23),
        // Qingming
        (4, 4), (4, 5), (4, 6),
        // Labour Day
        (5, 1), (5, 2), (5, 3), (5, 4), (5, 5),
        // Dragon Boat
        (6, 19), (6, 20), (6, 21),
        // Mid-Autumn
        (9, 25), (9, 26), (9, 27),
        // National Day
        (10, 1), (10, 2), (10, 3), (10, 4), (10, 5), (10, 6), (10, 7),
    ], year: 2026)

    /// Shared mainland full-day closures for the covered year.
    private static let chinaHolidays: Set<CalendarDay> = chinaHolidays2026

    /// Exact evening cancellations in the official SHFE/SGE 2026 notices above.
    /// Dec 31, 2025 is included only as the eve of the covered New Year holiday;
    /// this does not extend the general holiday calendar to all of 2025.
    private static let metalCNCancelledNights: Set<CalendarDay> =
        days([(12, 31)], year: 2025).union(days([
            (2, 13), (4, 3), (4, 30), (6, 18), (9, 24), (9, 30),
        ], year: 2026))

    // MARK: - United States (NYSE), 2026–2028

    /// Source: NYSE trading hours and calendar, https://www.nyse.com/trade/hours-calendars
    ///
    /// These are the listed observations and nothing more. They are *not*
    /// derived from US federal holiday rules, which would add dates the NYSE
    /// trades: 2028-01-01 is a Saturday and 2027-12-31 (Friday) is a normal
    /// session, so there is no observance there to import.
    private static let usHolidays: Set<CalendarDay> =
        usHolidays2026.union(usHolidays2027).union(usHolidays2028)

    /// 2026: Jan 1, Jan 19 (Martin Luther King Jr.), Feb 16 (Washington's
    /// Birthday), Apr 3 (Good Friday), May 25 (Memorial Day), Jun 19
    /// (Juneteenth), Jul 3 (Independence Day observed — Jul 4 is a Saturday),
    /// Sep 7 (Labor Day), Nov 26 (Thanksgiving), Dec 25 (Christmas).
    private static let usHolidays2026: Set<CalendarDay> = days([
        (1, 1), (1, 19), (2, 16), (4, 3), (5, 25),
        (6, 19), (7, 3), (9, 7), (11, 26), (12, 25),
    ], year: 2026)

    /// 2027: Jan 1, Jan 18 (MLK), Feb 15 (Washington's Birthday), Mar 26 (Good
    /// Friday), May 31 (Memorial Day), Jun 18 (Juneteenth observed — Jun 19 is
    /// a Saturday), Jul 5 (Independence Day observed — Jul 4 is a Sunday),
    /// Sep 6 (Labor Day), Nov 25 (Thanksgiving), Dec 24 (Christmas observed —
    /// Dec 25 is a Saturday).
    private static let usHolidays2027: Set<CalendarDay> = days([
        (1, 1), (1, 18), (2, 15), (3, 26), (5, 31),
        (6, 18), (7, 5), (9, 6), (11, 25), (12, 24),
    ], year: 2027)

    /// 2028: Jan 17 (MLK), Feb 21 (Washington's Birthday), Apr 14 (Good
    /// Friday), May 29 (Memorial Day), Jun 19 (Juneteenth), Jul 4
    /// (Independence Day), Sep 4 (Labor Day), Nov 23 (Thanksgiving), Dec 25
    /// (Christmas). Jan 1 falls on a Saturday and is not observed on the
    /// preceding Friday: the NYSE is open on 2027-12-31.
    private static let usHolidays2028: Set<CalendarDay> = days([
        (1, 17), (2, 21), (4, 14), (5, 29), (6, 19),
        (7, 4), (9, 4), (11, 23), (12, 25),
    ], year: 2028)

    /// Half days: the regular session ends at 13:00 ET and the after-hours
    /// session, per the same NYSE calendar page, at 17:00 ET (NYSE Arca runs
    /// the after-hours session, which is why its close is the one quoted).
    ///
    /// 2026: Nov 27 (day after Thanksgiving), Dec 24 (Christmas Eve).
    /// 2027: Nov 26. 2028: Jul 3, Nov 24. Christmas Eve 2027 is a full holiday
    /// above rather than a half day, and 2028 has no Christmas Eve session at
    /// all, so neither is repeated here.
    private static let usEarlyCloses: [CalendarDay: (regular: Int, extended: Int)] = {
        var table: [CalendarDay: (regular: Int, extended: Int)] = [:]
        func halfDay(_ year: Int, _ month: Int, _ day: Int) {
            table[CalendarDay(year: year, month: month, day: day)] = (13 * 60, 17 * 60)
        }
        halfDay(2026, 11, 27)
        halfDay(2026, 12, 24)
        halfDay(2027, 11, 26)
        halfDay(2028, 7, 3)
        halfDay(2028, 11, 24)
        return table
    }()

    // MARK: - Japan (Tokyo Stock Exchange), 2026–2027

    /// Source: JPX trading calendar,
    /// https://www.jpx.co.jp/english/corporate/about-jpx/calendar/index.html
    ///
    /// The Tokyo exchange closes for the December 31–January 3 New Year run.
    /// These are the dates JPX *lists* as non-trading days, which is why Jan 2
    /// and Jan 3 appear even in years where they fall on a weekend and cost the
    /// exchange nothing: the table mirrors the notice rather than trimming it.
    private static let japanHolidays: Set<CalendarDay> =
        japanHolidays2026.union(japanHolidays2027)

    /// 2026: Jan 1–3 and Jan 12 (Coming of Age Day), Feb 11 (National
    /// Foundation Day), Feb 23 (Emperor's Birthday), Mar 20 (Vernal Equinox
    /// Day), Apr 29 (Showa Day), May 3–6 (Constitution Memorial Day, Greenery
    /// Day, Children's Day, and the substitute holiday), Jul 20 (Marine Day),
    /// Aug 11 (Mountain Day), Sep 21–23 (Respect for the Aged Day, Citizens'
    /// Holiday, Autumnal Equinox Day), Oct 12 (Sports Day), Nov 3 (Culture
    /// Day), Nov 23 (Labour Thanksgiving Day), Dec 31 (year-end closure).
    private static let japanHolidays2026: Set<CalendarDay> = days([
        (1, 1), (1, 2), (1, 3), (1, 12),
        (2, 11), (2, 23),
        (3, 20),
        (4, 29),
        (5, 3), (5, 4), (5, 5), (5, 6),
        (7, 20),
        (8, 11),
        (9, 21), (9, 22), (9, 23),
        (10, 12),
        (11, 3), (11, 23),
        (12, 31),
    ], year: 2026)

    /// 2027: Jan 1–3 and Jan 11 (Coming of Age Day), Feb 11, Feb 23, Mar 21 and
    /// Mar 22 (Vernal Equinox Day and its substitute), Apr 29, May 3–5, Jul 19
    /// (Marine Day), Aug 11, Sep 20 and Sep 23 (Respect for the Aged Day and
    /// Autumnal Equinox Day), Oct 11 (Sports Day), Nov 3, Nov 23, Dec 31.
    /// Sep 21–22 fall between those two listed holidays and are not in the
    /// table: they are ordinary trading days here.
    private static let japanHolidays2027: Set<CalendarDay> = days([
        (1, 1), (1, 2), (1, 3), (1, 11),
        (2, 11), (2, 23),
        (3, 21), (3, 22),
        (4, 29),
        (5, 3), (5, 4), (5, 5),
        (7, 19),
        (8, 11),
        (9, 20), (9, 23),
        (10, 11),
        (11, 3), (11, 23),
        (12, 31),
    ], year: 2027)

    // MARK: - Hong Kong (HKEX securities market), 2026

    /// HKEX full closures. Source: "Hong Kong Securities Market Holiday
    /// Schedule for Year 2026", HKEX circular CT/075/25,
    /// https://www.hkex.com.hk/-/media/HKEX-Market/Services/Circulars-and-Notices/Participant-and-Members-Circulars/SEHK/2025/ce_SEHK_CT_075_2025.pdf
    ///
    /// Weekend closures are also enforced by `isTradingDay`.
    private static let hongKongHolidays2026: Set<CalendarDay> = days([
        (1, 1),                                     // The first day of January
        (2, 17), (2, 18), (2, 19),                  // Lunar New Year, days one to three
        (4, 3), (4, 6), (4, 7),                     // Good Friday; after Ching Ming; after Easter Monday
        (5, 1),                                     // Labour Day
        (5, 25),                                    // Day after the Birthday of the Buddha
        (6, 19),                                    // Tuen Ng Festival
        (7, 1),                                     // HKSAR Establishment Day
        (10, 1), (10, 19),                          // National Day; day after Chung Yeung Festival
        (12, 25),                                   // Christmas Day
    ], year: 2026)

    private static let hongKongHolidays: Set<CalendarDay> = hongKongHolidays2026

    /// Half days: the securities market closes at 12:10 HKT, the closing auction
    /// included, with no after-hours session. Source: HKEX trading hours,
    /// https://www.hkex.com.hk/Services/Trading-hours-and-Severe-Weather-Arrangements/Trading-Hours/Securities-Market
    ///
    /// 2026: Feb 16 (Lunar New Year's Eve), Dec 24 (Christmas Eve), Dec 31 (New
    /// Year's Eve). Kept as a set rather than a minutes map because every Hong
    /// Kong half day closes at the same time — see `earlyCloseMinutes`.
    private static let hongKongHalfDays: Set<CalendarDay> = days([
        (2, 16), (12, 24), (12, 31),
    ], year: 2026)

    // MARK: - Korea (KRX KOSPI and KOSDAQ), 2026

    /// Verified 2026 weekday closures. KRX closes for government holidays,
    /// elections, Labour Day and its year-end holiday:
    /// https://global.krx.co.kr/contents/GLB/06/0602/0602010201/GLB0602010201T1.jsp
    /// Official 2026 calendar and substitute holiday dates:
    /// https://www.kasa.go.kr/prog/bbsArticle/BBSMSTR_000000000010/view.do?bbsId=BBSMSTR_000000000010&nttId=B000000001860Pe2zT3
    /// https://www.kasi.re.kr/file/1764661238731_1.pdf
    /// July 17 Constitution Day was restored for 2026; official confirmation:
    /// https://www.mpm.go.kr/mpm/comm/newsPress/newsPressRelease/?boardId=bbs_0000000000000029&category=&cntId=4250&mode=view&pageIdx=7
    /// Jun 3 is the election closure. Jun 6 falls on Saturday with no added
    /// substitute closure on Jun 8; weekend holidays are handled by isWeekend.
    private static let koreaHolidays2026: Set<CalendarDay> = days([
        (1, 1),
        (2, 16), (2, 17), (2, 18),
        (3, 2),
        (5, 1), (5, 5), (5, 25),
        (6, 3),
        (7, 17),
        (8, 17),
        (9, 24), (9, 25),
        (10, 5), (10, 9),
        (12, 25), (12, 31),
    ], year: 2026)

    // MARK: - Table construction

    /// `(month, day)` pairs → a set of days in `year`. Written this way so each
    /// table reads as the notice it came from rather than as opaque date strings.
    private static func days(_ pairs: [(Int, Int)], year: Int) -> Set<CalendarDay> {
        Set(pairs.map { CalendarDay(year: year, month: $0.0, day: $0.1) })
    }
}
