# PulseSync — integration guide

`Packages/PulseSync` is a Swift 6 package providing the durable, conflict-explicit
synchronization foundation for Mac and iPhone. It depends only on `PulseCore` by
path and owns no application state.

The Lead owns `project.yml`, the app targets and all application wiring. This
document is the contract for that wiring.

- Platforms: iOS 18, macOS 14
- Dependency: `.package(path: "../PulseCore")`, product `PulseCore` → `PulseSync`
- Verified: `swift build` clean for both macOS and `arm64-apple-ios18.0`,
  zero warnings under `-strict-concurrency=complete`

## What this package does and does not claim

**Does:** keeps one whole `WatchlistSyncSnapshot` revisioned, atomically
committed, durable across crashes, and never silently overwritten.

**Does not:** claim that iCloud access works. `CloudKitSnapshotTransport` is
compiled and its CloudKit call paths are real, but it has **never been run
against a real account** in this environment — no real CloudKit request,
signing or account access was performed while building it. Whether the user is
signed in, whether the container identifier is correct, whether their private
database is reachable and whether their quota allows the write are knowable only
from a real request's actual result. Surface the real `CKError`; do not report
"iCloud ready" from configuration alone.

## The model in one paragraph

A `SnapshotDocument` is one revision of the entire snapshot. It carries its own
`revision`, the `parentRevision` it was derived from, and a stable `operationID`
identifying the user operation that produced it. A `SnapshotTransport` is a
compare-and-swap remote: `save(_:expecting:)` commits only if the remote still
holds the expected revision. `SnapshotCoordinator` is an actor that persists a
baseline and any uncommitted local snapshot in a caller-supplied directory, and
reports conflicts instead of resolving them.

## Public API

```swift
// The revisioned payload.
public struct SnapshotDocument: Sendable, Equatable, Codable {
    public var revision: UUID
    public var parentRevision: UUID?      // nil == created from nothing
    public var operationID: UUID          // stable across retries
    public var createdAt: Date
    public var snapshot: WatchlistSyncSnapshot
}

// What a local edit claims about the revision it was derived from.
public enum SnapshotParentExpectation: Sendable, Equatable {
    case currentBaseline   // freeze the baseline as it is at enqueue time
    case exact(UUID?)      // explicit claim; .exact(nil) == "the remote was empty"
}

public protocol SnapshotTransport: Sendable {
    func fetch() async throws -> RemoteSnapshotRecord
    func save(_ document: SnapshotDocument, expecting expectedRevision: UUID?) async throws
}

public struct RemoteSnapshotRecord: Sendable, Equatable {
    public var document: SnapshotDocument?   // nil == remote never written
    public var changeToken: String?          // opaque; e.g. recordChangeTag
}

public enum SnapshotTransportError: Error, Sendable, Equatable {
    case notConfigured(reason: String)   // never auto-retried
    case offline(reason: String)         // retryable — the only retryable case
    case conflict(current: RemoteSnapshotRecord, reason: String)
    case corruptRemote(reason: String)   // never auto-retried, never overwritten
    case rejected(reason: String)        // never auto-retried
    public var isRetryable: Bool
}

public enum SyncOutcome: Sendable, Equatable {
    case pushed(SnapshotDocument)
    case alreadyUpToDate(remote: SnapshotDocument?)
    case conflict(ConflictReport)
    case remoteAvailable(SnapshotDocument)
    case inSync(remote: SnapshotDocument?)
    case failed(SyncFailure)
}

public enum ConflictResolution: Sendable, Equatable {
    case keepLocal                              // rebase local content, keep it
    case acceptRemote                           // explicitly discard local pending
    case replaceLocal(with: WatchlistSyncSnapshot)  // commit a caller's merge
}

public actor SnapshotCoordinator {
    public init(directory: URL, transport: SnapshotTransport) throws

    public func setTransport(_ transport: SnapshotTransport)
    public func currentBaseline() -> SnapshotDocument?
    public func currentPending() -> SnapshotDocument?
    public func mostRecentFailure() -> SyncFailure?
    public var workingDirectory: URL

    @discardableResult
    public func enqueueLocalChange(
        snapshot: WatchlistSyncSnapshot,
        operationID: UUID = UUID(),
        parentExpectation: SnapshotParentExpectation,
        createdAt: Date = .now
    ) throws -> SnapshotDocument

    // Compatibility overload: `parentRevision: nil` keeps its historical
    // meaning of `.currentBaseline`; a non-nil value means `.exact(_:)`.
    @discardableResult
    public func enqueueLocalChange(
        snapshot: WatchlistSyncSnapshot,
        operationID: UUID = UUID(),
        parentRevision: UUID? = nil,
        createdAt: Date = .now
    ) throws -> SnapshotDocument

    public func synchronize() async -> SyncOutcome
    @discardableResult public func pushPending() async -> SyncOutcome
    @discardableResult
    public func commit(
        snapshot: WatchlistSyncSnapshot,
        operationID: UUID = UUID(),
        parentExpectation: SnapshotParentExpectation
    ) async throws -> SyncOutcome
    @discardableResult
    public func commit(
        snapshot: WatchlistSyncSnapshot,
        operationID: UUID = UUID(),
        parentRevision: UUID? = nil
    ) async throws -> SyncOutcome
    @discardableResult
    public func resolveConflict(_ resolution: ConflictResolution) async throws -> SyncOutcome
    public func discardPendingChange() throws
    public func peekRemote() async throws -> SnapshotDocument?

    public init(directory: URL, transport: SnapshotTransport) throws  // throws on unreadable state
}

public enum CoordinatorError: Error, Equatable, LocalizedError {
    case operationIDReusedWithDifferentContent(operationID: UUID)
}
```

