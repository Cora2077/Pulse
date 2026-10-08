import Foundation
import Security

/// Keychain persistence for the MCP bearer token. The token grants read/write
/// access to the user's watchlists and positions, so it never touches UserDefaults.
enum MCPTokenStore {
    struct KeychainFailure: Error {
        let status: OSStatus
    }

    private static let baseService = "app.pulse.mcp"
    private static let account = "bearer"

    /// Debug and release builds must never silently consume each other's secrets.
    private static var service: String {
        switch Bundle.main.bundleIdentifier {
        case "app.pulse.mac": "\(baseService).release"
        case "app.pulse.mac.dev": "\(baseService).debug"
        default: baseService
        }
    }

    static func loadOrCreate(
        read: () throws -> String? = load,
        generate: () throws -> String = generateToken,
        persist: (String) throws -> Void = save
    ) throws -> String {
        if let token = try read() { return token }
        let token = try generate()
        try persist(token)
        return token
    }

    /// The new token is persisted before being returned, so a crash mid-rotation
    /// can never leave the Keychain holding a token nobody was ever shown.
    static func rotate() throws -> String {
        let token = try generateToken()
        try save(token)
        return token
    }

    static func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try decodeRead(status: status, data: result as? Data)
    }

    static func decodeRead(status: OSStatus, data: Data?) throws -> String? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw KeychainFailure(status: errSecDecode)
        }
        return token
    }

    private static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainFailure(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainFailure(status: updateStatus)
        }
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// A running endpoint already holds its bearer token. Reuse that same value
/// for settings and restarts, and do not turn a denied read into a prompt loop.
@MainActor
final class MCPTokenSession {
    private let read: () throws -> String
    private let rotateStored: () throws -> String
    private var result: Result<String, Error>?

    init(read: @escaping () throws -> String = { try MCPTokenStore.loadOrCreate() },
         rotate: @escaping () throws -> String = MCPTokenStore.rotate) {
        self.read = read
        self.rotateStored = rotate
    }

    func current() throws -> String {
        if let result { return try result.get() }
        let loaded = Result(catching: read)
        result = loaded
        return try loaded.get()
    }

    func retryAfterFailure() {
        if case .failure = result { result = nil }
    }

    func rotate() throws -> String {
        let token = try rotateStored()
        result = .success(token)
        return token
    }
}
