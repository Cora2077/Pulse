import Foundation
import Testing
@testable import PulseCore

@Suite("Fuyao IPO calendar: two codes, nulls, and Beijing market identity")
struct FuyaoIPOTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)
    private func data(_ string: String) -> Data { Data(string.utf8) }

    private var shSzSubscribable: Data {
        data(#"""
        {"code":0,"message":"success","data":{"market":"sh_sz","status":"subscribable","item":[
          {"thscode":"301999.SZ","ticker":"301999","name":"合成科技",
           "subscription_code":"301999","subscription_date":"2026-10-14",
           "listing_date":null,"issue_price":20.3},
          {"thscode":"688999.SH","ticker":"688999","name":"合成半导体",
           "subscription_code":"787999","subscription_date":"2026-10-15",
           "listing_date":null,"issue_price":null}
        ]}}
        """#)
    }

    // MARK: - 解析

    @Test("Ticker and subscription code stay two separate fields")
    func twoCodes() throws {
        let list = try FuyaoProvider.parseIPOList(
            data: shSzSubscribable, market: .shSz, stage: .subscribable, fetchedAt: now)
        #expect(list.entries.count == 2)
        let a = try #require(list.entries.first { $0.ticker == "301999" })
        #expect(a.subscriptionCode == "301999")
        #expect(a.hasDistinctSubscriptionCode == false)
        // 科创板常见 787xxx 申购代码对应 688xxx 交易代码——两者必须分开显示。
        let b = try #require(list.entries.first { $0.ticker == "688999" })
        #expect(b.subscriptionCode == "787999")
        #expect(b.hasDistinctSubscriptionCode)
    }

    @Test("Undetermined listing date and price stay nil, not zero or today")
    func nullsStayNull() throws {
        let list = try FuyaoProvider.parseIPOList(
            data: shSzSubscribable, market: .shSz, stage: .subscribable, fetchedAt: now)
        let a = try #require(list.entries.first { $0.ticker == "301999" })
        #expect(a.listingDate == nil)
        #expect(a.issuePrice == 20.3)
        // 展示层把 nil 说成"待定"，不显示 0。
        #expect(FuyaoIPOFormat.day(a.listingDate) == "待定")
        #expect(FuyaoIPOFormat.price(a.issuePrice) == "20.30 元")

        let b = try #require(list.entries.first { $0.ticker == "688999" })
        #expect(b.issuePrice == nil)
        #expect(FuyaoIPOFormat.price(b.issuePrice) == "待定")
        // 申购日是确定的，正常显示。
        #expect(b.subscriptionDate != nil)
    }

    @Test("A row without a ticker is unusable and skipped")
    func skipsRowsWithoutTicker() throws {
        let body = data(#"""
        {"code":0,"data":{"item":[
          {"thscode":"301999.SZ","name":"无代码","issue_price":10},
          {"ticker":"301998","name":"有代码","issue_price":10}
        ]}}
        """#)
        let list = try FuyaoProvider.parseIPOList(data: body, market: .shSz, stage: .upcoming, fetchedAt: now)
        #expect(list.entries.count == 1)
        #expect(list.entries[0].ticker == "301998")
    }

    @Test("A non-positive issue price is treated as undetermined")
    func rejectsInvalidPrice() throws {
        let body = data(#"""
        {"code":0,"data":{"item":[
          {"ticker":"301998","name":"零价","issue_price":0},
          {"ticker":"301997","name":"负价","issue_price":-5},
          {"ticker":"301996","name":"正常","issue_price":8.88}
        ]}}
        """#)
        let list = try FuyaoProvider.parseIPOList(data: body, market: .shSz, stage: .upcoming, fetchedAt: now)
        #expect(list.entries.first { $0.ticker == "301998" }?.issuePrice == nil)
        #expect(list.entries.first { $0.ticker == "301997" }?.issuePrice == nil)
        #expect(list.entries.first { $0.ticker == "301996" }?.issuePrice == 8.88)
    }

    // MARK: - 市场身份

    @Test("A Shanghai/Shenzhen entry has a Pulse identity; a Beijing one does not")
    func marketIdentity() throws {
        let sh = try FuyaoProvider.parseIPOList(
            data: data(#"{"code":0,"data":{"item":[{"thscode":"688999.SH","ticker":"688999","name":"甲"}]}}"#),
            market: .shSz, stage: .subscribable, fetchedAt: now).entries[0]
        #expect(sh.symbol == SymbolID(market: .sh, code: "688999"))

        let bj = try FuyaoProvider.parseIPOList(
            data: data(#"{"code":0,"data":{"item":[{"thscode":"920285.BJ","ticker":"920285","name":"乙"}]}}"#),
            market: .bj, stage: .subscribable, fetchedAt: now).entries[0]
        // 北交所没有对应 Market：能展示，但没有身份，也就不能加入自选。
        #expect(bj.symbol == nil)
        #expect(bj.thscode == "920285.BJ")
        #expect(FuyaoIPOMarket.bj.supportsSymbolIdentity == false)
    }

    @Test("A null thscode keeps the row but yields no identity")
    func nullThscode() throws {
        let entry = try FuyaoProvider.parseIPOList(
            data: data(#"{"code":0,"data":{"item":[{"thscode":null,"ticker":"301995","name":"丙"}]}}"#),
            market: .shSz, stage: .upcoming, fetchedAt: now).entries[0]
        #expect(entry.thscode == nil)
        #expect(entry.symbol == nil)
        #expect(entry.ticker == "301995")
    }

    // MARK: - 合并与排序

    private func entry(_ ticker: String, market: FuyaoIPOMarket, stage: FuyaoIPOStage,
                       subscribe: Date? = nil) -> FuyaoIPOEntry {
        FuyaoIPOEntry(thscode: ticker + (market == .bj ? ".BJ" : ".SZ"), ticker: ticker,
                      name: ticker, subscriptionCode: ticker,
                      subscriptionDate: subscribe, listingDate: nil, issuePrice: nil,
                      market: market, stage: stage)
    }

    @Test("Calendar orders by stage then subscription date, and deduplicates by id")
    func calendarOrdering() {
        let early = now.addingTimeInterval(-86_400)
        let late = now.addingTimeInterval(86_400)
        let calendar = FuyaoIPOCalendar(lists: [
            FuyaoIPOList(market: .shSz, stage: .awaitingListing,
                         entries: [entry("300001", market: .shSz, stage: .awaitingListing)], fetchedAt: now),
            FuyaoIPOList(market: .shSz, stage: .upcoming,
                         entries: [entry("300002", market: .shSz, stage: .upcoming, subscribe: late)], fetchedAt: now),
            // 同一条目在两个阶段都出现 → 去重。
            FuyaoIPOList(market: .shSz, stage: .subscribable,
                                entries: [entry("300003", market: .shSz, stage: .subscribable, subscribe: early)], fetchedAt: now)
        ], fetchedAt: now)
        let ordered = calendar.entries
        // 可申购在前，待申购次之，待上市最后。
        #expect(ordered.map(\.stage) == [.subscribable, .upcoming, .awaitingListing])
        #expect(calendar.entries(stage: .subscribable).count == 1)
        #expect(calendar.hasData)
    }

    @Test("Partial failure keeps the stages that succeeded and reports the rest")
    func partialFailure() {
        let calendar = FuyaoIPOCalendar(lists: [
            FuyaoIPOList(market: .shSz, stage: .subscribable,
                         entries: [entry("300004", market: .shSz, stage: .subscribable)], fetchedAt: now),
            FuyaoIPOList(market: .bj, stage: .subscribable, entries: [], fetchedAt: now, error: "请求受限")
        ], fetchedAt: now)
        #expect(calendar.entries.count == 1)
        #expect(calendar.errors[.subscribable] == "请求受限")
        #expect(calendar.anySucceeded)
    }

    @Test("All queries failing is detectable, not an empty calendar")
    func allFailed() {
        let calendar = FuyaoIPOCalendar(lists: [
            FuyaoIPOList(market: .shSz, stage: .subscribable, entries: [], fetchedAt: now, error: "失败"),
            FuyaoIPOList(market: .bj, stage: .upcoming, entries: [], fetchedAt: now, error: "失败")
        ], fetchedAt: now)
        // 没有数据，也不能被读成"今天没有新股"。
        #expect(calendar.hasData == false)
        #expect(calendar.anySucceeded == false)
    }
}