## Required application wiring

### 1. A dedicated directory per device

The coordinator needs its own directory. Do not hand it a shared, generic or
user-visible folder.

```swift
func syncDirectory(bundleIdentifier: String) throws -> URL {
    let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
    )
    let directory = support
        .appendingPathComponent(bundleIdentifier, isDirectory: true)
        .appendingPathComponent("SnapshotSync", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
```

The transport's asset directory must likewise be its own, separate from the
coordinator's state directory:

```swift
let assetDirectory = directory.appendingPathComponent("assets", isDirectory: true)
```

### 2. Constructing the transport performs no network work

`CloudKitSnapshotTransport.init` only stores the identifier and creates a
`CKContainer` handle. It is safe at launch. It performs **no** network request,
so constructing it never proves the container works.

```swift
import PulseSync
import CloudKit

let transport: SnapshotTransport
if let containerID = settings.cloudKitContainerIdentifier, !containerID.isEmpty {
    transport = try CloudKitSnapshotTransport(
        containerIdentifier: containerID,          // explicit, caller-supplied
        workingDirectory: assetDirectory,
        databaseScope: .private
    )
} else {
    // Not configured is a real, distinct state. Do not fabricate a default
    // container identifier from entitlements.
    transport = UnconfiguredSnapshotTransport()
}
let coordinator = try SnapshotCoordinator(directory: syncDirectory, transport: transport)
```

`UnconfiguredSnapshotTransport` is yours to write: it throws
`.notConfigured(reason:)` from both methods. The coordinator turns that into
`SyncFailure.Kind.configuration`.

Only `#if canImport(CloudKit)` platforms can use `CloudKitSnapshotTransport`;
the file is guarded so the package still builds elsewhere.

### 3. Pushing a local edit

Enqueue on the same operation ID every time you retry the *same* user action;
generate a new ID for a new edit.

**Freeze the parent at edit time, not at enqueue time.** If the UI records a
local change while a `synchronize()` fetch may still be in flight, capture the
revision your UI actually applied when the user made the edit and pass it as
`.exact(frozenRevision)` (or `.exact(nil)` when the remote was empty at that
moment). The coordinator will then *refuse* the push with a conflict if the
confirmed base has moved past that frozen revision — instead of silently
re-parenting the user's edit onto content they never saw:

```swift
// At the moment the user commits the edit in the UI, freeze what was applied:
let frozenParent = coordinator.currentBaseline()?.revision   // may be nil

// Later, possibly after an in-flight fetch returned and advanced the baseline:
let outcome = try await coordinator.commit(
    snapshot: store.syncSnapshot(),
    operationID: editOperationID,            // stored with the draft, reused on retry
    parentExpectation: .exact(frozenParent)
)

switch outcome {
case .pushed(let doc):
    // Safe to clear the draft; doc.revision is now the remote revision.
case .failed(let failure):
    // Keep the draft. failure.kind == .transient means retrying is correct.
    // failure.kind == .unknown with a "could not be persisted" message means
    // the local state write failed — the draft/pending change is intact and
    // the in-memory state was NOT advanced past what the disk holds.
case .conflict(let report):
    presentConflict(report)          // requires an explicit user choice
case .remoteAvailable(let doc):
    applyRemote(doc)
case .alreadyUpToDate:
    break
case .inSync:
    break
}
```

