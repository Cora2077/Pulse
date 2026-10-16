import XCTest
@testable import FFFiPhone

final class PushConfigurationTests: XCTestCase {
    @MainActor
    func testSnapshotOnlyServiceCannotBeDescribedAsIndependentBackgroundQuotes() {
        let snapshot = IPhonePushBridgeClient.serviceDescription(deliveryReady: true, quoteSource: "client")
        XCTAssertTrue(snapshot.contains("依赖手机"))
        XCTAssertTrue(snapshot.contains("无法持续后台刷新"))
        let publicSource = IPhonePushBridgeClient.serviceDescription(deliveryReady: true, quoteSource: "public")
        XCTAssertTrue(publicSource.contains("尚未验证"))
        XCTAssertFalse(publicSource.contains("已到达"))
        XCTAssertTrue(IPhonePushBridgeClient.serviceDescription(deliveryReady: false, quoteSource: "public").contains("演练"))
    }

    @MainActor
    func testCredentialsCanNeverBePlacedInEndpointOrFollowAnInsecureRemoteScheme() throws {
        for raw in ["https://name:secret@example.invalid", "https://example.invalid/?key=value", "https://example.invalid/#fragment", "https://example.invalid/path", "http://example.invalid", "file:///tmp/push"] {
            XCTAssertThrowsError(try IPhonePushBridgeClient.endpoint(raw))
        }
        XCTAssertEqual(try IPhonePushBridgeClient.endpoint("https://example.invalid").host, "example.invalid")
    }

    @MainActor
    func testUnknownEndpointCannotReuseAnUnrelatedPersistedKeychainCredential() {
        let defaults = UserDefaults(suiteName: "app.pulse.push-config-test.\(UUID())")!
        let client = IPhonePushBridgeClient(defaults: defaults)
        XCTAssertFalse(client.isConfigured)
        // This fails before any Keychain access; no token is read or written.
        XCTAssertThrowsError(try client.saveConfiguration(endpoint: "https://example.invalid", bearer: ""))
        XCTAssertFalse(client.isConfigured)
    }

    @MainActor
    func testDemoEnvironmentCannotConfigureRemoteService() {
        let defaults = UserDefaults(suiteName: "app.pulse.push-demo-test.\(UUID())")!
        let client = IPhonePushBridgeClient(defaults: defaults, allowsRemoteConfiguration: false)
        XCTAssertFalse(client.isConfigurable)
        XCTAssertFalse(client.isConfigured)
        XCTAssertThrowsError(try client.saveConfiguration(endpoint: "https://example.invalid", bearer: "x"))
    }
}
