#if os(macOS)
import Foundation
import Security

/// Only the self-signed daily development app needs this fixed cdhash reader.
/// Release/iOS credentials continue to use their existing Keychain service.
enum LocalCredentialBroker {
    static var executable: URL? {
        guard Bundle.main.bundleIdentifier == "app.pulse.mac.dev" else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FFFCredentialBroker")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func request(_ operation: String, providerID: String, data: Data? = nil) -> (OSStatus, Data?) {
        guard ["load", "save", "clear"].contains(operation), (data?.count ?? 0) <= 16_384,
              let executable, providerID == "fuyao", trusted(executable) else { return (errSecAuthFailed, nil) }
        let process = Process()
        process.executableURL = executable
        process.arguments = [operation, providerID]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            if let data { input.fileHandleForWriting.write(data) }
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            let status = errors.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                return (Int32(String(data: status, encoding: .utf8) ?? "") ?? errSecAuthFailed, nil)
            }
            return (errSecSuccess, response)
        } catch { return (errSecAuthFailed, nil) }
    }

    private static func trusted(_ url: URL) -> Bool {
        var own: SecCode?, ownStatic: SecStaticCode?, helper: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecStaticCodeCreateWithPath(url as CFURL, [], &helper) == errSecSuccess, let helper,
              SecStaticCodeCheckValidity(helper, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        var ownInfo: CFDictionary?, helperInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(ownStatic, flags, &ownInfo) == errSecSuccess,
              SecCodeCopySigningInformation(helper, flags, &helperInfo) == errSecSuccess,
              let ownValues = ownInfo as? [String: Any], let helperValues = helperInfo as? [String: Any],
              helperValues[kSecCodeInfoIdentifier as String] as? String == "app.pulse.credentials.local",
              let ownCerts = ownValues[kSecCodeInfoCertificates as String] as? [SecCertificate], let ownCert = ownCerts.first,
              let helperCerts = helperValues[kSecCodeInfoCertificates as String] as? [SecCertificate], let helperCert = helperCerts.first else { return false }
        return SecCertificateCopyData(ownCert) as Data == SecCertificateCopyData(helperCert) as Data
    }
}
#endif
