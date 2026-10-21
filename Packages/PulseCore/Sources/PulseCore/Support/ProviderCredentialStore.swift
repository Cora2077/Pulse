import Foundation
import Security

/// Keychain persistence for per-provider BYOK credentials, one generic-password item
/// per provider id. Longbridge keeps its dedicated store because of OAuth token
/// rotation; every newer key-based source (Fuyao onward) stores its fields here.
/// Credentials grant access to the user's paid data quota, so they never touch
/// UserDefaults.
public enum ProviderCredentialStore {
    public struct KeychainFailure: Error, Sendable {
        public let status: OSStatus
    }

    private static let baseService = "app.pulse.providers"

    /// Debug and release builds must never silently consume each other's secrets.
    private static var service: String {
        switch Bundle.main.bundleIdentifier {
        case "app.pulse.mac", "app.pulse.ios": "\(baseService).release"
        case "app.pulse.mac.dev", "app.pulse.ios.dev": "\(baseService).debug"
        default: baseService
        }
    }

    public static func load(providerID: String) -> [String: String]? {
        #if os(macOS)
        // Background reads must never launch SecurityAgent, even if a caller
        // changed the process-wide policy. Query-only UI flags do not cover
        // legacy login-Keychain items on macOS.
        SecKeychainSetUserInteractionAllowed(false)
        if LocalCredentialBroker.executable != nil, providerID == "fuyao" {
            let (status, data) = LocalCredentialBroker.request("load", providerID: providerID)
            if status == errSecSuccess, let data {
                return try? JSONDecoder().decode([String: String].self, from: data)
            }
            // Preserve existing approved installations; failed legacy reads stay silent.
        }
        #endif
        var query = baseQuery(providerID: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    public static func save(_ credentials: [String: String], providerID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        #if os(macOS)
        SecKeychainSetUserInteractionAllowed(false)
        if LocalCredentialBroker.executable != nil, providerID == "fuyao" {
            let (status, _) = LocalCredentialBroker.request("save", providerID: providerID, data: data)
            guard status == errSecSuccess else { throw KeychainFailure(status: status) }
            return
        }
        #endif
        let query = baseQuery(providerID: providerID)
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

    public static func clear(providerID: String) {
        #if os(macOS)
        SecKeychainSetUserInteractionAllowed(false)
        if LocalCredentialBroker.executable != nil, providerID == "fuyao" {
            _ = LocalCredentialBroker.request("clear", providerID: providerID)
        }
        #endif
        SecItemDelete(baseQuery(providerID: providerID) as CFDictionary)
    }

    private static func baseQuery(providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(providerID)-credentials",
        ]
    }
}
