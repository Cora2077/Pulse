import Foundation
import Testing
import PulseCore
@testable import PulseSync

@Suite("Conflict choice is scoped to the versions a human confirmed")
struct ConflictConfirmationTests {
    @Test("A newer remote cannot be overwritten by an old keep-local confirmation")
    func remoteChangedAfterConfirmation() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("confirmation")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("initial commit failed"); return
        }
        let pending = try await coordinator.enqueueLocalChange(snapshot: Fixtures.snapshot(groupName: "local"))
        let shown = SnapshotDocument(parentRevision: base.revision, operationID: UUID(), snapshot: Fixtures.snapshot(groupName: "shown"))
        await remote.putExternally(shown)
        guard case .conflict = await coordinator.synchronize() else { Issue.record("conflict expected"); return }
        let newer = SnapshotDocument(parentRevision: shown.revision, operationID: UUID(), snapshot: Fixtures.snapshot(groupName: "newer"))
        await remote.putExternally(newer)
        let result = try await coordinator.resolveConflict(.keepLocal,
            expecting: SnapshotConflictExpectation(remoteRevision: shown.revision, pendingRevision: pending.revision))
        guard case .conflict(let updated) = result else { Issue.record("stale confirmation must refuse"); return }
        #expect(updated.remote.revision == newer.revision)
        #expect(await coordinator.currentPending()?.revision == pending.revision)
        #expect(await remote.currentDocument()?.revision == newer.revision)
    }
}
