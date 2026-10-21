import Foundation
import Testing
@testable import PulseCore

@Suite("Fuyao envelope and payload parsing")
struct FuyaoParserTests {
    /// Snapshot response shape from the official docs (fuyao.aicubes.cn/docs/api-reference/prices).
    static let snapshotFixture = Data("""
    {
      "code": 0,
      "message": "success",
      "request_id": "7e25804be878464ba420037155f041e6",
      "data": {
        "timestamp": 1784275991000,
        "total": 2,
        "item": [
          {
            "thscode": "600519.SH",
            "ticker": "600519",
            "volume": 3098875,
            "turnover": 3937375200,
            "last_price": 1277.8,
            "price_change": 21.8,
            "price_change_ratio_pct": 1.735669,
            "open_price": 1252.08,
            "high_price": 1282,
            "low_price": 1250.21,
            "prev_price": 1256
          },
          {
            "thscode": "000001.SZ",
            "ticker": "000001",
            "volume": null,
            "turnover": null,
            "last_price": 0,
            "price_change": null,
            "price_change_ratio_pct": null,
            "open_price": null,
            "high_price": null,
            "low_price": null,
            "prev_price": null
          }
        ]
      }
    }
    """.utf8)

    static func scope(_ thscodes: String, group: FuyaoProvider.Scope.Group = .shares) -> FuyaoProvider.Scope {
        FuyaoProvider.Scope(group: group, codes: thscodes.split(separator: ",").map(String.init))
    }

    @Test("Parses a snapshot batch and drops priceless rows")
    func parseSnapshot() throws {
        let rows = try FuyaoProvider.parseSnapshot(data: Self.snapshotFixture)
        #expect(rows.count == 1)

        let quote = try #require(rows["600519.SH"])
        #expect(quote.price == 1277.8)
        #expect(quote.previousClose == 1256)
        #expect(quote.open == 1252.08)
        #expect(quote.high == 1282)
        #expect(quote.low == 1250.21)
        #expect(quote.volume == 3_098_875)
        #expect(quote.turnover == 3_937_375_200)
        // The identity and the batch time are joined by the caller, not guessed here.
        let timestamp = try FuyaoProvider.batchTimestamp(data: Self.snapshotFixture, scope: Self.scope("600519.SH"))
        #expect(timestamp == Date(timeIntervalSince1970: 1_784_275_991))
    }

