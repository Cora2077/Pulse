#if canImport(ActivityKit) && os(iOS)
// `@preconcurrency` is required, not cosmetic. Under Swift 6 language mode
// ActivityKit's `Activity` is a main-actor-isolated class while its
// `update(_:)` / `end(_:dismissalPolicy:)` are declared `@concurrent`, so every
// direct `await activity.update(...)` is rejected as "sending 'activity' risks
// causing data races". That is an SDK annotation mismatch, not a real race: the
// calls below hold the reference on the main actor and touch nothing off it.
// It reproduces on a two-line probe against the iOS 18 SDK, so it is not
// something this file can fix. Relaxing the import keeps the rest of the module
// under full strict-concurrency checking. Revisit when ActivityKit annotates
// these methods consistently; the probes are cheap to re-run.
@preconcurrency import ActivityKit
import Foundation
import OSLog

/// Everything the coordinator needs from the app, injected.
///
/// The coordinator never fetches quotes and never reads the ledger: it is given
/// a snapshot and a decision, and it drives ActivityKit. That keeps the
/// lock-screen surface incapable of becoming a second source of financial truth.
@MainActor
public protocol PulseActivityDataSource: AnyObject {
    /// Immutable identity for the next activity.
    func activityAttributes() -> PulseActivityAttributes
    /// Current display state. `nil` means "nothing displayable right now", and
    /// the coordinator will end an existing activity rather than invent one.
    func activityState(now: Date) -> PulseActivityState?
    /// Candidates for the automatic-tracking policy.
    func trackingCandidates() -> [PulseActivityCandidate]
    /// The market currently under consideration.
    func currentMarket() -> (key: String, phase: PulseMarketPhase, timeZone: TimeZone)
}

/// Receives push tokens. **This is the only way a token leaves the module.**
///
/// The coordinator never logs, prints, persists or transmits a token itself; it
/// hands the opaque bytes to one delegate and forgets them. A caller that stores
/// them is responsible for treating them as credentials.
@MainActor
public protocol PulseActivityTokenDelegate: AnyObject {
    /// Token for updating an already-running activity.
    func activityDidReceiveUpdateToken(_ token: Data, forActivityID activityID: String)
    /// Token that lets the configured service *start* an activity with no app
    /// running. Receiving it does not mean a service exists.
    func activityDidReceivePushToStartToken(_ token: Data, forAttributesType typeName: String)
    /// A previously issued token is no longer valid; the service must drop it.
    func activityDidInvalidateToken(_ token: Data)
}

/// What the coordinator can honestly claim about the current setup.
///
/// The type lives in the pure layer (`PulseTrackingPolicy.swift`) so its
/// wording is testable without ActivityKit; this file only drives it.

/// Drives Live Activity lifecycle from a foreground reconcile.
///
/// Deliberately boring: no timers, no background loops. The app calls
/// ``reconcile(now:)`` when it comes to the foreground, when the quote changes,
/// and when the user changes a tracking preference; the coordinator decides
/// create / update / end and does exactly that.
///
/// Not `@Observable`: the only observable value is ``status``, which the app
/// reads deliberately (on foreground and after a user action) rather than on
/// every render. Keeping the class macro-free keeps it compile-checkable as a
/// plain type; wrap it in an `@Observable` app-side view model if a view needs
/// to react to it.
@MainActor
public final class PulseActivityCoordinator {
    public private(set) var status: PulseActivityRuntimeStatus

    /// Tokens observed in this process, for the delegate only. Not persisted.
    private var observedTokens: Set<Data> = []

    private let dataSource: PulseActivityDataSource
    private let preferencesStore: PulseTrackingPreferenceStore
    private let staleness: PulseStalenessPolicy
    /// What the app *declares*. Only becomes the effective capability once a
    /// push-to-start token has actually been observed — see ``effectiveCapability``.
    private var declaredCapability: PulseActivityCapability
    /// A push-to-start token this process actually received. Receiving one is
    /// necessary but not sufficient to claim a working remote service; it is
    /// still the only device-side evidence that remote start is even possible.
    private var hasPushToStartToken = false
    private var observedActivityIDs: Set<String> = []
    private var programmaticallyEndedIDs: Set<String> = []
    private let logger = Logger(subsystem: "app.pulse.activity", category: "coordinator")

    private var tokenTasks: [Task<Void, Never>] = []
    private var isObservingPushStarts = false
    private var stateTask: Task<Void, Never>?

    public weak var tokenDelegate: PulseActivityTokenDelegate?
    public var onUserDismissed: (@MainActor () -> Void)?

