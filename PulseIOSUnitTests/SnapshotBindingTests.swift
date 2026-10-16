import XCTest
import Foundation
import PulseCore
import PulseSync
@testable import FFFiPhone

final class SnapshotBindingTests: XCTestCase {
    @MainActor
    private func fixture(remote: InMemorySnapshotTransport) throws -> (WatchlistStore, AppSnapshotSyncController, URL) {
        let defaults = UserDefaults(suiteName: "app.pulse.binding.test.\(UUID())")!
        let store = WatchlistStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("fff-binding-\(UUID())", isDirectory: true)
        let coordinator = try SnapshotCoordinator(directory: root.appendingPathComponent("Queue"), transport: remote)
        let controller = try AppSnapshotSyncController(store: store, coordinator: coordinator,
            metadataDirectory: root.appendingPathComponent("Applied"), isConfigured: true)
        store.onLocalSyncChange = { [weak controller] in controller?.localChange($0) }
        return (store, controller, root)
    }
    private let apple = SymbolID(market: .us, code: "AAPL")
    private let microsoft = SymbolID(market: .us, code: "MSFT")
    @MainActor
    private func remoteDocument() -> SnapshotDocument {
        let defaults = UserDefaults(suiteName: "app.pulse.binding.remote.\(UUID())")!
        let store = WatchlistStore(defaults: defaults)
        store.add(SymbolInfo(symbol: microsoft, name: "测试远端标的", type: .equity))
        return SnapshotDocument(parentRevision: nil, operationID: UUID(), snapshot: store.syncSnapshot())
    }

    @MainActor
    func testEmptyInstallationPullsInsteadOfErasingRemote() async throws {
        let remote = InMemorySnapshotTransport()
        let document = remoteDocument()
        await remote.putExternally(document)
        let (store, controller, _) = try fixture(remote: remote)
        controller.start()
        await controller.waitForPendingWork()
        XCTAssertEqual(store.syncSnapshot(), document.snapshot)
        XCTAssertEqual(controller.confirmedRevision, document.revision)
        XCTAssertFalse(controller.hasPending)
        let actual = await remote.currentDocument()
        XCTAssertEqual(actual, document)
    }

    @MainActor
    func testRapidLocalSavesKeepTheirOwnAncestryAndDoNotConflictWithEachOther() async throws {
        let remote = InMemorySnapshotTransport()
        let (store, controller, _) = try fixture(remote: remote)
        controller.start()
        await controller.waitForPendingWork()
        store.add(SymbolInfo(symbol: apple, name: "测试苹果", type: .equity))
        store.add(SymbolInfo(symbol: microsoft, name: "测试微软", type: .equity))
        await controller.waitForPendingWork()
        XCTAssertNil(controller.conflict)
        XCTAssertFalse(controller.hasPending)
        let actual = await remote.currentDocument()
        XCTAssertEqual(actual?.snapshot, store.syncSnapshot())
        XCTAssertEqual(actual?.snapshot.items.count, 2)
    }

    @MainActor
    func testEditDuringFetchIsNotClobberedAndResolutionBacksUpBothSides() async throws {
        let remote = InMemorySnapshotTransport()
        let document = remoteDocument()
        await remote.putExternally(document)
        let gate = TransportGate(parkAt: .fetch)
        await remote.installGate(gate)
        let (store, controller, root) = try fixture(remote: remote)
        controller.start()
        guard await gate.waitUntilEntered(.fetch) else { XCTFail("fetch gate did not enter within its deadline"); return }
        store.add(SymbolInfo(symbol: apple, name: "测试本机标的", type: .equity))
        await gate.open()
        await controller.waitForPendingWork()
        XCTAssertNotNil(store.item(for: apple))
        XCTAssertNil(store.item(for: microsoft))
        XCTAssertNotNil(controller.conflict)
        controller.resolveKeepingLocal()
        await controller.waitForPendingWork()
        XCTAssertNil(controller.conflict)
        let actual = await remote.currentDocument()
        XCTAssertEqual(actual?.snapshot, store.syncSnapshot())
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Applied"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("conflict-") }
        XCTAssertEqual(backups.count, 1)
        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(backups.first))) as? [String: Any]
        XCTAssertNotNil(backup?["local"])
        XCTAssertNotNil(backup?["remote"])
    }
}
