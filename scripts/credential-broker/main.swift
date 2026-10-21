import Foundation
import Security
import CryptoKit
import Darwin

// A standalone executable deliberately kept byte-for-byte stable between app
// rebuilds. Self-signed local apps have cdhash Keychain partitions, not team IDs.
// Authenticate the live parent before reading any input or touching credentials.
func signingInfo(_ code: SecCode) -> [String: Any]? {
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var result: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess else { return nil }
    return result as? [String: Any]
}
func authorizeParent() -> Bool {
    var own: SecCode?
    guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
          let info = signingInfo(own),
          let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let certificate = certs.first else { return false }
    let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    var parent: SecCode?
    let attrs = [kSecGuestAttributePid as String: NSNumber(value: getppid())] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &parent) == errSecSuccess, let parent else { return false }
    var requirement: SecRequirement?
    let expression = "identifier \"app.pulse.mac.dev\" and certificate leaf = H\"\(digest)\""
    guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
          let requirement,
          SecCodeCheckValidity(parent, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return false }
    return true
}
SecKeychainSetUserInteractionAllowed(false)
guard authorizeParent() else { exit(77) }
guard CommandLine.arguments.count == 3,
      ["load", "save", "clear"].contains(CommandLine.arguments[1]),
      CommandLine.arguments[2] == "fuyao" else { exit(64) }
let operation = CommandLine.arguments[1]
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "app.pulse.providers.debug.broker.v1",
    kSecAttrAccount as String: "fuyao-credentials"]
var status: OSStatus = errSecParam
switch operation {
case "load":
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data { FileHandle.standardOutput.write(data) }
case "save":
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 16_384,
          let values = try? JSONDecoder().decode([String: String].self, from: data),
          let key = values["apiKey"], !key.isEmpty else { exit(64) }
    status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var request = query
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        status = SecItemAdd(request as CFDictionary, nil)
    }
case "clear": status = SecItemDelete(query as CFDictionary)
default: break
}
// Status only, never credential bytes, on stderr.
if status != errSecSuccess { FileHandle.standardError.write(Data("\(status)".utf8)); exit(1) }
