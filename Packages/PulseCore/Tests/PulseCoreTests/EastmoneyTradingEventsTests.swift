import Foundation
import XCTest
@testable import PulseCore

final class EastmoneyTradingEventsTests: XCTestCase {
    private let sh = SymbolID(market: .sh, code: "600519")

    func testStrictDateParsingAndMissingPayloadStayUnavailable() throws {
        let parsed = try XCTUnwrap(EastmoneyTradingEvents.parseDate("2026-10-08 00:00:00"))
        let calendar = EastmoneyTradingEvents.dateCalendar
        XCTAssertEqual(calendar.component(.day, from: parsed), 8)
        XCTAssertEqual(calendar.component(.hour, from: parsed), 0)
        XCTAssertEqual(calendar.timeZone.identifier, "Asia/Shanghai")
        XCTAssertNil(EastmoneyTradingEvents.parseDate("2026-02-30 00:00:00"))
        XCTAssertNil(EastmoneyTradingEvents.parseDate("NaN"))

        XCTAssertNil(EastmoneyTradingEvents.parse(
            Data(#"{"success":true,"result":{}}"#.utf8),
            source: .earnings, symbols: [sh], now: parsed, sourceURL: "https://example.com"
        ))
        XCTAssertEqual(EastmoneyTradingEvents.parse(
            Data(#"{"success":false,"code":9201,"message":"返回数据为空"}"#.utf8),
            source: .earnings, symbols: [sh], now: parsed, sourceURL: "https://example.com"
        )?.count, 0)
    }

    func testOnlyMatchingSymbolAndValidForecastRowsAreAccepted() throws {
        let payload = #"{"success":true,"result":{"pages":1,"data":[{"SECURITY_CODE":"600519","SECUCODE":"600519.SH","NOTICE_DATE":"2026-10-31 00:00:00","EVENT_TYPE":"预约披露日","LEVEL1_CONTENT":"2026年第三季度季报预约2026年10月31日披露"},{"SECURITY_CODE":"600519","SECUCODE":"600519.SZ","NOTICE_DATE":"2026-10-31 00:00:00","EVENT_TYPE":"预约披露日","LEVEL1_CONTENT":"wrong exchange"},{"SECURITY_CODE":"600519","SECUCODE":"600519.SH","NOTICE_DATE":"NaN","EVENT_TYPE":"预约披露日","LEVEL1_CONTENT":"missing date"},{"SECURITY_CODE":"600519","SECUCODE":"600519.SH","NOTICE_DATE":"2026-10-31 00:00:00","EVENT_TYPE":"公告","LEVEL1_CONTENT":"not an appointment"}]}}"#
        let now = try XCTUnwrap(EastmoneyTradingEvents.parseDate("2026-10-01"))
        let records = try XCTUnwrap(EastmoneyTradingEvents.parse(
            Data(payload.utf8), source: .earnings, symbols: [sh], now: now,
            sourceURL: "https://example.com/source"
        ))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].symbol, sh)
        XCTAssertEqual(records[0].event.kind, .earnings)
        XCTAssertTrue(records[0].isForecast)
        XCTAssertEqual(records[0].sourceName, "东方财富")
        XCTAssertEqual(records[0].event.title, "2026年第三季度季报预约2026年10月31日披露")
        let refreshed = try XCTUnwrap(EastmoneyTradingEvents.parse(
            Data(payload.utf8), source: .earnings, symbols: [sh], now: now,
            sourceURL: "https://example.com/source"
        ))
        XCTAssertEqual(records[0].event.id, refreshed[0].event.id)
        XCTAssertNil(EastmoneyTradingEvents.parse(
            Data(#"{"success":true,"result":{"pages":2,"data":[]}}"#.utf8),
            source: .earnings, symbols: [sh], now: now, sourceURL: "https://example.com/source"
        ))
    }

    func testDividendAndUnlockRowsUseObservedSourceFields() throws {
        let now = try XCTUnwrap(EastmoneyTradingEvents.parseDate("2026-10-01"))
        let dividend = #"{"success":true,"result":{"pages":1,"data":[{"SECURITY_CODE":"600519","SECUCODE":"600519.SH","EX_DIVIDEND_DATE":"2026-10-08 00:00:00","IMPL_PLAN_PROFILE":"10派1.00元(含税)"}]}}"#
        let unlock = #"{"success":true,"result":{"pages":1,"data":[{"SECURITY_CODE":"600519","SECUCODE":"600519.SH","FREE_DATE":"2026-10-08 00:00:00","FREE_SHARES_TYPE":"股权激励限售股份","FREE_SHARES":"NaN"}]}}"#
        let dividendRecords = try XCTUnwrap(EastmoneyTradingEvents.parse(
            Data(dividend.utf8), source: .dividends, symbols: [sh], now: now,
            sourceURL: "https://example.com/dividend"
        ))
        let unlockRecords = try XCTUnwrap(EastmoneyTradingEvents.parse(
            Data(unlock.utf8), source: .unlocks, symbols: [sh], now: now,
            sourceURL: "https://example.com/unlock"
        ))
        XCTAssertEqual(dividendRecords.first?.event.kind, .dividend)
        XCTAssertEqual(dividendRecords.first?.event.title, "10派1.00元(含税)")
        XCTAssertFalse(dividendRecords.first?.isForecast ?? true)
        XCTAssertEqual(unlockRecords.first?.event.kind, .unlock)
        XCTAssertEqual(unlockRecords.first?.event.title, "股权激励限售股份")
    }
}