    public init(
        dataSource: PulseActivityDataSource,
        preferencesStore: PulseTrackingPreferenceStore,
        staleness: PulseStalenessPolicy = .default,
        capability: PulseActivityCapability = .foregroundOnly
    ) {
        self.dataSource = dataSource
        self.preferencesStore = preferencesStore
        self.staleness = staleness
        self.declaredCapability = capability
        self.status = PulseActivityRuntimeStatus(
            activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            capability: Self.effectiveCapability(
                declared: capability,
                hasPushToStartToken: false
            )
        )
    }

    /// The capability this process can honestly claim right now.
    ///
    /// Delegates to ``PulseActivityCapability/effective(_:hasPushToStartToken:)``
    /// so the rule is pure and testable on macOS: a build that merely *says* it
    /// has a remote service does not get to tell the user "后台可自动开始"
    /// until ActivityKit has actually handed this process a push-to-start token.
    static func effectiveCapability(
        declared: PulseActivityCapability,
        hasPushToStartToken: Bool
    ) -> PulseActivityCapability {
        PulseActivityCapability.effective(declared, hasPushToStartToken: hasPushToStartToken)
    }

    /// Whether a remote start can actually be addressed to this device.
    public var canStartRemotely: Bool { status.capability == .remotePushConfigured }
    public var activeActivityCount: Int {
        Activity<PulseActivityAttributes>.activities.filter {
            $0.activityState != .ended && $0.activityState != .dismissed
        }.count
    }

    /// Called only after the application has separately checked its explicitly
    /// configured service. A token alone never upgrades a local-only build.
    public func setDeclaredCapability(_ capability: PulseActivityCapability) {
        declaredCapability = capability
        status.capability = Self.effectiveCapability(declared: capability,
            hasPushToStartToken: hasPushToStartToken)
    }

    /// Upgrade path for "was local-only, now a push-capable service exists":
    /// activities started without a push token can never be updated remotely,
    /// so they must be recreated with `.token`. Call from the app only after a
    /// real capability upgrade; this ends visible surfaces once by design.
    public func adoptRemotePushCapability() async {
        declaredCapability = .remotePushConfigured
        status.capability = Self.effectiveCapability(
            declared: declaredCapability, hasPushToStartToken: hasPushToStartToken)
        await endAllActivities()
    }

    // MARK: - Reconcile

    /// Bring the system's activities in line with the current decision.
    ///
    /// - Parameter isAutomatic: `true` when this reconcile was triggered by the
    ///   automatic rule rather than by an explicit user action. Automatic starts
    ///   are budgeted per session so a dismissed activity is not resurrected
    ///   repeatedly.
    ///
    /// `async` on purpose: ActivityKit's `update`/`end` are `async` and the
    /// activity object is main-actor isolated, so awaiting them here is both the
    /// correct isolation and the only way the caller learns whether the change
    /// actually landed. Nothing is detached and fired into the void.
    @discardableResult
    public func reconcile(now: Date = .now, isAutomatic: Bool = true) async -> PulseActivityStatus? {
        status.activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let preferences = preferencesStore.load()
        let market = dataSource.currentMarket()
        let sessionID = PulseActivitySession.identifier(
            marketKey: market.key,
            phase: market.phase,
            now: now,
            timeZone: market.timeZone
        )
        let decision = PulseTrackingPolicy.decide(
            context: PulseTrackingContext(
                candidates: dataSource.trackingCandidates(),
                marketPhase: market.phase,
                sessionID: sessionID,
                authorized: status.activitiesEnabled,
                capability: status.capability,
                now: now
            ),
            preferences: preferences
        )

        guard decision.shouldStart else {
            // No candidate: this is a real state change, so an activity that is
            // up must go down rather than keep showing a symbol nobody tracks.
            await endAll(decision: decision)
            return nil
        }

        // The plan is computed purely, from what is actually on screen and what
        // this session has already spent. Two things it gets right that an
        // inline `decision.primary` check did not: the budget follows the
        // instrument that will actually be shown (so keeping an incumbent never
        // charges a start), and an update to an existing activity never charges
        // one either.
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: displayedSymbolKey(),
            decision: decision,
            preferences: preferences,
            hasActivityFor: { [self] symbolKey in !currentActivities(for: symbolKey).isEmpty },
            isAutomatic: isAutomatic,
            attemptsInSession: preferencesStore.loadBudget().attempts(inSession: sessionID)
        )