    @Test("A batch without a usable timestamp is refused, never stamped now")
    func missingTimestamp() throws {
        let scope = Self.scope("600519.SH")
        for timestamp in ["null", "0", "-1", ""] {
            let fixture = Data("""
            {"code":0,"message":"success","data":{"timestamp":\(timestamp),"item":[
              {"thscode":"600519.SH","last_price":1277.8,"prev_price":1256}
            ]}}
            """.utf8)
            #expect(throws: ProviderError.self) {
                _ = try FuyaoProvider.batchTimestamp(data: fixture, scope: scope)
            }
        }
        let withoutField = Data("""
        {"code":0,"message":"success","data":{"item":[{"thscode":"600519.SH","last_price":1277.8,"prev_price":1256}]}}
        """.utf8)
        #expect(throws: ProviderError.self) {
            _ = try FuyaoProvider.batchTimestamp(data: withoutField, scope: scope)
        }
        #expect(FuyaoProvider.batchTimestamp(.nan) == nil)
        #expect(FuyaoProvider.batchTimestamp(.infinity) == nil)
        #expect(FuyaoProvider.batchTimestamp(0) == nil)
    }

    @Test("Non-finite price and volume never become a quote")
    func nonFiniteSnapshotValues() throws {
        // JSON has no NaN or infinity literal; 1e999 overflows the decoder, and a
        // row it cannot decode fails the envelope rather than yielding a quote.
        let fixture = Data("""
        {"code":0,"message":"success","data":{"timestamp":1784275991000,"item":[
          {"thscode":"600519.SH","last_price":1e999,"prev_price":1256,"volume":1e999}
        ]}}
        """.utf8)
        #expect(throws: (any Error).self) {
            _ = try FuyaoProvider.parseSnapshot(data: fixture)
        }
        // The same row without a previous close is simply not a quote.
        let halfRow = Data("""
        {"code":0,"message":"success","data":{"timestamp":1784275991000,"item":[
          {"thscode":"600519.SH","last_price":1277.8,"prev_price":0,"volume":-5}
        ]}}
        """.utf8)
        #expect(try FuyaoProvider.parseSnapshot(data: halfRow).isEmpty)
    }

    @Test("Parses daily bars in ascending time order")
    func parseCandles() throws {
        let fixture = Data("""
        {
          "code": 0,
          "message": "success",
          "request_id": "b9f91af9c77a42d6b8a04738793d2fa2",
          "data": {
            "timestamp": 1747584000000,
            "item": [
              {
                "date_ms": 1716220800000,
                "open_price": 1602.0,
                "high_price": 1620.0,
                "low_price": 1598.0,
                "close_price": 1610.0,
                "volume": 2000000.0,
                "turnover": 3210000000.0
              },
              {
                "date_ms": 1716134400000,
                "open_price": 1611.602,
                "high_price": 1626.602,
                "low_price": 1601.722,
                "close_price": 1602.612,
                "volume": 3142572.0,
                "turnover": 5401389334.87
              }
            ]
          }
        }
        """.utf8)
        let candles = try FuyaoProvider.parseCandles(data: fixture)
        #expect(candles.count == 2)
        #expect(candles[0].time < candles[1].time)
        #expect(candles[0].open == 1611.602)
        #expect(candles[0].close == 1602.612)
        #expect(candles[1].close == 1610.0)
        #expect(candles[0].time == Date(timeIntervalSince1970: 1_716_134_400))
    }

    @Test("Parses ticker search and skips exchanges Pulse has no market for")
    func parseSearch() throws {
        let fixture = Data("""
        {
          "code": 0,
          "message": "success",
          "request_id": "c3d4e5f6",
          "data": {
            "timestamp": 1716105600000,
            "item": [
              {
                "thscode": "601318.SH",
                "ticker": "601318",
                "name": "中国平安",
                "exchange": "SH",
                "asset_type": "a-share",
                "currency": "CNY"
              },
              {
                "thscode": "510300.SH",
                "ticker": "510300",
                "name": "沪深300ETF",
                "exchange": "SH",
                "asset_type": "fund-etf",
                "currency": "CNY"
              },
              {
                "thscode": "832000.BJ",
                "ticker": "832000",
                "name": "北交所样例",
                "exchange": "BJ",
                "asset_type": "a-share",
                "currency": "CNY"
              }
            ]
          }
        }
        """.utf8)
        let results = try FuyaoProvider.parseSearch(data: fixture)
        #expect(results.count == 2)
        #expect(results[0].symbol == SymbolID(market: .sh, code: "601318"))
        #expect(results[0].name == "中国平安")
        #expect(results[0].info.type == .equity)
        #expect(results[1].symbol == SymbolID(market: .sh, code: "510300"))
        #expect(results[1].info.type == .etf)
    }

    @Test("Maps business error codes onto circuit-safe ProviderErrors")
    func errorMapping() {
        func error(code: Int) -> ProviderError {
            FuyaoProvider.providerError(code: code, message: "m", endpoint: "snapshot")
        }
        // Quota and upstream failures must trip the circuit so routing falls back.
        #expect(error(code: 4001).shouldTripCircuit)
        if case .rateLimited = error(code: 4001) {} else { Issue.record("4001 should map to rateLimited") }
        #expect(error(code: 5001).shouldTripCircuit)
        #expect(error(code: 5003).shouldTripCircuit)
        // Request-level problems must not take the source offline.
        #expect(!error(code: 1002).shouldTripCircuit)
        #expect(!error(code: 2001).shouldTripCircuit)
        #expect(!error(code: 2003).shouldTripCircuit)
        #expect(!error(code: 3001).shouldTripCircuit)
        // 2004 says this key's plan cannot use the endpoint: a request problem, not
        // a source outage, and it must not cost the user every A-share quote.
        #expect(!error(code: 2004).shouldTripCircuit)
        if case .clientError(status: 403, _) = error(code: 2004) {} else {
            Issue.record("2004 should map to clientError(403)")
        }
    }

    @Test("Business error inside an HTTP 200 body surfaces as a thrown ProviderError")
    func envelopeError() {
        let fixture = Data("""
        {"code":2003,"message":"Invalid or revoked API key","request_id":"d23e","data":null}
        """.utf8)
        #expect(throws: ProviderError.self) {
            _ = try FuyaoProvider.parseSnapshot(data: fixture)
        }
    }

    @Test("Maps only exchange-listed A-share identities, indices and boards to thscodes")
    func symbolMapping() {
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .sh, code: "600519")) == "600519.SH")
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .sz, code: "000001")) == "000001.SZ")
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .sh, code: "510300")) == "510300.SH")
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .sz, code: "159915")) == "159915.SZ")
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .sz, code: "160105")) == "160105.SZ")
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .hk, code: "700")) == nil)
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .us, code: "AAPL")) == nil)
        // Metadata, rather than a code prefix, decides unknown instruments' types.
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .sh, code: "000300")) == "000300.SH")
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .sh, code: "000688")) == "000688.SH")
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .sz, code: "510300")) == "510300.SZ")
        // Indices ride semantic identities on the index endpoints.
        #expect(FuyaoProvider.thscode(for: SymbolID(index: .shanghaiComposite)) == "000001.SH")
        #expect(FuyaoProvider.thscode(for: SymbolID(index: .shenzhenComponent)) == "399001.SZ")
        #expect(FuyaoProvider.thscode(for: SymbolID(index: .chiNext)) == "399006.SZ")
        #expect(FuyaoProvider.thscode(for: SymbolID(index: .hangSeng)) == nil)
        #expect(FuyaoProvider.thscode(for: SymbolID(index: .sp500)) == nil)
        #expect(FuyaoProvider.thscode(for: SymbolID(metal: .goldSpot)) == nil)
        let board = SectorIndexID(code: "881155", name: "银行")
        #expect(FuyaoProvider.thscode(for: SymbolID(sectorIndex: board)) == "881155.TI")
        #expect(FuyaoProvider.thscode(for: SymbolID(market: .us, code: "88ABCD")) == nil)
    }
}
