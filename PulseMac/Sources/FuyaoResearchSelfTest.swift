#if DEBUG
import AppKit
import Foundation
import SwiftUI
import PulseCore

private final class ResearchMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var failNews = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let fail = Self.failNews
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
    static func reset(fail: Bool = false) { lock.lock(); count = 0; failNews = fail; lock.unlock() }
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
        do {
            try render(FuyaoIntelligenceContent(state: renderState), name: "intelligence-light", width: 850, height: 600, scheme: .light)
            try render(FuyaoIntelligenceContent(state: renderState), name: "intelligence-narrow-dark", width: 340, height: 650, scheme: .dark)
        } catch { failures.append("native render: \(error.localizedDescription)") }
        failures += FuyaoResearchAcceptance.contextChecks()
        do { try FuyaoResearchAcceptance.renderAdditional() }
        catch { failures.append("additional render: \(error.localizedDescription)") }
        print("PULSE_RESEARCH_SELFTEST \(failures.isEmpty ? "ok" : "failed") checks=20 failures=\(failures.joined(separator: "; "))")
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
