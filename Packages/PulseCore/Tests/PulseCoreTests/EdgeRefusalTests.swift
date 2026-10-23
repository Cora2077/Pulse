import Foundation
import Testing
@testable import PulseCore

@Suite("An edge refusal is not an empty result")
struct EdgeRefusalTests {
    private func body(_ text: String) -> Data { Data(text.utf8) }

    @Test("A WAF interstitial is recognised, ordinary JSON is not")
    func recognisesBlockPage() {
        let waf = #"<!DOCTYPE html><html><head><script>window.location.href="https://waf.tencent.com/501page.html?u=x"</script></head></html>"#
        #expect(HTTPClient.looksLikeEdgeBlock(body(waf)))
        #expect(!HTTPClient.looksLikeEdgeBlock(body(#"{"code":0,"data":{}}"#)))
        #expect(!HTTPClient.looksLikeEdgeBlock(Data()))
        // A large legitimate HTML page is not a block page.
        #expect(!HTTPClient.looksLikeEdgeBlock(body(String(repeating: "<p>x</p>", count: 2_000))))
    }

    @Test("A refusal is not a verdict about the instrument and retries the circuit")
    func refusalSemantics() {
        let refused = ProviderError.sourceRefused(detail: "HTTP 501 from web.ifzq.gtimg.cn")
        #expect(refused.shouldTripCircuit, "an edge block is a source failure, not a request problem")
        #expect(ProviderError.shouldTrip(refused))
        // A request-level error still must not take the whole source offline.
        #expect(!ProviderError.clientError(status: 403, detail: "x").shouldTripCircuit)
    }

    @Test("The chart says the source refused instead of claiming no data")
    @MainActor
    func messageIsDistinct() {
        let refused = RefreshEngine.candleFailureMessage(ProviderError.sourceRefused(detail: "x"))
        #expect(refused.contains("拒绝"))
        #expect(refused != RefreshEngine.candleFailureMessage(ProviderError.symbolNotFound(SymbolID(market: .sh, code: "600519"))))
    }
}
