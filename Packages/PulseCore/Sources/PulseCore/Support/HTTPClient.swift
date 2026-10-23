import Foundation

/// Lightweight HTTP wrapper: unified User-Agent, timeout, and error semantics.
public struct HTTPClient: Sendable {
    public var session: URLSession
    public var defaultHeaders: [String: String]

    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    public init(session: URLSession? = nil, defaultHeaders: [String: String] = [:]) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.httpAdditionalHeaders = nil
            self.session = URLSession(configuration: config)
        }
        self.defaultHeaders = defaultHeaders
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        try await perform(URLRequest(url: url), headers: headers)
    }

    /// Form-encoded POST. Some official endpoints (the Shanghai Gold Exchange's
    /// history file) only answer to one.
    public func post(
        _ url: URL,
        form: [String: String],
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            form.map { "\($0.key)=\(Self.formEncoded($0.value))" }
                .sorted()
                .joined(separator: "&")
                .utf8
        )
        return try await perform(request, headers: headers)
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Detects the small set of HTML shells these endpoints serve when a WAF
    /// intercepts them, without treating every HTML error page as one.
    static func looksLikeEdgeBlock(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count < 8_192 else { return false }
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        guard head.contains("html") || head.hasPrefix("<") else { return false }
        return head.contains("waf") || head.contains("501page")
            || head.contains("blocked") || head.contains("access denied")
    }

    private func perform(_ base: URLRequest, headers: [String: String]) async throws -> Data {
        var request = base
        let url = request.url
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in defaultHeaders { request.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            // A WAF often answers 200 with an interstitial HTML page instead of
            // JSON. It is a refusal, not an empty result: callers must not cache
            // it as "this symbol has no data".
            if Self.looksLikeEdgeBlock(data) {
                throw ProviderError.sourceRefused(detail: "edge block page from \(url?.host ?? "?")")
            }
            return data
        case 429: throw ProviderError.rateLimited
        case 501, 502, 503, 504:
            // Edge/WAF refusals land here; they say nothing about the instrument.
            throw ProviderError.sourceRefused(detail: "HTTP \(http.statusCode) from \(url?.host ?? "?")")
        case 400..<500: throw ProviderError.clientError(status: http.statusCode,
                                                        detail: "HTTP \(http.statusCode) for \(url?.host ?? "?")")
        default: throw ProviderError.badResponse("HTTP \(http.statusCode) for \(url?.host ?? "?")")
        }
    }
}
