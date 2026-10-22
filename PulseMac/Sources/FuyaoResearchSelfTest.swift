#if DEBUG
import AppKit
import Foundation
import SwiftUI
import PulseCore

private final class ResearchMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var failNews = false
    nonisolated(unsafe) static var failEvents = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let fail = Self.failNews
        let failEventsNow = Self.failEvents
        Self.lock.unlock()
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = query.first { $0.name == "thscode" || $0.name == "thscodes" || $0.name == "q" }?.value ?? "600519.SH"
        let body: String
        if url.path.contains("tickers/search") {
            body = "{\"code\":0,\"data\":{\"item\":[{\"thscode\":\"\(code)\",\"name\":\"合成股票\",\"asset_type\":\"a-share\"}]}}"
        } else if url.path.contains("timeline-list") {
            body = fail ? "{\"code\":2004,\"message\":\"unavailable\"}"
                : "{\"code\":0,\"data\":{\"items\":[{\"id\":\"\(code)-1\",\"title\":\"合成新闻：\(code)\",\"summary\":\"用于验证标的隔离与原生渲染的合成内容。\",\"source\":\"测试来源\",\"publish_time_ms\":1792454400000,\"jump_url\":\"https://example.org/news\"}]}}"
        } else if url.path.contains("anomaly-analysis") {
            body = "{\"code\":0,\"data\":{\"timestamp\":1792454400000,\"item\":[{\"thscode\":\"\(code)\",\"stock_name\":\"合成股票\",\"analysis_content\":\"合成解读：行业消息受到关注，具体影响仍需核实。\",\"keyword_list\":[\"合成主题\"],\"tag_name\":\"大涨\"}]}}"
        } else if url.path.contains("dragon-tiger-list") {
            body = """
            {"code":0,"data":{"timestamp":1792483200000,"board_type":"all","trade_date":"2026-10-19",
              "count":3,"stock_count":2,
              "stock_items":[
                {"thscode":"600519.SH","ticker":"600519","name":"合成股票","change":0.0277,
                 "net_value":-45246913.56,"net_rate":-0.0113,"org_net_value":1234567.89,
                 "org_net_rate":0.004,"org_buy_num":3,"org_sell_num":1,"range_days":1},
                {"thscode":"600519.SH","ticker":"600519","name":"合成股票","change":0.0512,
                 "net_value":-88000000,"range_days":3},
                {"thscode":null,"ticker":"301139","name":"合成退市","change":0.026,
                 "net_value":559311.15,"range_days":1}
              ],
              "hot_money_items":[{"name":"合成游资","buying":1200000,
                "rows":[{"thscode":"600519.SH","ticker":"600519","name":"合成股票","range_days":1,"net_value":800000}]}]}}
            """
        } else if url.path.contains("abnormal-monitor-list") {
            body = """
            {"code":0,"data":{"item":[
              {"thscode":"600519.SH","name":"合成股票","start_date_ms":1791734400000,"end_date_ms":null,
               "monitor_type":1,"monitor_label":"严重异动"}
            ],"pagination":{"page":1,"size":30,"total":1,"has_next":false}}}
            """
        } else if url.path.contains("corporate-actions") {
            // The endpoint echoes the requested code; the fixture does the same so a
            // mismatch check cannot pass by accident.
            body = failEventsNow
                ? "{\"code\":2004,\"message\":\"client only\"}"
                : "{\"code\":0,\"data\":{\"thscode\":\"\(code)\",\"item\":[{\"ticker\":\"\(code.prefix(6))\",\"ex_date_ms\":1766073600000,\"dividend_per_share\":23.957,\"per_share_bonus\":0}]}}"
        } else if url.path.contains("rank-trend") {
            body = "{\"code\":0,\"data\":{\"timestamp\":1791849600000,\"item\":[{\"thscode\":\"\(code)\",\"date_ms\":1792368000000,\"rank\":120},{\"thscode\":\"\(code)\",\"date_ms\":1792454400000,\"rank\":25}]}}"
        } else {
            body = "{\"code\":0,\"data\":{\"timestamp\":1792454400000,\"item\":[{\"thscode\":\"600519.SH\",\"name\":\"合成股票\",\"rank\":25,\"rank_change\":12,\"rank_trend\":\"up\"}]}}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(fail: Bool = false, failEvents: Bool = false) {
        lock.lock(); count = 0; failNews = fail; Self.failEvents = failEvents; lock.unlock()
    }
    static func requests() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
