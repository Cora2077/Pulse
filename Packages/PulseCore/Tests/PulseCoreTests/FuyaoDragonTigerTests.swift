import Foundation
import Testing
@testable import PulseCore

@Suite("Fuyao dragon-tiger and abnormal monitor semantics")
struct FuyaoDragonTigerTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)
    private func data(_ string: String) -> Data { Data(string.utf8) }

    // 真实形状：含 thscode=null、.BJ、以及同一股票的当日榜与三日榜两行。
    private var dayBody: Data {
        data(#"""
        {"code":0,"data":{"timestamp":1792483200000,"board_type":"all","trade_date":"2026-10-19",
          "count":4,"stock_count":3,
          "stock_items":[
            {"thscode":"600825.SH","ticker":"600825","name":"新华传媒","change":0.027704,
             "concept_list":[{"name":"文化传媒概念"},{"name":"AI语料"}],
             "net_value":-45246913.56,"net_rate":-0.01132292,"hot_rank":1,
             "buy_value":201991394.06,"sell_value":247238307.62,"range_days":1,
             "org_net_value":1234567.89,"org_net_rate":0.004,"org_buy_num":3,"org_sell_num":1,
             "limit_reason":"文化传媒"},
            {"thscode":"600825.SH","ticker":"600825","name":"新华传媒","change":0.0512,
             "net_value":-88000000,"range_days":3},
            {"thscode":null,"ticker":"301139","name":"元道退","change":0.025974,
             "concept_list":[],"net_value":559311.15,"net_rate":0.08047396,"hot_rank":3296,
             "buy_value":2351303.0,"sell_value":1791991.85,"range_days":1},
            {"thscode":"920690.BJ","ticker":"920690","name":"北交所股","change":0.1,
             "net_value":1000,"range_days":1}
          ],
          "hot_money_items":[]}}
        """#)
    }

    @Test("Same stock on both ranges stays two rows and never merges")
    func rangeGrouping() throws {
        let day = try FuyaoProvider.parseDragonTiger(data: dayBody, requestedBoard: .all, fetchedAt: now)
        // 4 条记录、3 只股票：600825 出现两次（当日榜 + 三日榜）。
        #expect(day.recordCount == 4)
        #expect(day.stockCount == 3)
        #expect(day.stockRows.count == 4)
        let xinhua = day.stockRows.filter { $0.ticker == "600825" }
        #expect(xinhua.count == 2)
        #expect(Set(xinhua.map(\.rangeDays)) == [1, 3])
        let grouped = day.rowsByRange
        #expect(grouped[.day]?.count == 3)
        #expect(grouped[.threeDay]?.count == 1)
    }

    @Test("Trade date comes from the response, not from the clock")
    func tradeDateFromResponse() throws {
        let day = try FuyaoProvider.parseDragonTiger(data: dayBody, requestedBoard: .all, fetchedAt: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = FuyaoProvider.beijingTimeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: day.tradeDate)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 19)
        // 与 fetchedAt 无关：抓取时间远晚于业务日。
        #expect(day.fetchedAt == now)
        #expect(day.dataTime != nil)
    }

    @Test("A null thscode keeps the row but has no Pulse identity")
    func nullThscode() throws {
        let day = try FuyaoProvider.parseDragonTiger(data: dayBody, requestedBoard: .all, fetchedAt: now)
        let delisted = try #require(day.stockRows.first { $0.ticker == "301139" })
        #expect(delisted.thscode == nil)
        #expect(delisted.symbol == nil)
        // 身份缺失不丢金额：它仍然是榜单的一部分。
        #expect(delisted.netValue == 559311.15)
        // 去重键退回 ticker，所以它不会和任何完整代码冲突。
        #expect(delisted.id == "301139|1")
    }

    @Test("A .BJ row is kept but maps to no Pulse market")
    func beijingRow() throws {
        let day = try FuyaoProvider.parseDragonTiger(data: dayBody, requestedBoard: .all, fetchedAt: now)
        let bj = try #require(day.stockRows.first { $0.ticker == "920690" })
        #expect(bj.thscode == "920690.BJ")
        #expect(bj.symbol == nil)
    }

    @Test("Fraction fields stay fractions; negative net buy stays negative")
    func units() throws {
        let day = try FuyaoProvider.parseDragonTiger(data: dayBody, requestedBoard: .all, fetchedAt: now)
        let row = try #require(day.stockRows.first { $0.ticker == "600825" && $0.rangeDays == 1 })
        #expect(row.changeFraction == 0.027704)  // 小数，不是 2.77
        #expect(row.netRate == -0.01132292)
        #expect(row.netValue == -45246913.56)
        #expect(row.orgBuyCount == 3)
        #expect(row.concepts == ["文化传媒概念", "AI语料"])
    }

    @Test("Unknown range is not folded into the one-day board")
    func unknownRange() throws {
        let body = data(#"{"code":0,"data":{"trade_date":"2026-10-19","stock_items":[{"ticker":"600000","name":"X","range_days":null,"net_value":5}]}}"#)
        let day = try FuyaoProvider.parseDragonTiger(data: body, requestedBoard: .all, fetchedAt: now)
        #expect(day.stockRows.count == 1)
        #expect(day.stockRows[0].range == nil)
        #expect(day.rowsByRange[.day] == nil)
        #expect(day.rowsWithUnknownRange.count == 1)
    }

    @Test("Duplicate rows collapse on identity plus range")
    func duplicateRows() throws {
        let body = data(#"""
        {"code":0,"data":{"trade_date":"2026-10-19","stock_items":[
          {"thscode":"600000.SH","ticker":"600000","name":"X","range_days":1,"net_value":5},
          {"thscode":"600000.SH","ticker":"600000","name":"X","range_days":1,"net_value":9}
        ]}}
        """#)
        let day = try FuyaoProvider.parseDragonTiger(data: body, requestedBoard: .all, fetchedAt: now)
        #expect(day.stockRows.count == 1)
        #expect(day.stockRows[0].netValue == 5)
    }

    @Test("A missing trade_date is an error, not a silent today")
    func missingTradeDate() {
        let body = data(#"{"code":0,"data":{"stock_items":[]}}"#)
        #expect(throws: ProviderError.self) {
            try FuyaoProvider.parseDragonTiger(data: body, requestedBoard: .all, fetchedAt: now)
        }
    }

    @Test("The echoed board type wins over the requested one")
    func boardEcho() throws {
        let body = data(#"{"code":0,"data":{"board_type":"org","trade_date":"2026-10-19","stock_items":[]}}"#)
        let day = try FuyaoProvider.parseDragonTiger(data: body, requestedBoard: .all, fetchedAt: now)
        #expect(day.boardType == .org)
    }

    // MARK: - 游资榜

    @Test("Hot-money board fills the hot-money table and leaves stock rows empty")
    func hotMoneyBoard() throws {
        let body = data(#"""
        {"code":0,"data":{"board_type":"hot_money","trade_date":"2026-10-19","stock_items":[],
          "hot_money_items":[
            {"name":"游资甲","buying":1200000,"rows":[
              {"thscode":"600000.SH","ticker":"600000","name":"X","range_days":1,"net_value":800000},
              {"ticker":"301139","name":"元道退","range_days":3,"net_value":100}
            ]},
            {"name":"游资乙","buying":300000,"rows":[]}
          ]}}
        """#)
        let day = try FuyaoProvider.parseDragonTiger(data: body, requestedBoard: .hotMoney, fetchedAt: now)
        #expect(day.stockRows.isEmpty)
        #expect(day.hotMoneyRows.count == 2)
        // 按聚合买入降序。
        #expect(day.hotMoneyRows[0].name == "游资甲")
        #expect(day.hotMoneyRows[0].rows.count == 2)
        #expect(day.hotMoneyRows[1].rows.isEmpty)
    }

    // MARK: - 机构详情

    @Test("Institution records keep one-day and three-day apart and preserve seat multiplicity")
    func institutionSeats() throws {
        let body = data(#"""
        {"code":0,"data":{"thscode":"301052.SZ","trade_date":"2026-10-12","item":[
          {"range_days":1,"start_date":"2026-10-12","end_date":"2026-10-12",
           "org_buy_value":78242315.6,"org_sell_value":83760760,"org_net_value":-5518444.4,
           "org_buy_num":3,"org_sell_num":5,"org_net_rate":-0.00945038,
           "buy_departments":[
             {"department_id":"THS59","name":"机构专用"},
             {"department_id":"THS59","name":"机构专用"},
             {"department_id":"T000027098","name":"平安证券浙江分公司"}
           ],
           "sell_departments":[{"department_id":"THS59","name":"机构专用"}]},
          {"range_days":3,"start_date":"2026-10-10","end_date":"2026-10-12","org_net_value":100}
        ]}}
        """#)
        let records = try FuyaoProvider.parseDragonTigerInstitution(data: body, thscode: "301052.SZ")
        #expect(records.count == 2)
        let oneDay = try #require(records.first { $0.rangeDays == 1 })
        #expect(oneDay.buySeats.count == 3)
        let grouped = oneDay.groupedSeats(oneDay.buySeats)
        // 机构专用出现两次：是两条席位记录，不是一家营业部。
        let ths59 = try #require(grouped.first { $0.seat.departmentID == "THS59" })
        #expect(ths59.appearances == 2)
        #expect(grouped.count == 2)
        #expect(oneDay.orgNetValue == -5518444.4)
    }

    @Test("Institution response echoing another symbol is rejected")
    func institutionEcho() {
        let body = data(#"{"code":0,"data":{"thscode":"600000.SH","item":[]}}"#)
        #expect(throws: ProviderError.self) {
            try FuyaoProvider.parseDragonTigerInstitution(data: body, thscode: "301052.SZ")
        }
    }

    // MARK: - 异动监控

    @Test("An open-ended monitor means still watched, not missing")
    func monitorNullEnd() throws {
        let body = data(#"""
        {"code":0,"data":{"item":[
          {"thscode":"600825.SH","name":"新华传媒","start_date_ms":1791734400000,"end_date_ms":null,
           "monitor_type":1,"monitor_label":"严重异动"},
          {"thscode":"000001.SZ","name":"平安银行","start_date_ms":1791734400000,"end_date_ms":1792684800000,
           "monitor_type":9,"monitor_label":"重点监控"},
          {"thscode":null,"name":null,"start_date_ms":null,"end_date_ms":null,"monitor_type":2,"monitor_label":"严重异动"}
        ],
        "pagination":{"page":1,"size":30,"total":2,"has_next":false}}}
        """#)
        let page = try FuyaoProvider.parseAbnormalMonitors(data: body, page: 1, fetchedAt: now)
        // 没有开始日的行无法定位时间，被丢弃而不是补成今天。
        #expect(page.records.count == 2)
        let ongoing = try #require(page.records.first { $0.thscode == "600825.SH" })
        #expect(ongoing.isOngoing)
        #expect(ongoing.endDate == nil)
        #expect(ongoing.label == "严重异动")
        let closed = try #require(page.records.first { $0.thscode == "000001.SZ" })
        #expect(closed.isOngoing == false)
        // label 原文保留，不按类型码重写。
        #expect(closed.label == "重点监控")
        #expect(page.ongoing.count == 1)
        #expect(page.total == 2)
    }

    @Test("Monitor identity survives a missing stock code")
    func monitorIdentity() throws {
        let body = data(#"""
        {"code":0,"data":{"item":[
          {"thscode":"","name":"同名","start_date_ms":1791734400000,"end_date_ms":null,"monitor_type":1,"monitor_label":"严重异动"}
        ]}}
        """#)
        let page = try FuyaoProvider.parseAbnormalMonitors(data: body, page: 1, fetchedAt: now)
        #expect(page.records.count == 1)
        #expect(page.records[0].thscode == nil)
        #expect(page.records[0].symbol == nil)
        #expect(page.records[0].name == "同名")
    }
}