### 4. Applying a remote snapshot

`synchronize()` returns the remote document; it never applies it for you.
Apply through the existing store API, which performs its own checks:

```swift
func applyRemote(_ document: SnapshotDocument) {
    // applySyncSnapshot is the existing checked entry point. Do not write
    // snapshot fields directly.
    if store.applySyncSnapshot(document.snapshot) {
        // store persisted it; the coordinator already recorded the baseline.
    }
}
```

### 5. Handling a conflict

**Never auto-resolve.** A reported conflict means two devices diverged. The
local pending snapshot is intact and the remote is untouched, so presenting the
choice costs nothing.

```swift
func presentConflict(_ report: ConflictReport) {
    // report.remote          — what the other device has
    // report.localPending    — what this device has, still queued and safe
    // report.localBaseline   — the common ancestor, for a three-way merge
    //
    // Offer: keep mine / take theirs / merge.
}

// "Keep mine":
_ = try await coordinator.resolveConflict(.keepLocal)

// "Take theirs":
_ = try await coordinator.resolveConflict(.acceptRemote)

// A real three-way merge, using the existing PulseCore merge:
// The merge result must be validated before use; resolveValidated does that.
if case .conflict(let report) = outcome,
   let local = report.localPending, let remote = report.remote.document {
    let merge = WatchlistSyncMerge.merge(
        base: report.localBaseline?.snapshot ?? local.snapshot,
        local: local.snapshot,
        remote: remote.snapshot
    )
    if merge.isConflictFree {
        let merged = try WatchlistSyncMerge.resolveValidated(merge, choosing: .local)
        _ = try await coordinator.resolveConflict(.replaceLocal(with: merged))
    } else {
        // Still conflicted: ask the user per conflict, then replaceLocal with
        // the result. Do not commit a snapshot whose conflicts are unresolved.
    }
}
```

### 6. Sync on launch and on foreground

```swift
func syncNow() async {
    switch await coordinator.synchronize() {
    case .remoteAvailable(let doc):
        applyRemote(doc)
    case .conflict(let report):
        presentConflict(report)
    case .failed(let failure):
        show(failure)                 // .configuration needs settings, not retry
    case .alreadyUpToDate, .inSync, .pushed:
        break
    }
}
```

## Guarantees and the reasoning behind them

**No silent overwrite.** A local pending snapshot is cleared only by a confirmed
commit, `acceptRemote`, `keepLocal` succeeding, `replaceLocal`, or the explicitly
named `discardPendingChange()`. No error path clears it.

**Reentrancy safety.** The coordinator is an actor: a local edit can be enqueued
while a `pushPending` save or a `synchronize` fetch is suspended at the network
`await`. An acknowledgement is only ever applied to the exact document it
confirms — a newer edit enqueued mid-flight is never cleared by an older ack,
and `synchronize()` never commits a change it did not see when it started (a
mid-flight edit stays durable pending for your explicit push path).

**Honest parents.** `pushPending()` compares the pending document's recorded
`parentRevision` against the last confirmed base *before* any network write. A
mismatch is an explicit `.conflict`, never a silent re-label of the parent and
never an overwrite of a newer remote revision. The compare-and-swap expectation
sent to the transport is always the pending document's own `parentRevision`.

**Honest persistence.** Every durable-state write is `try`, never `try?`. If a
state write fails, the outcome is `.failed` (kind `.unknown`), the in-memory
state is left describing what the disk actually holds, and the pending change is
kept. A commit that landed remotely but whose acknowledgement could not be
persisted is *not* reported as pushed; the next `synchronize()` settles it
through the lost-confirmation path (same operation ID, same content).

**Explicit conflict, no LWW.** If the remote revision is not the revision the
local change descends from, `synchronize()` returns `.conflict` and stops. There
is no automatic merge and no last-writer-wins.

**Atomic commits.** One record, one asset, one document. A commit is whole or
absent; there is no state in which trades landed but plans did not.

