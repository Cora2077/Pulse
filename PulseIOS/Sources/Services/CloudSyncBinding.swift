import Foundation
import PulseCore
import PulseSync

private struct UnconfiguredIPhoneTransport: SnapshotTransport {
    func fetch() async throws -> RemoteSnapshotRecord {
        throw SnapshotTransportError.notConfigured(reason: "此构建未配置已授权的 CloudKit 容器")
    }
    func save(_ document: SnapshotDocument, expecting expectedRevision: UUID?) async throws {
        throw SnapshotTransportError.notConfigured(reason: "此构建未配置已授权的 CloudKit 容器")
    }
}

@MainActor
final class IPhoneCloudSyncBinding {
    private let controller: AppSnapshotSyncController
    init(app: IPhoneAppState) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("app.pulse.ios", isDirectory: true)
            .appendingPathComponent(app.isDemo ? "AcceptanceSync" : "SnapshotSync", isDirectory: true)
        let id = (Bundle.main.object(forInfoDictionaryKey: "FFFCloudKitContainerIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configured = !app.isDemo && !id.isEmpty && !id.hasPrefix("$(")
        let transport: any SnapshotTransport = configured
            ? try CloudKitSnapshotTransport(containerIdentifier: id, workingDirectory: root.appendingPathComponent("Assets"))
            : UnconfiguredIPhoneTransport()
        let coordinator = try SnapshotCoordinator(directory: root.appendingPathComponent("Queue"), transport: transport)
        controller = try AppSnapshotSyncController(store: app.watchlist, coordinator: coordinator,
            metadataDirectory: root.appendingPathComponent("Applied"), isConfigured: configured)
        controller.onStateChanged = { [weak app, weak controller] in
            guard let app, let controller else { return }
            app.syncStatus = controller.statusText
            app.syncConflict = controller.conflict
            app.confirmedPlanRevision = controller.confirmedRevision?.uuidString
            app.confirmedPlanAt = controller.confirmedAt
        }
        controller.onRemoteApplied = { [weak app] in Task { await app?.refresh() } }
    }
    func start() { controller.start() }
    func localChange(_ snapshot: WatchlistSyncSnapshot) { controller.localChange(snapshot) }
    func synchronize() { controller.synchronize() }
    func keepLocal() { controller.resolveKeepingLocal() }
    func acceptRemote() { controller.resolveAcceptingRemote() }
}
