import Foundation
import Observation
import Security
import PulseActivity

struct PushSessionWindow: Codable, Sendable {
    var id: String
    var start: String
    var end: String
    var autoStart = true
}

@MainActor
@Observable
final class IPhonePushBridgeClient {
    private(set) var endpointText: String
    private(set) var statusText = "后台推送未配置"
    private(set) var liveReady = false
    private(set) var isConfigured = false
    private(set) var quoteSourceMode = "unknown"
    var isConfigurable: Bool { allowsRemoteConfiguration }
    var onConfigurationChanged: (() -> Void)?
    private let defaults: UserDefaults
    private let allowsRemoteConfiguration: Bool
    private let deviceID: String
    private var startToken: Data?
    private var updateToken: Data?
    private var activityID: String?
    private let keychainService: String
    private var lastSentDigest: Data?
    private let networkSession = URLSession(configuration: .ephemeral,
        delegate: PushNoRedirectDelegate(), delegateQueue: nil)

    init(defaults: UserDefaults, allowsRemoteConfiguration: Bool = true) {
        self.defaults = defaults
        self.allowsRemoteConfiguration = allowsRemoteConfiguration
        endpointText = defaults.string(forKey: "ios.push.endpoint") ?? ""
        let id = defaults.string(forKey: "ios.push.deviceID") ?? UUID().uuidString
        deviceID = id
        defaults.set(id, forKey: "ios.push.deviceID")
        keychainService = (Bundle.main.bundleIdentifier ?? "app.pulse.ios") + ".private-push-bridge"
        // No Keychain read or network at initialization.
        isConfigured = allowsRemoteConfiguration
            && defaults.bool(forKey: "ios.push.userConfigured") && !endpointText.isEmpty
    }
    func saveConfiguration(endpoint: String, bearer: String) throws {
        guard allowsRemoteConfiguration else { throw PushClientError.configurationUnavailable }
        let newEndpoint = try Self.endpoint(endpoint)
        if isConfigured, try Self.endpoint(endpointText) != newEndpoint {
            throw PushClientError.revokeFirst
        }
        if bearer.isEmpty && ((try? Self.endpoint(endpointText)) != newEndpoint || endpointText.isEmpty) {
            throw PushClientError.invalidCredential
        }
        if !bearer.isEmpty {
            guard bearer.count >= 32 else { throw PushClientError.invalidCredential }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService, kSecAttrAccount as String: "bearer"]
            let bytes = Data(bearer.utf8)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query
                insert[kSecValueData as String] = bytes
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw PushClientError.keychain }
            } else if status != errSecSuccess { throw PushClientError.keychain }
        }
        guard try readBearer() != nil else { throw PushClientError.invalidCredential }
        endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(endpointText, forKey: "ios.push.endpoint")
        defaults.set(true, forKey: "ios.push.userConfigured")
        isConfigured = true; liveReady = false; lastSentDigest = nil
        statusText = "配置已保存到本机，尚未核对服务"
        onConfigurationChanged?()
    }
    func checkStatus() async {
        do {
            let response = try await request("GET", path: "/v1/status")
            liveReady = response["deliveryReady"] as? Bool == true && response["mode"] as? String == "live"
            quoteSourceMode = response["quoteSource"] as? String ?? "unknown"
            statusText = Self.serviceDescription(deliveryReady: liveReady, quoteSource: quoteSourceMode)
        } catch { liveReady = false; statusText = error.localizedDescription }
        onConfigurationChanged?()
    }
    func receivePushToStartToken(_ token: Data) { startToken = token; lastSentDigest = nil }
    func receiveUpdateToken(_ token: Data, activityID: String) {
        updateToken = token; self.activityID = activityID; lastSentDigest = nil
    }
    func invalidateToken(_ token: Data) {
        if startToken == token { startToken = nil }
        if updateToken == token { updateToken = nil; activityID = nil }
        lastSentDigest = nil
    }
    func register(attributes: PulseActivityAttributes, state: PulseActivityState,
                  windows: [PushSessionWindow], enabled: Bool, pauseUntil: Date?) async {
        guard isConfigured else { return }
        guard let startToken, !windows.isEmpty, windows.count <= 8 else {
            statusText = "尚未取得远程启动令牌，或没有已授权交易时窗"; return
        }
        guard state.primary.price.isFinite, state.primary.price > 0,
              state.quoteSourceTime <= Date.now.addingTimeInterval(60) else {
            statusText = "行情状态未通过推送前校验"; return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var c = encoder.singleValueContainer()
                try c.encode(["encoding": "unixSeconds", "value": String(date.timeIntervalSince1970)])
            }
            // Explicit input clock tags; ActivityKit's output clock remains the
            // server's default-Codable wire contract, not a custom system decoder.
            var template = try JSONSerialization.jsonObject(with: encoder.encode(state)) as! [String: Any]
            Self.normalizeTaggedDates(&template)
            var primary = template["primary"] as! [String: Any]
            if primary["sourceDelay"] == nil { primary["sourceDelay"] = NSNull() }
            if primary["changePercent"] == nil { primary["changePercent"] = NSNull() }
            template["primary"] = primary
            let attrs = try JSONSerialization.jsonObject(with: JSONEncoder().encode(attributes))
            let windowObjects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(windows))
            var body: [String: Any] = ["attributes": attrs, "template": template,
                "pushToStartToken": ["kind": "pushToStart", "base64": startToken.base64EncodedString()],
                "enabled": enabled, "windows": windowObjects]
            if let updateToken { body["updateToken"] = ["kind": "update", "base64": updateToken.base64EncodedString()] }
            if let activityID { body["activityID"] = activityID }
            if let pauseUntil { body["pauseUntil"] = ISO8601DateFormatter().string(from: pauseUntil) }
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            guard data != lastSentDigest else { return }
            let response = try await request("PUT", path: "/v1/registrations/\(deviceID)", body: data)
            lastSentDigest = data
            quoteSourceMode = response["quoteSource"] as? String ?? quoteSourceMode
            if response["quoteRefreshable"] as? Bool == true {
                statusText = "已注册，支持独立行情刷新 · 不代表推送已到达设备"
            } else if quoteSourceMode == "client" {
                statusText = "已注册，但行情依赖手机快照，无法持续后台刷新"
            } else {
                statusText = "已注册，但未确认当前标的的独立刷新能力 · 不代表推送已到达"
            }
        } catch { statusText = error.localizedDescription }
    }
    func updatePolicy(enabled: Bool, pauseUntil: Date?) async {
        guard isConfigured else { return }
        do {
            var body: [String: Any] = ["enabled": enabled]
            if let pauseUntil { body["pauseUntil"] = ISO8601DateFormatter().string(from: pauseUntil) }
            else { body["pauseUntil"] = NSNull() }
            _ = try await request("POST", path: "/v1/registrations/\(deviceID)/pause",
                body: JSONSerialization.data(withJSONObject: body))
            statusText = enabled ? "远程关注策略已更新" : "远程自动关注已关闭"
            lastSentDigest = nil
        } catch { statusText = error.localizedDescription }
    }
    func revoke() async {
        guard isConfigured else { return }
        do {
            _ = try await request("DELETE", path: "/v1/registrations/\(deviceID)")
            liveReady = false; lastSentDigest = nil
            isConfigured = false
            defaults.set(false, forKey: "ios.push.userConfigured")
            statusText = "远程活动注册已撤销"
        } catch { statusText = error.localizedDescription }
        onConfigurationChanged?()
    }
    private func readBearer() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "bearer",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let bytes = item as? Data else { throw PushClientError.keychain }
        return String(data: bytes, encoding: .utf8)
    }
    private func request(_ method: String, path: String, body: Data? = nil) async throws -> [String: Any] {
        guard let bearer = try readBearer() else { throw PushClientError.invalidCredential }
        let base = try Self.endpoint(endpointText)
        let url = base.appendingPathComponent(String(path.dropFirst()))
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await networkSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PushClientError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PushClientError.badResponse }
        return object
    }
    static func serviceDescription(deliveryReady: Bool, quoteSource: String) -> String {
        guard deliveryReady else { return "服务可达，但处于演练或未配置完成状态" }
        switch quoteSource {
        case "public": return "服务可推送，已启用公开行情适配 · 真机到达尚未验证"
        case "client": return "服务可推送，但行情依赖手机上传，无法持续后台刷新"
        case "none": return "服务可推送，但未启用独立行情源"
        default: return "服务可推送，但未报告独立行情能力 · 真机到达尚未验证"
        }
    }
    static func endpoint(_ raw: String) throws -> URL {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil, components.path.isEmpty || components.path == "/",
              let url = components.url else { throw PushClientError.endpoint }
        var allowed = components.scheme == "https"
        #if DEBUG
        allowed = allowed || components.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
        #endif
        guard allowed else { throw PushClientError.endpoint }
        return url
    }
    private static func normalizeTaggedDates(_ object: inout [String: Any]) {
        for (key, value) in object {
            if var nested = value as? [String: Any] {
                if nested["encoding"] as? String == "unixSeconds", let text = nested["value"] as? String,
                   let number = Double(text), number.isFinite { nested["value"] = number }
                else { normalizeTaggedDates(&nested) }
                object[key] = nested
            }
        }
    }
}

private final class PushNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // credentials must never follow a server redirect
    }
}

private enum PushClientError: LocalizedError {
    case endpoint, invalidCredential, keychain, badResponse, revokeFirst, configurationUnavailable, http(Int)
    var errorDescription: String? {
        switch self {
        case .endpoint: "请填写有效的 HTTPS 服务根地址；调试版本仅允许本机 HTTP。"
        case .invalidCredential: "本机尚未保存有效的服务访问凭据，请在设置中配置，勿发送到聊天。"
        case .keychain: "无法读写此 App 自己的钥匙串项，未注册远程活动。"
        case .badResponse: "服务响应格式不正确，未确认注册成功。"
        case .revokeFirst: "切换服务器前请先撤销旧服务注册，再填写新服务自己的访问凭据。"
        case .configurationUnavailable: "验收演示环境禁止配置远程服务；此环境不会读取钥匙串或发送请求。"
        case .http(let code): "服务请求未完成（HTTP \(code)），未假报推送成功。"
        }
    }
}
