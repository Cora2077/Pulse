import Foundation
import PulseCore
import PulseSync

/// Explicit opt-in only. Merely building the iPhone target never migrates the
/// user's Mac or grants its local development signature iCloud privileges.
@MainActor
final class MacCloudSyncBinding {
    let controller: AppSnapshotSyncController
    private var polling: Task<Void, Never>?
    init(store: WatchlistStore, containerID: String) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.pulse.mac")
            .appendingPathComponent("PrivateCloudSync", isDirectory: true)
        let transport = try CloudKitSnapshotTransport(containerIdentifier: containerID,
            workingDirectory: root.appendingPathComponent("Assets"))
        let coordinator = try SnapshotCoordinator(directory: root.appendingPathComponent("Queue"), transport: transport)
        controller = try AppSnapshotSyncController(store: store, coordinator: coordinator,
            metadataDirectory: root.appendingPathComponent("Applied"), isConfigured: true)
    }
    func start(store: WatchlistStore) {
        store.onLocalSyncChange = { [weak controller] snapshot in controller?.localChange(snapshot) }
        controller.start()
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                self.controller.synchronize()
            }
        }
    }
}