        switch plan.action {
        case .budgetExhausted:
            status.lastErrorDescription = preferencesStore.loadBudget().historyUnavailable == true
                ? "自动关注计数损坏，已停止新建活动；请在设置中明确重新开启一次"
                : "本次交易时段已自动尝试多次，已停止自动开始"
            return nil
        case .none:
            await endAll(decision: decision)
            return nil
        case .update, .holdIncumbent, .start:
            break
        }

        guard let chosen = plan.primary else {
            await endAll(decision: decision)
            return nil
        }

        guard let state = dataSource.activityState(now: now) else {
            await endAll(decision: decision)
            return nil
        }

        // The state is authored for the primary the policy picked; if reconcile
        // held a different incumbent, the state must belong to it too or the
        // surfaces would show one symbol's name against another's price.
        //
        // Nothing is claimed before this check, so a mismatch costs no budget:
        // the incumbent keeps being updated and the automatic-start ledger is
        // untouched.
        guard state.primary.symbolKey == chosen.symbolKey else {
            await updateExisting(state: state.refreshed(asOf: now, staleness: staleness))
            return state.status
        }

        let refreshed = state.refreshed(asOf: now, staleness: staleness)

        // Claim the budget **before** asking the system, so a request that never
        // reports back cannot buy a second start. `claimAutomaticStart` is
        // durable, so a relaunch inside the same session still sees it and a
        // system `.ended` does not refund it. Only a real `.start` claims, and
        // only a claim that created nothing is refunded.
        var claimedSession: String?
        if plan.action == .start, plan.attemptsConsumed > 0 {
            _ = preferencesStore.claimAutomaticStart(inSession: sessionID, at: now)
            claimedSession = sessionID
        }

        let created = await apply(
            state: refreshed,
            attributes: dataSource.activityAttributes(),
            now: now,
            allowStart: plan.action == .start
        )

        // The claim bought a start that never happened (no permission, too many
        // activities, a throw before the system saw it). Give it back: that is
        // the only refund path, and it can never hand back a start that landed.
        if let claimedSession, !created {
            _ = preferencesStore.refundAutomaticStart(inSession: claimedSession, at: now)
        }

