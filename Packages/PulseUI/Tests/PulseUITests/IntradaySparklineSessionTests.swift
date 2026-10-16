import Foundation
import Testing
import PulseCore
@testable import PulseUI

/// The shared-axis contract for list rows. These tests cover the decision that
/// places a row on someone else's clock, which is the only way a Korean row and
/// a Chinese row can be read against each other.
struct IntradaySparklineSessionTests {
    private func session(_ market: Market, on day: Int = 19) throws -> IntradayTradingSession {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: day)))
        return IntradayTradingSession(market: market, referenceDate: date)
    }

    /// With no reference market the row keeps its own exchange's session, which
    /// is what every caller outside the aligned groups relies on. A nil default
    /// that accidentally projected would shift every existing row.
    @Test("No reference market keeps the session on its own exchange's clock")
    func noReferenceKeepsOwnSession() throws {
        let seoul = try session(.kr)
        #expect(IntradaySparklineView.plotSession(of: seoul, referenceMarket: nil) == seoul)
    }

    /// Naming the row's own market is the same as naming none: the projection is
    /// skipped rather than round-tripped through a calendar that could move a
    /// boundary by a second.
    @Test("The row's own market as reference is still the identity")
    func ownMarketAsReferenceIsIdentity() throws {
        let shanghai = try session(.sh)
        #expect(IntradaySparklineView.plotSession(of: shanghai, referenceMarket: .sh) == shanghai)
    }

    /// The whole point of the feature: a Korean row and a Chinese row must place
    /// the same instant at the same x.
    ///
    /// The equality is on the axis *fraction*, which is what becomes an x
    /// coordinate. Seoul's 390-minute axis and Shanghai's 240-minute one have
    /// different lengths, so the same instant sits at a different fraction of
    /// each session — and at a different `minuteOffset`. Only a shared clock
    /// window fixes both rows to absolute Beijing time, which is what
    /// `axisBounds` + `axisFraction` provide.
    ///
    /// This test exists because `projected(to:)` alone looks like it should work
    /// and does not: it re-reads a session's boundaries but leaves the row still
    /// measuring from its own open, so the two rows stayed 53px apart at 348px
    /// wide. Asserting the fraction catches that; asserting the offset does not.
    @Test("A Korean row and a Chinese row place the same instant at the same x")
    func koreanRowSharesChineseX() throws {
        let seoul = try session(.kr)
        let shanghai = try session(.sh)

        var beijingCalendar = Calendar(identifier: .gregorian)
        beijingCalendar.timeZone = Market.sh.timeZone
        // 14:12 in Beijing is 15:12 in Seoul: one instant, two local readings.
        let bar = try #require(
            beijingCalendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 14, minute: 12))
        )

        let koreanPlotted = IntradaySparklineView.plotSession(of: seoul, referenceMarket: .sh)
        let chinesePlotted = IntradaySparklineView.plotSession(of: shanghai, referenceMarket: .sh)

        // Both rows are drawn against the same Beijing clock window.
        let bounds = IntradayTradingSession.axisBounds(
            for: [seoul, shanghai], reference: .sh
        )
        let koreanX = koreanPlotted.axisFraction(for: bar, reference: .sh, bounds: bounds)
        let chineseX = chinesePlotted.axisFraction(for: bar, reference: .sh, bounds: bounds)

        #expect(koreanX != nil)
        #expect(chineseX != nil)
        #expect(abs((koreanX ?? -1) - (chineseX ?? -2)) < 0.001)

        // The window has to cover both sessions' Beijing readings, or one of the
        // two rows would be clipped at an edge.
        #expect(bounds.start <= 8 * 60)      // Seoul 09:00 KST = 08:00 CST
        #expect(bounds.end >= 15 * 60)       // Shanghai 15:00 close
        #expect(bounds.start < 8 * 60 + 60)  // and no wider than the union needs
    }

    /// Seoul trades straight through Shanghai's lunch break, so a projected
    /// Korean axis must still have no break. Inventing one would draw a gap in a
    /// line that never stopped trading.
    @Test("A projected Korean session keeps trading through the Chinese lunch")
    func projectedKoreanSessionHasNoLunch() throws {
        let projected = IntradaySparklineView.plotSession(of: try session(.kr), referenceMarket: .sh)
        #expect(projected.morningEnd == nil)
        #expect(projected.afternoonStart == nil)
        #expect(projected.totalMinutes == 390)
    }

    /// The A-share row is the axis every other row is measured against, so its
    /// own lunch boundaries have to survive untouched.
    @Test("The A-share row's lunch boundaries survive the projection")
    func chineseLunchBoundariesSurvive() throws {
        let shanghai = try session(.sh)
        let projected = IntradaySparklineView.plotSession(of: shanghai, referenceMarket: .sh)
        #expect(projected.morningEnd == shanghai.morningEnd)
        #expect(projected.afternoonStart == shanghai.afternoonStart)
        #expect(projected.totalMinutes == 240)
    }
}
