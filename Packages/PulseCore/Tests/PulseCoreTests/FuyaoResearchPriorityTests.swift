import Foundation
import Testing
@testable import PulseCore

private final class ResearchPriorityProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var snapshotStarted = false
    nonisolated(unsafe) static var snapshotFinished: Date?
    nonisolated(unsafe) static var researchStarted: Date?
    static func reset() { lock.lock(); defer { lock.unlock() }; snapshotStarted = false; snapshotFinished = nil; researchStarted = nil }
    static func snapshotIsRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return snapshotStarted }
    static func times() -> (Date?, Date?) { lock.lock(); defer { lock.unlock() }; return (snapshotFinished, researchStarted) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path.contains("snapshot") {
            Self.lock.lock(); Self.snapshotStarted = true; Self.lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
                Self.lock.lock(); Self.snapshotFinished = .now; Self.lock.unlock()
                deliver(#"{"code":0,"data":{"timestamp":1792454400000,"item":[{"thscode":"600519.SH","last_price":11,"prev_price":10}]}}"#)
            }
        } else if path.contains("search") {
            deliver(#"{"code":0,"data":{"item":[{"thscode":"600519.SH","name":"A","asset_type":"a-share"}]}}"#)
        } else {
            Self.lock.lock(); Self.researchStarted = .now; Self.lock.unlock()
            deliver(#"{"code":0,"data":{"timestamp":1792454400000,"item":[]}}"#)
        }
    }
    private func deliver(_ body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Research yields to quotes", .serialized)
struct FuyaoResearchPriorityTests {
    @Test("Background research waits while a quote request is in flight")
    func quotesFirst() async throws {
        ResearchPriorityProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResearchPriorityProtocol.self]
        let provider = FuyaoProvider(apiKey: "test-only", http: HTTPClient(session: URLSession(configuration: config)),
            pacing: .init(minInterval: 0, sleepsWhenPaced: true))
        _ = try await provider.search("600519.SH")
        let quotes = Task { try await provider.quotes(for: [SymbolID(market: .sh, code: "600519")]) }
        for _ in 0..<100 {
            if ResearchPriorityProtocol.snapshotIsRunning() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ResearchPriorityProtocol.snapshotIsRunning())
        let research = Task { try await provider.hotStocks() }
        _ = try await quotes.value
        _ = try await research.value
        let times = ResearchPriorityProtocol.times()
        let finished = try #require(times.0)
        let started = try #require(times.1)
        #expect(started >= finished)
    }
}
