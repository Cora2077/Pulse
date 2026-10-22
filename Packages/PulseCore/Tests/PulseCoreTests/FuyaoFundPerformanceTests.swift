import Foundation
import Testing
@testable import PulseCore

@Suite("Fuyao fund performance: units, ranks and partial failure")
struct FuyaoFundPerformanceTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)
    private func data(_ string: String) -> Data { Data(string.utf8) }

    // 真实形状：`returns` 的键是 return_*/peer_average_*/rank_*，值都是百分数原值。
    private var returnsBody: Data {
        data(#"""
        {"code":0,"data":{"timestamp":1784131200000,"item":[{
          "return_month":-3.33,"return_tmonth":0.03,"return_hyear":0.19,"return_year":19.66,
          "return_tyear":28.69,"return_fyear":1.77,"return_nowyear":2.49,"return_now":121.58,
          "peer_average_year":12.4,"rank_year":12,"rank_total_year":480,
          "peer_average_month":-2.1,"rank_month":300,"rank_total_month":480
        }]}}
        """#)
    }

    // 回撤全为负值：取绝对值会丢掉方向。
    private var drawdownBody: Data {
        data(#"""
        {"code":0,"data":{"timestamp":1786690800000,"item":[{
          "thscode":"510300.SH","ticker":"510300",
          "week":-1.2,"month":-3.6,"tmonth":-6.8,"hyear":-9.1,
          "year":-12.5,"twoyear":-18.4,"tyear":-21.7,"fyear":-28.9,
          "nowyear":-7.3,"now":-31.2
        }]}}
        """#)
    }

    private var navBody: Data {
        data(#"""
        {"code":0,"data":{"timestamp":1784131200000,"item":[
          {"nav_date":1752595200000,"unit_nav":4.0713,"adj_nav":4.512},
          {"nav_date":1752681600000,"unit_nav":4.1015,"adj_nav":4.545}
        ]}}
        """#)
    }

    // MARK: - 解析

    @Test("Returns keep percent values as-is and pair ranks with their totals")
    func parsesReturns() throws {
        let (values, ranks) = try FuyaoProvider.parseFundReturns(data: returnsBody)
        // 百分数原值：19.66 就是 +19.66%，不乘 100 也不除 100。
        #expect(values["return_year"] == 19.66)
        #expect(values["peer_average_year"] == 12.4)
        #expect(ranks["rank_year"] == 12)
        #expect(ranks["rank_total_year"] == 480)
        // 未出现的周期不产生键。
        #expect(values["return_week"] == nil)
        #expect(ranks["rank_week"] == nil)
    }

    @Test("Drawdowns keep their negative sign")
    func parsesDrawdowns() throws {
        let values = try FuyaoProvider.parseFundDrawdowns(data: drawdownBody)
        #expect(values["year"] == -12.5)
        #expect(values["now"] == -31.2)
        // 负数原样保留，不取绝对值。
        #expect(values.values.allSatisfy { $0 < 0 })
    }

    @Test("Nav points stay ascending and keep both bases distinct")
    func parsesNavs() throws {
        let navs = try FuyaoProvider.parseFundNavs(data: navBody)
        #expect(navs.count == 2)
        #expect(navs[0].date < navs[1].date)
        #expect(navs[0].unitNav == 4.0713)
        #expect(navs[0].adjustedNav == 4.512)
    }

    @Test("A nav row missing every value is dropped, not zeroed")
    func dropsEmptyNavRow() throws {
        let body = data(#"""
        {"code":0,"data":{"item":[
          {"nav_date":1752595200000,"unit_nav":null,"adj_nav":null},
          {"nav_date":1752681600000,"unit_nav":4.1015}
        ]}}
        """#)
        let navs = try FuyaoProvider.parseFundNavs(data: body)
        #expect(navs.count == 1)
        #expect(navs[0].unitNav == 4.1015)
        // 未请求 adj 时该字段缺失，读出来是 nil 而不是 0。
        #expect(navs[0].adjustedNav == nil)
    }

    // MARK: - 组合语义

    @Test("Periods merge returns, peer averages, ranks and drawdowns by window")
    func mergesWindows() throws {
        let (values, ranks) = try FuyaoProvider.parseFundReturns(data: returnsBody)
        let drawdowns = try FuyaoProvider.parseFundDrawdowns(data: drawdownBody)
        let period = FuyaoPerformancePeriod(
            window: .year,
            returnPercent: values[FuyaoPerformanceWindow.year.returnKey],
            peerAveragePercent: values[FuyaoPerformanceWindow.year.peerAverageKey],
            rank: ranks[FuyaoPerformanceWindow.year.rankKey],
            rankTotal: ranks[FuyaoPerformanceWindow.year.rankTotalKey],
            drawdownPercent: drawdowns[FuyaoPerformanceWindow.year.drawdownKey]
        )
        #expect(period.returnPercent == 19.66)
        #expect(period.peerAveragePercent == 12.4)
        #expect(period.exceedsPeer == true)
        #expect(period.rank == 12)
        #expect(period.drawdownPercent == -12.5)
        // 12 / 480 → 前 2.5%。
        #expect(abs((period.rankPercentile ?? 0) - 2.5) < 1e-9)
    }

    @Test("Exceeding peer is unknown when either side is missing")
    func exceedsPeerNeedsBoth() {
        let missingPeer = FuyaoPerformancePeriod(
            window: .year, returnPercent: 5, peerAveragePercent: nil,
            rank: nil, rankTotal: nil, drawdownPercent: nil)
        #expect(missingPeer.exceedsPeer == nil)
        let shortfall = FuyaoPerformancePeriod(
            window: .year, returnPercent: 5, peerAveragePercent: 8,
            rank: nil, rankTotal: nil, drawdownPercent: nil)
        #expect(shortfall.exceedsPeer == false)
    }

    @Test("Rank percentile is unknown when the rank is outside the total")
    func rankPercentileBounds() {
        let invalid = FuyaoPerformancePeriod(
            window: .year, returnPercent: nil, peerAveragePercent: nil,
            rank: 500, rankTotal: 480, drawdownPercent: nil)
        #expect(invalid.rankPercentile == nil)
        let noTotal = FuyaoPerformancePeriod(
            window: .year, returnPercent: nil, peerAveragePercent: nil,
            rank: 3, rankTotal: nil, drawdownPercent: nil)
        #expect(noTotal.rankPercentile == nil)
    }

    @Test("Empty periods are dropped and order is fixed by window, not by payload")
    func periodOrderAndFiltering() {
        func period(_ window: FuyaoPerformanceWindow, ret: Double?, dd: Double?) -> FuyaoPerformancePeriod {
            .init(window: window, returnPercent: ret, peerAveragePercent: nil,
                  rank: nil, rankTotal: nil, drawdownPercent: dd)
        }
        let performance = FuyaoFundPerformance(
            thscode: "510300.SH",
            periods: [
                period(.year, ret: 19.66, dd: -12.5),
                period(.week, ret: nil, dd: nil),        // 全空 → 丢弃
                period(.month, ret: -3.33, dd: -3.6),
                period(.tyear, ret: nil, dd: -21.7)      // 只有回撤 → 保留
            ],
            navs: [], fetchedAt: now
        )
        // 顺序按 week/month/.../tyear，而不是按传入顺序。
        #expect(performance.nonEmptyPeriods.map(\.window) == [.month, .year, .tyear])
    }

    @Test("All three endpoints failing is an error, not a successful empty answer")
    func allFailedIsError() async {
        let handle = FuyaoFundStub.install(status: 503, bodies: ["{\"code\":5003,\"message\":\"unavailable\"}"])
        let provider = FuyaoProvider(apiKey: "synthetic", http: handle.http,
                                     pacing: .init(minInterval: 0, sleepsWhenPaced: false), now: { now })
        await #expect(throws: ProviderError.self) {
            try await provider.fundPerformance(for: SymbolID(market: .sh, code: "510300"))
        }
        // 三个端点都应尝试过：失败不该在第一个就静默返回空。
        #expect(handle.urls.count == 3)
    }

    @Test("A single failing endpoint keeps the other two results")
    func partialFailureKeepsRest() async throws {
        // 收益端点返回业务错误，回撤与净值正常。
        let handle = FuyaoFundStub.install(status: 200, bodies: [
            "{\"code\":5002,\"message\":\"timeout\"}",
            #"{"code":0,"data":{"item":[{"year":-12.5}]}}"#,
            #"{"code":0,"data":{"item":[{"nav_date":1752681600000,"unit_nav":4.1015,"adj_nav":4.545}]}}"#
        ])
        let provider = FuyaoProvider(apiKey: "synthetic", http: handle.http,
                                     pacing: .init(minInterval: 0, sleepsWhenPaced: false), now: { now })
        let result = try await provider.fundPerformance(for: SymbolID(market: .sh, code: "510300"))
        // 收益失败被记录，但回撤与净值照常返回。
        #expect(result.errors["区间收益"] != nil)
        #expect(result.errors["最大回撤"] == nil)
        #expect(result.errors["净值"] == nil)
        #expect(result.mostRecentNav?.unitNav == 4.1015)
        #expect(result.period(.year)?.drawdownPercent == -12.5)
        #expect(result.hasData)
    }

    // MARK: - 格式化

    @Test("Percent formatting never rescales: 19.66 prints as 19.66%")
    func percentFormatting() {
        #expect(FuyaoPerformanceFormat.percent(19.66) == "19.66%")
        #expect(FuyaoPerformanceFormat.percent(-3.33) == "-3.33%")
        #expect(FuyaoPerformanceFormat.percent(nil) == "—")
        // 回撤保留负号。
        #expect(FuyaoPerformanceFormat.drawdown(-12.5) == "-12.5%")
        #expect(FuyaoPerformanceFormat.nav(4.0713) == "4.0713")
        #expect(FuyaoPerformanceFormat.rank(12, 480) == "12 / 480")
        #expect(FuyaoPerformanceFormat.rank(3, nil) == "第 3")
        #expect(FuyaoPerformanceFormat.rank(nil, 480) == "—")
    }
}

/// 按调用顺序回放响应体的极简 stub，用于验证三个端点的失败隔离。
private final class FuyaoFundStub: URLProtocol, @unchecked Sendable {
    private struct Plan {
        var bodies: [String]
        var status: Int
        var urls: [URL] = []
        var cursor = 0
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [String: Plan] = [:]
    private static let tokenHeader = "X-Pulse-Fund-Perf-Test"

    struct Handle {
        let token: String
        let http: HTTPClient
        var urls: [URL] {
            FuyaoFundStub.lock.lock(); defer { FuyaoFundStub.lock.unlock() }
            return FuyaoFundStub.plans[token]?.urls ?? []
        }
    }

    static func install(status: Int, bodies: [String]) -> Handle {
        let token = UUID().uuidString
        lock.lock(); plans[token] = Plan(bodies: bodies, status: status); lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FuyaoFundStub.self]
        return Handle(token: token,
                      http: HTTPClient(session: URLSession(configuration: config),
                                       defaultHeaders: [tokenHeader: token]))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: Self.tokenHeader) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        Self.lock.lock()
        var plan = Self.plans[token] ?? Plan(bodies: [], status: 200)
        if let url = request.url { plan.urls.append(url) }
        let body = plan.bodies.isEmpty ? "" : plan.bodies[min(plan.cursor, plan.bodies.count - 1)]
        plan.cursor += 1
        Self.plans[token] = plan
        let status = plan.status
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