**Honest retries.** Reusing an operation ID counts as already-committed only when
the content matches too. Same ID with different content throws
`CoordinatorError.operationIDReusedWithDifferentContent` — it is a caller bug,
and treating it as idempotent would silently drop the second edit.

**Crash recovery.** State is written with `Data.write(options: .atomic)` *before*
each network attempt, so a restart recovers an unsent change with its original
operation ID and bytes. A state file from a newer build throws rather than being
guessed at.

**Validation is not bypassed.** Every snapshot is checked with
`WatchlistSyncWireCodec.encode` and `LocalBackupStore.validateSnapshot` before
being queued and again immediately before being sent. A remote snapshot is
validated before it is applied and is never overwritten if it fails.

**Same price and size, different transaction ID = two facts.** Nothing in the
sync path keys or deduplicates transactions by value; identity is always the
transaction's own `id`.

## CloudKit transport specifics

- **One record** (`PulseSyncSnapshot` / `pulse-sync-snapshot-v1`) in the
  **private** database, holding the snapshot as a single `CKAsset`. One record
  gives batch atomicity and one `recordChangeTag` for compare-and-swap; an asset
  keeps the record within size limits.
- **Optimistic concurrency**: `save` reads the current record, compares the
  stored `revision` field against the expected revision, then saves with
  `.ifServerRecordUnchanged`. `serverRecordChanged` is mapped to a real
  `.conflict` carrying the server record.
- **Per-record results are inspected.** `modifyRecords` reports failures
  per record and only throws for the whole batch, so a rejected save would
  otherwise look like success.
- **Materialize before overwrite.** `save` fully decodes any existing record —
  revision, operation ID, parent revision and the asset payload — before
  deciding anything. A record that cannot be read back consistently is
  reported as `.corruptRemote` and is never silently replaced; no identity is
  ever fabricated for a missing field. A `serverRecordChanged` race whose
  server record fails to decode is likewise corruption, not a mergeable
  conflict and not "empty remote".
- **Asset hygiene**: the asset file is written only inside the transport's own
  directory, and removal is gated on a structural ownership check (absolute,
  resolved, direct child of that directory, matching filename prefix). Any
  `remove`/`move` is preceded by that check plus a non-empty path guard. Files
  CloudKit materializes for a fetched asset are only ever read, never moved or
  deleted.
- **Error honesty**: `.notAuthenticated`/`.badContainer`/`.missingEntitlement`
  map to `.notConfigured`, not to a retryable `.offline`. A retry cannot sign a
  user in.

## Testing

The suite uses `InMemorySnapshotTransport` (a real CAS actor) and isolated
temporary directories. No test touches the network, CloudKit or real app data;
the CloudKit tests exercise only the pure record↔document mapping and error
classification with locally constructed `CKRecord` values. Disk-write failures
are injected through a test-only hook in the state store, not through
filesystem permission tricks.

```bash
cd Packages/PulseSync
swift test --scratch-path /tmp/fff-ios-sync-build
```

51 tests in 7 suites cover: first create and two-device revision exchange,
concurrent first-create race, offline retry without duplication, lost
confirmation settling, same-ID-different-content refusal (locally and when the
remote claims the ID), pending and baseline survival across restart,
unsupported state version, remote conflict not overwriting local pending, all
three explicit resolutions, same-price/same-size distinct transactions,
validation before send, whole-snapshot atomicity, corrupt remote not
overwritten, configuration-vs-transient classification, the state store's
atomicity and path-ownership rules, actor reentrancy (an edit enqueued
mid-fetch or mid-save survives the older ack and the baseline tracks only the
confirmed document), explicit parent expectations (`.exact(nil)` conflicting
with an appeared remote or an existing baseline, stale parents refused before
any network write), persistence-failure honesty on enqueue, on push
acknowledgement and during synchronize, and the CloudKit metadata mapping and
error classification.

> **Environment note for the Lead:** `swift build`/`swift test` in this sandbox
> fail with `sandbox-exec: sandbox_apply: Operation not permitted` while
> compiling the package manifest — this affects the unmodified `PulseCore`
> package identically, so it is environmental, not caused by this package. It is
> worked around with `--disable-sandbox`. Do not treat that flag as part of the
> build contract; on an unrestricted machine the plain command works.