enum FuyaoResearchSelfTest {
    static func run() async -> Bool {
        guard CommandLine.arguments.contains("--main-window-demo") else {
            print("PULSE_RESEARCH_SELFTEST failed: isolated demo required")
            return false
        }
        var failures: [String] = []
        func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResearchMockProtocol.self]
        let provider = FuyaoProvider(apiKey: "synthetic-only", http: HTTPClient(session: URLSession(configuration: config)))
        let controller = FuyaoResearchController(provider: provider, available: { true })
        let first = SymbolID(market: .sh, code: "600519")
        let second = SymbolID(market: .sz, code: "000001")
        ResearchMockProtocol.reset()
        async let a: Void = controller.loadIntelligence(first)
        async let b: Void = controller.loadIntelligence(first)
        _ = await (a, b)
        expect(ResearchMockProtocol.requests() == 5, "shared load must make one meta and four research requests")
        expect(controller.intelligence[first]?.news?.value.first?.id == "600519.SH-1", "news identity")
        expect(controller.intelligence[first]?.ranking?.dataTime == controller.intelligence[first]?.ranking?.value.last?.date, "rank freshness")
        let requests = ResearchMockProtocol.requests()
        await controller.loadIntelligence(first)
        expect(ResearchMockProtocol.requests() == requests, "cache must avoid duplicate network")
        await controller.loadIntelligence(second)
        expect(controller.intelligence[second]?.news?.value.first?.id == "000001.SZ-1", "switch must isolate news")
        expect(controller.intelligence[first]?.news?.value.first?.id == "600519.SH-1", "switch must retain original symbol")
        let renderState = controller.intelligence[first] ?? .init()
        ResearchMockProtocol.reset(fail: true)
        await controller.loadIntelligence(first, force: true)
        expect(controller.intelligence[first]?.errors["新闻"] != nil, "news permission failure visible")
        expect(controller.intelligence[first]?.anomalies != nil, "partial failures must keep anomaly results")
        expect(controller.intelligence[first]?.news != nil, "refresh failure must retain dated prior news")
        let pending = Task { await controller.loadIntelligence(second, force: true) }
        await Task.yield()
        controller.reset()
        await pending.value
        expect(controller.intelligence.isEmpty, "reset must block late publication")
        // 龙虎榜：区间分组、可空身份、命中判定、监控 null 语义。
        let flow = FuyaoDragonTigerController(provider: provider, available: { true })
        ResearchMockProtocol.reset()
        await flow.load(board: .all)
        let day = flow.days[.all]?.day
        expect(day?.recordCount == 3, "dragon tiger record count")
        expect(day?.stockCount == 2, "dragon tiger stock count")
        // 同一股票的当日榜与三日榜是两条记录，不能被合并。
        expect(day?.stockRows.filter { $0.ticker == "600519" }.count == 2, "same stock keeps both ranges")
        expect(day?.rowsByRange[.day]?.count == 2, "one-day board grouping")
        expect(day?.rowsByRange[.threeDay]?.count == 1, "three-day board grouping")
        // thscode 为 null 的行保留但没有身份。
        let anonymous = day?.stockRows.first { $0.ticker == "301139" }
        expect(anonymous != nil, "null thscode row kept")
        expect(anonymous?.symbol == nil, "null thscode has no identity")
        // 命中判定只认当日榜。
        expect(flow.watchHits(board: .all, symbols: [first]).count == 1, "watch hit uses one-day board")
        // 榜单缓存：重复加载不再请求。
        let afterBoard = ResearchMockProtocol.requests()
        await flow.load(board: .all)
        expect(ResearchMockProtocol.requests() == afterBoard, "board cache avoids repeat fetch")
        // 游资榜与全部榜是两份缓存。
        await flow.load(board: .hotMoney)
        expect(flow.days[.hotMoney]?.day?.hotMoneyRows.count == 1, "hot money board cached separately")
        // 监控：end_date 缺失表示仍在监控，不是数据丢失。
        await flow.loadMonitors()
        let monitor = flow.monitors[.current]?.page?.records.first
        expect(monitor?.isOngoing == true, "nil end date means still monitored")
        expect(flow.monitors[.current]?.page?.ongoing.count == 1, "ongoing count")
        expect(flow.monitorHits(symbols: [first]).count == 1, "monitor hit by symbol")
        // 取消后回写。
        let flowEpoch = flow.epoch
        let pendingFlow = Task { await flow.load(board: .org, force: true) }
        await Task.yield()
        flow.reset()
        expect(flow.epoch > flowEpoch, "flow reset bumps epoch")
        await pendingFlow.value
        expect(flow.days[.org] == nil, "cancelled board load must not publish")
        do { try FuyaoResearchAcceptance.renderCapitalFlow() }
        catch { failures.append("capital flow render: \(error.localizedDescription)") }