        return refreshed.status
    }

    /// End every activity for this app, e.g. because tracking was switched off.
    public func endAllActivities(now: Date = .now) async {
        for id in Activity<PulseActivityAttributes>.activities.map(\.id) {
            await endActivity(id: id, dismissalPolicy: .immediate)
        }
        status.lastChangeWasLocal = true
    }

    /// Explicitly end the activity showing `symbolKey`, if any.
    public func endActivity(symbolKey: String, dismissalPolicy: ActivityUIDismissalPolicy = .default) async {
        // `Activity` is a non-`Sendable` main-actor class, so it must not be
        // carried across the `await`. Re-resolve it from the id inside the
        // loop body, on the main actor, and await there.
        for id in currentActivities(for: symbolKey).map(\.id) {
            await endActivity(id: id, dismissalPolicy: dismissalPolicy)
        }
    }

    /// End one activity by id, re-resolving it on the main actor.
    private func endActivity(id: String, dismissalPolicy: ActivityUIDismissalPolicy) async {
        guard let activity = Activity<PulseActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        programmaticallyEndedIDs.insert(id)
        await activity.end(nil, dismissalPolicy: dismissalPolicy)
    }

    /// Bring the activity in line with the user's "pause today".
    ///
    /// Pausing ends the activity with `.immediate` — the user asked for quiet —
    /// but the *preference* is what stops it coming back; the two are stored
    /// separately for exactly that reason.
    public func pauseToday(now: Date = .now) async {
        let market = dataSource.currentMarket()
        let sessionID = PulseActivitySession.identifier(
            marketKey: market.key, phase: market.phase, now: now, timeZone: market.timeZone
        )
        _ = preferencesStore.mutate { $0.pauseToday(sessionID: sessionID, at: now) }
        await endAllActivities(now: now)
    }

    /// Undo a pause. **Only ever called from an explicit user action.**
    ///
    /// This is also the *only* path that reopens the session's automatic-start
    /// budget. A user who pressed "恢复" is asking for another attempt, so the
    /// retry is theirs to authorise; nothing automatic and no lifecycle event
    /// touches the ledger. The reopen is scoped to the current session.
    public func resumeToday(now: Date = .now) async {
        let market = dataSource.currentMarket()
        let sessionID = PulseActivitySession.identifier(
            marketKey: market.key, phase: market.phase, now: now, timeZone: market.timeZone
        )
        _ = preferencesStore.mutate { $0.resumeToday(at: now) }
        _ = preferencesStore.clearAutomaticStartBudget(sessionID: sessionID, at: now)
        await reconcile(now: now, isAutomatic: false)
    }

    // MARK: - Push tokens

    /// Start observing push-to-start and per-activity update tokens.
    ///
    /// Observation is harmless without a service, but it is also useless: the
    /// tokens are handed to ``tokenDelegate`` and never stored here. Call this
    /// from the app once it has a delegate; without a configured service the
    /// tokens should be discarded by that delegate.
    public func startObservingPushTokens(attributesType: PulseActivityAttributes.Type = PulseActivityAttributes.self) {
        guard !isObservingPushStarts else { return }
        isObservingPushStarts = true

        tokenTasks.append(Task { [weak self] in
            for await token in Activity<PulseActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                self.deliver(pushToStartToken: token, typeName: String(describing: attributesType))
            }
        })

        tokenTasks.append(Task { [weak self] in
            for await activity in Activity<PulseActivityAttributes>.activityUpdates {
                guard let self else { return }
                self.observeUpdateTokens(of: activity)
                self.observeState(of: activity)
            }
        })
        for activity in Activity<PulseActivityAttributes>.activities {
            observeUpdateTokens(of: activity)
            observeState(of: activity)
        }
    }

    /// Observe tokens and state for one activity. Called for activities created
    /// by this process and for ones discovered at launch.
    public func observeUpdateTokens(of activity: Activity<PulseActivityAttributes>) {
        guard observedActivityIDs.insert(activity.id).inserted else { return }
        if let token = activity.pushToken { deliver(updateToken: token, activityID: activity.id) }
        tokenTasks.append(Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard let self else { return }
                self.deliver(updateToken: token, activityID: activity.id)
            }
        })
    }

    /// Watch one activity's lifecycle state.
    ///
    /// Two things matter here and neither is a substitute for the other: a
    /// `.dismissed` state means the user swiped the activity away and should get
    /// the same quiet as an explicit pause for this session, and `.stale` means
    /// the surfaces are already showing an expired quote. Whether the system
    /// reports a dismissal promptly is a device-verification matter and is not
    /// assumed here — the next foreground reconcile is the backstop.
    public func observeState(of activity: Activity<PulseActivityAttributes>) {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self else { return }
                self.handle(activityState: state, activity: activity)
            }
        }
    }

    private func handle(activityState state: ActivityState, activity: Activity<PulseActivityAttributes>) {
        switch state {
        case .dismissed:
            guard !programmaticallyEndedIDs.contains(activity.id) else { return }
            // Treat as a today-pause so it is not immediately recreated; the
            // user's master switch is untouched. Scoped to the session the
            // *activity* belonged to, so a dismissal late at night cannot pause
            // a session that has not started yet.
            let now = Date()
            let market = dataSource.currentMarket()
            let sessionID = PulseActivitySession.identifier(
                marketKey: market.key, phase: market.phase, now: now, timeZone: market.timeZone
            )
            _ = preferencesStore.mutate { $0.pauseToday(sessionID: sessionID, at: now) }
            onUserDismissed?()
        case .ended:
            // Deliberately does **nothing** to the automatic-start ledger.
            //
            // The old code cleared its in-memory counter here, which meant
            // "activity reached its 8-hour limit" or "the app was relaunched"
            // both reset the budget and the activity could be re-created
            // forever, one system timeout at a time. `.ended` is a system
            // lifecycle event: the user did not ask for anything, so it grants
            // nothing. The spent budget stands for the rest of the session;
            // only an explicit ``resumeToday(now:)`` reopens it, and a new
            // session opens a fresh budget on its own.
            status.lastChangeWasLocal = false
        case .stale, .active, .pending:
            break
        @unknown default:
            break
        }
    }

    private func deliver(pushToStartToken token: Data, typeName: String) {
        guard !observedTokens.contains(token) else { return }
        observedTokens.insert(token)
        // A real token is the only device-side evidence that this installation
        // is addressable for a remote start. It upgrades the *declared*
        // capability and nothing else: it is still not proof the service will
        // deliver, and the wording never says so.
        hasPushToStartToken = true
        status.capability = Self.effectiveCapability(
            declared: declaredCapability,
            hasPushToStartToken: true
        )
        tokenDelegate?.activityDidReceivePushToStartToken(token, forAttributesType: typeName)
    }

    private func deliver(updateToken token: Data, activityID: String) {
        guard !observedTokens.contains(token) else { return }
        observedTokens.insert(token)
        tokenDelegate?.activityDidReceiveUpdateToken(token, forActivityID: activityID)
    }

    // MARK: - Apply

    /// Apply the state. Returns `true` when a start actually landed, so the
    /// caller knows whether an automatic-start claim was earned.
    ///
    /// - Parameter allowStart: `false` for a hold/update plan. The chosen
    ///   instrument is not the one on screen and creating it now would be an
    ///   unbudgeted start, so the existing surface is left alone instead.
    @discardableResult
    private func apply(
        state: PulseActivityState,
        attributes: PulseActivityAttributes,
        now: Date,
        allowStart: Bool
    ) async -> Bool {
        let content = PulseActivityContent(state: state, relevanceScore: relevance(for: state))

        if let id = currentActivities(for: state.primary.symbolKey).first?.id {
            await updateActivity(id: id, content: content)
            status.lastChangeWasLocal = true
            return false
        }

        guard allowStart else {
            // Nothing to update and not allowed to create: leave the incumbent
            // exactly as it is rather than swapping the user's surface.
            return false
        }

        // A different symbol is showing: retire it, then start the new one.
        for id in Activity<PulseActivityAttributes>.activities
            .filter({ $0.attributes.symbolKey != state.primary.symbolKey })
            .map(\.id) {
            await endActivity(id: id, dismissalPolicy: .immediate)
        }

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content.activityContent,
                pushType: declaredCapability == .remotePushConfigured && tokenDelegate != nil ? .token : nil
            )
            status.lastErrorDescription = nil
            status.lastChangeWasLocal = true
            observeUpdateTokens(of: activity)
            observeState(of: activity)
            return true
        } catch {
            // Failures here are ordinary (no permission, too many activities).
            // Recording the reason is the point: the app shows it instead of
            // pretending the island is up.
            status.lastErrorDescription = describe(error)
            status.lastChangeWasLocal = true
            return false
        }
    }

    private func updateExisting(state: PulseActivityState) async {
        let content = PulseActivityContent(state: state, relevanceScore: relevance(for: state))
        for id in currentActivities(for: state.primary.symbolKey).map(\.id) {
            await updateActivity(id: id, content: content)
        }
    }

    /// Update one activity, re-resolving it on the main actor so the
    /// non-`Sendable` `Activity` never crosses an isolation boundary.
    private func updateActivity(id: String, content: PulseActivityContent) async {
        guard let activity = Activity<PulseActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content.activityContent)
    }

    private func endAll(decision: PulseTrackingDecision) async {
        let shouldEndNow: Bool
        switch decision.eligibility {
        case .disabled, .noCandidate, .permissionDenied: shouldEndNow = true
        case .marketClosed, .pausedToday: shouldEndNow = true
        case .eligible, .remoteServiceNotConfigured: shouldEndNow = false
        }
        guard shouldEndNow else { return }
        for id in Activity<PulseActivityAttributes>.activities.map(\.id) {
            await endActivity(id: id, dismissalPolicy: .immediate)
        }
    }

    private func relevance(for state: PulseActivityState) -> Double {
        var score = state.status == .live ? 50.0 : 10.0
        if state.plans.priceConditionReachedCount > 0 { score += 30 }
        if state.plans.manualReviewCount > 0 { score += 10 }
        return min(score, 100)
    }

    private func currentActivities(for symbolKey: String) -> [Activity<PulseActivityAttributes>] {
        Activity<PulseActivityAttributes>.activities.filter { $0.attributes.symbolKey == symbolKey }
    }

    private func displayedSymbolKey() -> String? {
        Activity<PulseActivityAttributes>.activities.first?.attributes.symbolKey
    }

    /// Human-readable reason, in Chinese, for the app to show.
    private func describe(_ error: any Error) -> String {
        guard let authorization = error as? ActivityAuthorizationError else {
            return "实时活动创建失败：\(error.localizedDescription)"
        }
        return switch authorization {
        case .denied: "系统未允许实时活动"
        case .globalMaximumExceeded: "系统实时活动数量已达上限"
        case .targetMaximumExceeded: "本 App 实时活动数量已达上限"
        case .attributesTooLarge: "活动内容过大"
        case .unsupported, .unsupportedTarget: "当前系统或设备不支持该实时活动"
        case .visibility: "当前可见性不允许实时活动"
        case .persistenceFailure: "实时活动状态保存失败"
        case .unentitled: "缺少实时活动权限配置"
        case .malformedActivityIdentifier, .reconnectNotPermitted, .missingProcessIdentifier:
            "实时活动内部状态异常"
        @unknown default: "实时活动失败：\(authorization.failureReason ?? "未知原因")"
        }
    }
}
#endif
