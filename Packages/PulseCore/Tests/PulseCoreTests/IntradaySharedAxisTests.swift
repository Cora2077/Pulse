import Foundation
import Testing
@testable import PulseCore

struct IntradaySharedAxisTests {
    private var day: Date { Date(timeIntervalSince1970: 1792548000) }
    @Test("Group identity, order and duplicates cannot change the shared window")
    func membershipFrame() throws {
        let a = try #require(IntradaySharedAxis(markets: [.sh, .kr, .hk], referenceDate: day))
        let b = try #require(IntradaySharedAxis(markets: [.hk, .kr, .sh, .sh, .us], referenceDate: day))
        #expect(a == b)
        #expect(a.startMinute == 480); #expect(a.endMinute == 960)
        #expect(a.fraction(minute: .nan) == nil)
        #expect(a.fraction(minute: 479) == nil)
    }
    @Test("Chinese-only and Japanese mixed groups use their actual Beijing sessions")
    func asiaSessions() throws {
        let cn = try #require(IntradaySharedAxis(markets: [.sh, .sz], referenceDate: day))
        let jp = try #require(IntradaySharedAxis(markets: [.jp, .sh], referenceDate: day))
        #expect(cn.startMinute == 570); #expect(cn.endMinute == 900)
        #expect(jp.startMinute == 480); #expect(jp.endMinute == 900)
        #expect(cn.tickMinutes.contains(570))
        #expect(cn.lunchMinutes == 690...780)
    }
}
