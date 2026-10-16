import Foundation

/// A deterministic park point for `InMemorySnapshotTransport`.
///
/// The transport is used by tests that need a call to be *provably* suspended
/// inside an `await` before they perform a competing action. A caller installs
/// a gate, starts a coordinator call in a task, waits for the gate to report
/// that the stage was entered, then acts and finally opens the gate.
///
/// Every wait is on a continuation, never a sleep, so the resulting
/// interleaving is caused by the test's own ordering rather than by timing.
/// When no gate is installed the transport behaves exactly as before, so
/// production-like preview code pays nothing.
///
/// All waits carry a timeout: a gate whose `parkAt` stage disagrees with the
/// stage a test waits on fails loudly after the timeout instead of hanging the
/// whole suite forever.
public actor TransportGate {
    /// Where a parked call is waiting.
    public enum Stage: Sendable {
        case fetch
        case save
    }

    private let parkedStage: Stage
    /// True once `open()` has been called.
    private var isOpen = false
    /// Continuations waiting for the gate to open, keyed so a timeout can
    /// remove exactly its own waiter.
    private var openWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Continuations waiting for their requested stage to be entered.
    private var enterWaiters: [UUID: (Stage, CheckedContinuation<Bool, Never>)] = [:]
    private var hasBeenEntered = false
    private var enteredStage: Stage?

    /// Creates a gate that parks the first call reaching `parkedStage`.
    ///
    /// A test must construct the gate with the same stage it later passes to
    /// `waitUntilEntered`; a mismatch is reported as a timeout, not a hang.
    public init(parkAt parkedStage: Stage = .save) {
        self.parkedStage = parkedStage
    }

    /// Suspends the caller until the gate opens, if this is the parked stage.
    ///
    /// Called from inside the transport, so the call is genuinely in flight
    /// while it waits here. If nobody opens the gate within `timeout` the call
    /// is released anyway, so a broken test degrades into a failure instead of
    /// wedging every later test.
    func park(_ stage: Stage, timeout: TimeInterval = 30) async {
        guard stage == parkedStage, !isOpen else { return }
        hasBeenEntered = true
        enteredStage = stage
        // Only waiters parked on *this* stage are released; a waiter for a
        // different stage is a test bug and must time out, not be released
        // into a scenario that never happened.
        let matched = enterWaiters.filter { $0.value.0 == stage }
        for id in matched.keys { enterWaiters.removeValue(forKey: id) }
        for (_, waiter) in matched { waiter.1.resume(returning: true) }
        guard !isOpen else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
                return
            }
            openWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.releaseOpenWaiter(id)
            }
        }
    }

    private func releaseOpenWaiter(_ id: UUID) {
        guard let waiter = openWaiters.removeValue(forKey: id) else { return }
        waiter.resume()
    }

    /// Waits until a call has parked here at `stage`.
    ///
    /// - Returns: `true` when the stage was genuinely entered, `false` when the
    ///   wait timed out — which means the gate was configured for a different
    ///   stage and the intended interleaving never happened. Tests must treat
    ///   `false` as a failure, because proceeding would silently test nothing.
    @discardableResult
    public func waitUntilEntered(_ stage: Stage, timeout: TimeInterval = 10) async -> Bool {
        if hasBeenEntered, enteredStage == stage { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            if hasBeenEntered, enteredStage == stage {
                continuation.resume(returning: true)
                return
            }
            enterWaiters[id] = (stage, continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expireEnterWaiter(id)
            }
        }
    }

    private func expireEnterWaiter(_ id: UUID) {
        guard let waiter = enterWaiters.removeValue(forKey: id) else { return }
        waiter.1.resume(returning: false)
    }

    /// Releases the parked call. Safe to call more than once.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for (_, waiter) in waiters { waiter.resume() }
    }

    /// True once a call has parked, so a test can assert that the interleaving
    /// it intended actually happened instead of silently testing nothing.
    public var didPark: Bool { hasBeenEntered }
}