        // 除权：缓存、覆盖、失败保留、取消回写。
        let events = FuyaoCorporateActionsController(provider: provider, available: { true }, defaults: UserDefaults(suiteName: "pulse.selftest.events") ?? .standard)
        ResearchMockProtocol.reset()
        await events.load(first)
        expect(events.series(for: first)?.actions.count == 1, "corporate action parsed")
        expect(events.series(for: first)?.actions.first?.cashPerShare == 23.957, "corporate action amount")
        let afterFirst = ResearchMockProtocol.requests()
        await events.load(first)
        expect(ResearchMockProtocol.requests() == afterFirst, "corporate actions cache avoids repeat fetch")
        // 失败必须保留上一次成功副本，只把错误标出来。
        ResearchMockProtocol.reset(failEvents: true)
        await events.load(first, force: true)
        expect(events.series(for: first)?.actions.count == 1, "failed refresh keeps prior actions")
        expect(events.entries[first]?.lastError != nil, "failed refresh marks the entry")
        // 单标的失败不该被报成整个来源失败：全景错误只留给"一条都没拿到"的情况，
        // 否则界面会把一只票的权限问题说成数据源整体不可用。
        expect(events.lastError == nil, "one symbol's failure is not a source-wide error")
        // 计划提示：除权前创建的活跃计划命中，除权后与已取消的不命中。
        let noticeEx = Date(timeIntervalSince1970: 1_766_073_600)
        let before = TradePlan(kind: .buy, price: 1200, quantity: 100, status: .active,
                               createdAt: noticeEx.addingTimeInterval(-86_400))
        let after = TradePlan(kind: .buy, price: 1200, quantity: 100, status: .active,
                              createdAt: noticeEx.addingTimeInterval(86_400))
        let cancelled = TradePlan(kind: .buy, price: 1200, quantity: 100, status: .cancelled,
                                  createdAt: noticeEx.addingTimeInterval(-86_400))
        expect(events.notice(for: before, symbol: first) != nil, "plan before ex-date is flagged")
        expect(events.notice(for: after, symbol: first) == nil, "plan after ex-date is silent")
        expect(events.notice(for: cancelled, symbol: first) == nil, "cancelled plan is silent")
        // 无缓存标的绝不提示：没有数据不等于没有除权。
        expect(events.notice(for: before, symbol: second) == nil, "no cache means no claim")
        // 取消后回写：reset 必须阻止迟到的结果落地。
        let eventsEpoch = events.epoch
        let pendingEvents = Task { await events.load(second) }
        await Task.yield()
        events.reset()
        expect(events.epoch > eventsEpoch, "reset bumps epoch")
        await pendingEvents.value
        expect(events.entries[second] == nil, "cancelled load must not publish")
        do {
            try render(FuyaoIntelligenceContent(state: renderState), name: "intelligence-light", width: 850, height: 600, scheme: .light)
            try render(FuyaoIntelligenceContent(state: renderState), name: "intelligence-narrow-dark", width: 340, height: 650, scheme: .dark)
        } catch { failures.append("native render: \(error.localizedDescription)") }
        failures += FuyaoResearchAcceptance.contextChecks()
        do { try FuyaoResearchAcceptance.renderCorporateActions() }
        catch { failures.append("corporate action render: \(error.localizedDescription)") }
        do { try FuyaoResearchAcceptance.renderIndicators() }
        catch { failures.append("indicator render: \(error.localizedDescription)") }
        do { try FuyaoResearchAcceptance.renderFundPerformance() }
        catch { failures.append("fund performance render: \(error.localizedDescription)") }
        do { try FuyaoResearchAcceptance.renderTradingDays() }
        catch { failures.append("trading days render: \(error.localizedDescription)") }
        do { try FuyaoResearchAcceptance.renderIPO() }
        catch { failures.append("ipo render: \(error.localizedDescription)") }
        do { try FuyaoResearchAcceptance.renderAdditional() }
        catch { failures.append("additional render: \(error.localizedDescription)") }
        print("PULSE_RESEARCH_SELFTEST \(failures.isEmpty ? "ok" : "failed") checks=46 failures=\(failures.joined(separator: "; "))")
        return failures.isEmpty
    }

    static func render<V: View>(_ content: V, name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fuyao-research-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let hosting = NSHostingView(rootView: ScrollView { content.padding(16) }
            .frame(width: width, height: height).environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        if CommandLine.arguments.contains("--export-render-base64") {
            print("PULSE_RESEARCH_RENDER_BASE64 \(name) \(png.base64EncodedString())")
            return
        }
        let url = directory.appendingPathComponent(name + ".png")
        try png.write(to: url)
        print("PULSE_RESEARCH_RENDER \(url.path)")
    }
}
#endif
