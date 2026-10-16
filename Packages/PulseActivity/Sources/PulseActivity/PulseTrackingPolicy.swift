import Foundation

/// One instrument the app believes is worth tracking, as an *input* to policy.
///
/// "Held OR active plan OR pinned" is expressed here as three independent flags.
/// The policy ORs them; it never requires two of them at once.
public struct PulseActivityCandidate: Codable, Hashable, Sendable {
    public var symbolKey: String
    /// The user holds a non-zero position.
    public var held: Bool
    /// There is at least one non-stopped, non-abandoned plan for it.
    public var hasActivePlan: Bool
    /// The user explicitly pinned it as the primary.
    public var pinned: Bool
    /// The user has this many things to act on for it (crossed price condition,
    /// manual condition awaiting review). Drives priority, not qualification.
    public var actionablePlanCount: Int

    public init(
        symbolKey: String,
        held: Bool = false,
        hasActivePlan: Bool = false,
        pinned: Bool = false,
        actionablePlanCount: Int = 0
    ) {
        self.symbolKey = symbolKey
        self.held = held
        self.hasActivePlan = hasActivePlan
        self.pinned = pinned
        self.actionablePlanCount = max(0, actionablePlanCount)
    }

    /// The rule, in one place: any one of the three is enough.
    public var qualifies: Bool { held || hasActivePlan || pinned }
}

/// Why automatic tracking is or is not allowed to start right now.
///
/// Every case is reported to the user as-is; none of them silently turns into
/// "it will just work".
public enum PulseTrackingEligibility: String, Codable, Hashable, Sendable {
    /// Everything checks out for an automatic start.
    case eligible
    /// The user turned automatic tracking off. Stays off until they turn it on.
    case disabled
    /// The user paused *today*. Restores itself next trading day.
    case pausedToday
    /// The relevant market has no session running.
    case marketClosed
    /// The app has no permission to start activities.
    case permissionDenied
    /// Nothing in the account qualifies.
    case noCandidate
    /// This device cannot do the remote part: activities can only be created and
    /// updated while the app is in the foreground. Never reported as success.
    case remoteServiceNotConfigured

    public var isEligible: Bool { self == .eligible }
}

/// A candid description of what the device can actually do.
public enum PulseActivityCapability: String, Codable, Hashable, Sendable {
    /// The app is running and can create/update activities itself.
    case foregroundOnly
    /// A remote service is configured and its credentials are present.
    case remotePushConfigured
    /// A remote service is configured but this build cannot reach it.
    case remotePushUnavailable

    /// The capability a process may honestly claim, given what it *declares*
    /// and the only device-side evidence that remote start is possible.
    ///
    /// Declaration alone is not enough. A build can compile in the remote path
    /// and still have no addressable device: until ActivityKit has handed this
    /// process a push-to-start token, no remote start can be targeted at it, so
    /// ``remotePushConfigured`` degrades to ``foregroundOnly``. This is the
    /// gate that stops "we wrote the push code" from being reported to the user
    /// as "you will be tracked in the background".
    ///
    /// A token is necessary but **not sufficient**: it proves the device is
    /// addressable, not that APNs accepts our key or that a delivery will land.
    /// The token can only ever gate the declaration down; it can never upgrade a
    /// genuinely foreground-only build.
    public static func effective(_ declared: PulseActivityCapability, hasPushToStartToken: Bool) -> PulseActivityCapability {
        switch declared {
        case .foregroundOnly, .remotePushUnavailable:
            declared
        case .remotePushConfigured:
            hasPushToStartToken ? .remotePushConfigured : .foregroundOnly
        }
    }
}

/// Inputs a caller must supply. `now` is injected; nothing here reads the clock.
public struct PulseTrackingContext: Hashable, Sendable {
    public var candidates: [PulseActivityCandidate]
    /// Market phase for the session being considered.
    public var marketPhase: PulseMarketPhase
    /// Stable identifier of the session (market + trading day + leg), so a
    /// "today pause" is scoped to one session rather than to a wall-clock date.
    public var sessionID: String
    /// Whether the app currently holds activity permission.
    public var authorized: Bool
    public var capability: PulseActivityCapability
    public var now: Date

    public init(
        candidates: [PulseActivityCandidate],
        marketPhase: PulseMarketPhase,
        sessionID: String,
        authorized: Bool,
        capability: PulseActivityCapability = .foregroundOnly,
        now: Date
    ) {
        self.candidates = candidates
        self.marketPhase = marketPhase
        self.sessionID = sessionID
        self.authorized = authorized
        self.capability = capability
        self.now = now
    }
}

/// The decision, with the reason attached so the UI can explain itself.
public struct PulseTrackingDecision: Hashable, Sendable {
    public var eligibility: PulseTrackingEligibility
    /// The chosen primary. `nil` unless ``eligibility`` is `.eligible`.
    public var primary: PulseActivityCandidate?
    /// Other qualifying instruments, ordered, for the expanded view's context.
    public var others: [PulseActivityCandidate]
    /// The session this decision was made for.
    public var sessionID: String
    /// True when this decision may only be applied while the app is in the
    /// foreground. A caller that ignores this is claiming background success it
    /// does not have.
    public var foregroundOnly: Bool

    public var shouldStart: Bool { eligibility == .eligible && primary != nil }

    public init(
        eligibility: PulseTrackingEligibility,
        primary: PulseActivityCandidate? = nil,
        others: [PulseActivityCandidate] = [],
        sessionID: String,
        foregroundOnly: Bool
    ) {
        self.eligibility = eligibility
        self.primary = primary
        self.others = others
        self.sessionID = sessionID
        self.foregroundOnly = foregroundOnly
    }
}

/// What a reconcile should do to the system's activities, decided purely.
///
/// This is the part of the coordinator that has to be reviewable without
/// ActivityKit: given what is on screen, what the policy chose, and what this
/// session has already spent, it says whether the app may start something new.
public enum PulseReconcileAction: String, Codable, Hashable, Sendable {
    /// Create an activity for the chosen primary. The **only** action that
    /// spends automatic-start budget.
    case start
    /// The chosen primary already has a live activity: push new content into it.
    /// Never spends budget — an update is not a start.
    case update
    /// Keep the activity that is on screen even though the ordering changed.
    /// Never spends budget.
    case holdIncumbent
    /// Nothing may be started: the session's automatic budget is spent.
    case budgetExhausted
    /// Nothing qualifies, or the gates refused. Existing activities are retired.
    case none
}

/// The reconcile decision, with everything the coordinator needs to act.
public struct PulseReconcileDecision: Hashable, Sendable {
    public var action: PulseReconcileAction
    /// The instrument the surface will show. `nil` for ``PulseReconcileAction/none``.
    public var primary: PulseActivityCandidate?
    /// Starts already recorded for this session, before this decision.
    public var attemptsBefore: Int
    /// Starts that will be recorded if this decision is applied (0 or 1).
    public var attemptsConsumed: Int
    /// Whether the decision may only be applied in the foreground.
    public var foregroundOnly: Bool

    public var attemptsAfter: Int { attemptsBefore + attemptsConsumed }

    public init(
        action: PulseReconcileAction,
        primary: PulseActivityCandidate? = nil,
        attemptsBefore: Int = 0,
        attemptsConsumed: Int = 0,
        foregroundOnly: Bool
    ) {
        self.action = action
        self.primary = primary
        self.attemptsBefore = max(0, attemptsBefore)
        self.attemptsConsumed = max(0, min(1, attemptsConsumed))
        self.foregroundOnly = foregroundOnly
    }
}

/// The permanent preferences. All of them survive an activity ending, which is
/// the whole point: a Live Activity is a system object with a lifetime, the
/// user's wish to be tracked is not.
///
/// **Consent is opt-in, and only the user can grant it.** ``enabled`` has no
/// default in ``init(enabled:...)`` on purpose: every call site has to state
/// what it means, so "no stored preference" cannot silently become "yes".
/// ``consentNotYetGiven`` is what an empty or unreadable store decodes to, and
/// every constructor that a *fresh user* could reach goes through it.
public struct PulseTrackingPreferences: Codable, Hashable, Sendable {
    /// Master switch. Off must never be undone by anything automatic.
    public var enabled: Bool
    /// The session ID the user paused. Set only by an explicit pause.
    public var pausedSessionID: String?
    /// The pinned primary. Wins over every derived candidate while it qualifies.
    public var pinnedSymbolKey: String?
    /// When the master switch was last changed, for the settings UI.
    public var updatedAt: Date?

    public init(
        enabled: Bool,
        pausedSessionID: String? = nil,
        pinnedSymbolKey: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.pausedSessionID = pausedSessionID
        self.pinnedSymbolKey = pinnedSymbolKey
        self.updatedAt = updatedAt
    }

    /// What an untouched store holds: nothing was ever switched on, so nothing
    /// is on. This — not ``trackingEnabled`` — is the value a load must fall
    /// back to.
    public static let consentNotYetGiven = PulseTrackingPreferences(enabled: false)

    /// The full-tracking baseline. **Pure contexts only** — previews, unit
    /// tests, a fresh in-memory decision. It must never be what a disk read
    /// produces for a missing or corrupt blob: that would be the app granting
    /// itself consent the user never gave.
    public static let trackingEnabled = PulseTrackingPreferences(enabled: true)

    /// Whether this device recorded an explicit choice. A value that still
    /// carries its own `updatedAt` or a pause/pin was written by a user action.
    public var hasRecordedUserChoice: Bool {
        updatedAt != nil || pausedSessionID != nil || pinnedSymbolKey != nil
    }

    /// Whether the user paused the session in progress.
    public func isPaused(sessionID: String) -> Bool {
        guard let pausedSessionID else { return false }
        return pausedSessionID == sessionID
    }

    // MARK: Mutations (explicit user actions only)

    /// Pause the current session. Deliberately does not touch ``enabled``, and
    /// deliberately does not clear ``pinnedSymbolKey``.
    public mutating func pauseToday(sessionID: String, at date: Date) {
        pausedSessionID = sessionID
        updatedAt = date
    }

    /// Resume the current session — an explicit user action, never automatic.
    /// (The *next* session is not paused anyway, so nothing else is needed.)
    public mutating func resumeToday(at date: Date) {
        pausedSessionID = nil
        updatedAt = date
    }

    public mutating func setEnabled(_ enabled: Bool, at date: Date) {
        self.enabled = enabled
        updatedAt = date
    }

    /// Pin a primary. Pass `nil` to unpin.
    public mutating func pin(symbolKey: String?, at date: Date) {
        pinnedSymbolKey = symbolKey
        updatedAt = date
    }
}

/// The automatic-tracking rule, as one pure function.
///
/// It answers "should an activity exist for this session, and for which
/// instrument" — no timers, no clock reads, no ActivityKit, no network. That is
/// what makes it testable on macOS and reviewable against the product rules.
public enum PulseTrackingPolicy {
    /// Evaluate the decision for one session.
    ///
    /// Order of gates is the order the user would explain them in:
    /// switched off → paused → market shut → no permission → nothing qualifies.
    /// `remoteServiceNotConfigured` is *not* a gate: a foreground-only device
    /// still starts activities while the app is open; it only reports honestly
    /// that it cannot be relied on to start them later.
    public static func decide(
        context: PulseTrackingContext,
        preferences: PulseTrackingPreferences
    ) -> PulseTrackingDecision {
        let foregroundOnly = context.capability != .remotePushConfigured

        func refusal(_ reason: PulseTrackingEligibility) -> PulseTrackingDecision {
            PulseTrackingDecision(
                eligibility: reason,
                sessionID: context.sessionID,
                foregroundOnly: foregroundOnly
            )
        }

        guard preferences.enabled else { return refusal(.disabled) }
        guard !preferences.isPaused(sessionID: context.sessionID) else { return refusal(.pausedToday) }
        guard context.marketPhase.isOpen else { return refusal(.marketClosed) }
        guard context.authorized else { return refusal(.permissionDenied) }

        let qualifying = context.candidates.filter(\.qualifies)
        guard !qualifying.isEmpty else { return refusal(.noCandidate) }

        let ordered = order(qualifying, pinnedSymbolKey: preferences.pinnedSymbolKey)
        guard let primary = ordered.first else { return refusal(.noCandidate) }

        return PulseTrackingDecision(
            eligibility: .eligible,
            primary: primary,
            others: Array(ordered.dropFirst()),
            sessionID: context.sessionID,
            foregroundOnly: foregroundOnly
        )
    }

    /// Selection order: the pinned instrument first, then instruments the user
    /// must act on, then held instruments, then active plans, then name order.
    ///
    /// Name order last makes the result stable: price ticks never reorder it, so
    /// the island's primary cannot swap under the user between two updates.
    public static func order(
        _ candidates: [PulseActivityCandidate],
        pinnedSymbolKey: String?
    ) -> [PulseActivityCandidate] {
        candidates
            .enumerated()
            .sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                let aPinned = a.symbolKey == pinnedSymbolKey
                let bPinned = b.symbolKey == pinnedSymbolKey
                if aPinned != bPinned { return aPinned }
                if (a.actionablePlanCount > 0) != (b.actionablePlanCount > 0) {
                    return a.actionablePlanCount > 0
                }
                if (a.actionablePlanCount > 0 && b.actionablePlanCount > 0),
                   a.actionablePlanCount != b.actionablePlanCount {
                    return a.actionablePlanCount > b.actionablePlanCount
                }
                if a.held != b.held { return a.held }
                if a.hasActivePlan != b.hasActivePlan { return a.hasActivePlan }
                if a.symbolKey != b.symbolKey { return a.symbolKey < b.symbolKey }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Whether an existing activity may be kept across a reconcile.
    ///
    /// The primary is not allowed to hop while the user is looking at it: a new
    /// symbol is followed only when nothing is showing the old one, or when the
    /// user pinned the new one. This is the debounce that stops price ticks from
    /// rotating the island.
    public static func reconciledPrimary(
        currentlyShowing symbolKey: String?,
        decision: PulseTrackingDecision,
        preferences: PulseTrackingPreferences
    ) -> PulseActivityCandidate? {
        guard let chosen = decision.primary else { return nil }
        guard let showing = symbolKey else { return chosen }
        if showing == chosen.symbolKey { return chosen }
        // The user pinned something else — the pin always wins.
        if preferences.pinnedSymbolKey == chosen.symbolKey { return chosen }
        // Otherwise hold the instrument already on screen if it still qualifies.
        if let existing = decision.others.first(where: { $0.symbolKey == showing }) {
            return existing
        }
        return chosen
    }

    /// How long to wait before another automatic start in the same session.
    ///
    /// A user who dismissed the activity twice in one session does not get a
    /// third pop-up: the app stops re-creating it and says so. This is a
    /// per-session budget, not a loop around the system's 8-hour limit.
    public static func automaticStartBudget(forAttempts attempts: Int) -> Bool {
        attempts < 2
    }

    /// Whether the session's budget still allows one more automatic start.
    ///
    /// Named for the ledger rather than the raw count so call sites cannot pass
    /// the wrong number by accident.
    public static func canStartAutomatically(ledger: PulseAutomaticStartLedger, sessionID: String) -> Bool {
        automaticStartBudget(forAttempts: ledger.attempts(inSession: sessionID))
    }

    /// The whole reconcile decision, as one pure function.
    ///
    /// Two things this exists to get right, both of which were wrong when the
    /// coordinator decided inline:
    ///
    /// 1. **Budget follows the *chosen* primary, not the ordering's first
    ///    place.** When the incumbent is kept, the app is updating an activity
    ///    that already exists — spending a start on it wastes the session's
    ///    budget and can stop the incumbent's own updates.
    /// 2. **Only a real start costs anything.** An update, a hold, or a refusal
    ///    consumes zero.
    ///
    /// - Parameters:
    ///   - currentlyShowing: the symbol the system is displaying, if any.
    ///   - hasActivityFor: whether a live activity for a symbol exists. Injected
    ///     so this stays testable without ActivityKit.
    ///   - isAutomatic: `false` for an explicit user action, which is never
    ///     budgeted (the user asked for it).
    ///   - attemptsInSession: attempts already recorded for this session.
    public static func reconcileAction(
        currentlyShowing: String?,
        decision: PulseTrackingDecision,
        preferences: PulseTrackingPreferences,
        hasActivityFor: (String) -> Bool,
        isAutomatic: Bool,
        attemptsInSession: Int
    ) -> PulseReconcileDecision {
        let foregroundOnly = decision.foregroundOnly

        guard decision.shouldStart, let chosen = reconciledPrimary(
            currentlyShowing: currentlyShowing,
            decision: decision,
            preferences: preferences
        ) else {
            return PulseReconcileDecision(action: .none, foregroundOnly: foregroundOnly)
        }

        // The chosen instrument already has an activity: the coordinator's job
        // is to update it. Never a start, never budget.
        if hasActivityFor(chosen.symbolKey) {
            return PulseReconcileDecision(action: .update, primary: chosen, foregroundOnly: foregroundOnly)
        }

        // The ordering's first place is not the chosen primary, so the surface
        // keeps showing the incumbent. Also not a start.
        if chosen.symbolKey != decision.primary?.symbolKey {
            return PulseReconcileDecision(action: .holdIncumbent, primary: chosen, foregroundOnly: foregroundOnly)
        }

        if isAutomatic, !automaticStartBudget(forAttempts: attemptsInSession) {
            return PulseReconcileDecision(
                action: .budgetExhausted,
                primary: chosen,
                attemptsBefore: attemptsInSession,
                foregroundOnly: foregroundOnly
            )
        }

        return PulseReconcileDecision(
            action: .start,
            primary: chosen,
            attemptsBefore: attemptsInSession,
            attemptsConsumed: isAutomatic ? 1 : 0,
            foregroundOnly: foregroundOnly
        )
    }
}

/// Why a load did not return what was stored.
///
/// Reported to the caller instead of being swallowed: an app that shows
/// "自动关注已开启" while the store is unreadable is claiming a consent it
/// cannot find. ``PulseTrackingPreferenceStore/loadResult()`` returns this
/// alongside the safe fallback.
public enum PulseTrackingStoreLoad: String, Codable, Hashable, Sendable {
    /// A blob was present and decoded.
    case loaded
    /// Nothing was ever stored on this device.
    case empty
    /// A blob was present but is not decodable as preferences.
    case corrupt

    public var isTrustworthy: Bool { self == .loaded }
}

/// A load, with the reason attached.
public struct PulseTrackingStoreSnapshot: Hashable, Sendable {
    public var preferences: PulseTrackingPreferences
    public var load: PulseTrackingStoreLoad

    public init(preferences: PulseTrackingPreferences, load: PulseTrackingStoreLoad) {
        self.preferences = preferences
        self.load = load
    }

    /// True when the stored blob was missing or unreadable, so the app must not
    /// treat ``preferences`` as the user's own words.
    public var isUnreadable: Bool { !load.isTrustworthy }
}

/// The durable automatic-start ledger: how many times this app has *started* an
/// activity without the user asking, per market session.
///
/// This is the part that has to survive a relaunch. A Live Activity is a system
/// object with a lifetime and the system tells the app when one ends — but
/// "ended" is not "the user changed their mind", so the budget spent in a
/// session is not refunded by it. Only a new session (or an explicit user
/// action) opens a fresh budget.
///
/// Scope note: this counts *starts this app performed*. A start the remote
/// service performed is not visible here and is not counted.
public struct PulseAutomaticStartLedger: Codable, Hashable, Sendable {
    /// The session the counter belongs to. `nil` before the first start.
    public var sessionID: String?
    /// Automatic starts attempted in ``sessionID``.
    public var attempts: Int
    public var updatedAt: Date?
    /// Optional for compatibility with older persisted ledgers. Unknown history
    /// cannot grant a fresh start budget until the user explicitly resumes.
    public var historyUnavailable: Bool?

    public init(sessionID: String? = nil, attempts: Int = 0, updatedAt: Date? = nil,
                historyUnavailable: Bool? = nil) {
        self.sessionID = sessionID
        self.attempts = max(0, attempts)
        self.updatedAt = updatedAt
        self.historyUnavailable = historyUnavailable
    }

    /// Starts recorded against `sessionID`. Zero for any other session, which
    /// is what makes a new session start with a full budget without a timer.
    public func attempts(inSession sessionID: String) -> Int {
        historyUnavailable == true ? Int.max : (self.sessionID == sessionID ? attempts : 0)
    }

    /// Record one more automatic start in `sessionID`, dropping the previous
    /// session's count.
    public mutating func recordStart(inSession sessionID: String, at date: Date) {
        guard historyUnavailable != true else { return }
        if self.sessionID == sessionID {
            attempts += 1
        } else {
            self.sessionID = sessionID
            attempts = 1
        }
        updatedAt = date
    }

    /// Clear the count for a session, on an explicit user action only.
    public mutating func clear(sessionID: String, at date: Date) {
        if historyUnavailable == true {
            self.sessionID = sessionID
            historyUnavailable = nil
        }
        guard self.sessionID == sessionID else { return }
        attempts = 0
        updatedAt = date
    }
}

/// What the coordinator can honestly claim about the current setup.
///
/// Lives in the pure layer (not behind the ActivityKit gate) so the wording the
/// user is shown can be asserted in tests without an iOS device.
public struct PulseActivityRuntimeStatus: Hashable, Sendable {
    public var activitiesEnabled: Bool
    public var capability: PulseActivityCapability
    /// Set when the app has an ActivityKit-level failure worth surfacing.
    public var lastErrorDescription: String?
    /// `true` when this process created or updated an activity itself.
    public var lastChangeWasLocal: Bool

    public init(
        activitiesEnabled: Bool = false,
        capability: PulseActivityCapability = .foregroundOnly,
        lastErrorDescription: String? = nil,
        lastChangeWasLocal: Bool = true
    ) {
        self.activitiesEnabled = activitiesEnabled
        self.capability = capability
        self.lastErrorDescription = lastErrorDescription
        self.lastChangeWasLocal = lastChangeWasLocal
    }

    /// The sentence the settings screen should show.
    ///
    /// ``PulseActivityCapability/remotePushConfigured`` is only reached after a
    /// real push-to-start token has been received, and even then the wording
    /// says the service *may* update — never that a push has been delivered.
    /// There is no device-side way to know that, and this string must not
    /// pretend otherwise.
    public var capabilityDescription: String {
        switch capability {
        case .foregroundOnly:
            "仅本机前台：只能在本 App 前台运行时创建和更新实时活动，无法在后台自动开始。"
        case .remotePushConfigured:
            "本机已可被远程服务寻址：服务可在授权有效时发起活动更新，但这不代表推送已被验证可达。"
        case .remotePushUnavailable:
            "已配置远程服务但当前不可用，自动开始可能失败。"
        }
    }
}

/// Durable storage for ``PulseTrackingPreferences``.
///
/// Stored under a caller-supplied key in a caller-supplied `UserDefaults` (the
/// app group suite in production). No credentials, no account data, no plan
/// content — only switches, a session ID and a symbol key.
///
/// **A missing or corrupt blob is not consent.** ``load()`` returns
/// ``PulseTrackingPreferences/consentNotYetGiven`` (enabled = false) in both
/// cases and never the permissive baseline. The app has an explicit first-run
/// switch of its own; this store does not second-guess it.
///
/// Not `Sendable`: it holds a `UserDefaults`, which is thread-safe but not
/// annotated as such. Keep one per isolation domain (the coordinator owns the
/// main-actor one) rather than passing it across actors.
public struct PulseTrackingPreferenceStore {
    public static let defaultKey = "pulse.activity.tracking.preferences.v1"
    /// The durable per-session automatic-start ledger, beside the preferences.
    public static let defaultBudgetKey = "pulse.activity.tracking.start-budget.v1"

    private let defaults: UserDefaults
    private let key: String
    private let budgetKey: String

    public init(
        defaults: UserDefaults,
        key: String = PulseTrackingPreferenceStore.defaultKey,
        budgetKey: String = PulseTrackingPreferenceStore.defaultBudgetKey
    ) {
        self.defaults = defaults
        self.key = key
        self.budgetKey = budgetKey
    }

    /// Preferences plus the reason they are what they are.
    ///
    /// Use this wherever the app has to *tell the user* something about
    /// tracking; `load()` is the same value with the reason dropped.
    public func loadResult() -> PulseTrackingStoreSnapshot {
        guard let data = defaults.data(forKey: key) else {
            return PulseTrackingStoreSnapshot(preferences: .consentNotYetGiven, load: .empty)
        }
        do {
            return PulseTrackingStoreSnapshot(
                preferences: try JSONDecoder().decode(PulseTrackingPreferences.self, from: data),
                load: .loaded
            )
        } catch {
            // A blob that will not decode is not a reason to start behaviour the
            // user did not ask for. Falling back to "on" here would be the app
            // granting itself consent, so it falls back to "not yet given".
            return PulseTrackingStoreSnapshot(preferences: .consentNotYetGiven, load: .corrupt)
        }
    }

    public func load() -> PulseTrackingPreferences { loadResult().preferences }

    public func save(_ preferences: PulseTrackingPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }

    public func mutate(_ body: (inout PulseTrackingPreferences) -> Void) -> PulseTrackingPreferences {
        var current = load()
        body(&current)
        save(current)
        return current
    }

    // MARK: - Automatic-start budget (durable)

    /// Missing history is the first-use case; present-but-unreadable history
    /// is not proof that nothing was spent. Fail closed across relaunches and
    /// session changes, until an explicit user resume repairs it.
    public func loadBudget() -> PulseAutomaticStartLedger {
        guard defaults.object(forKey: budgetKey) != nil else { return PulseAutomaticStartLedger() }
        guard let data = defaults.data(forKey: budgetKey),
              let ledger = try? JSONDecoder().decode(PulseAutomaticStartLedger.self, from: data),
              ledger.attempts >= 0, ledger.attempts < Int.max,
              ledger.attempts == 0 || ledger.sessionID != nil else {
            return PulseAutomaticStartLedger(historyUnavailable: true)
        }
        return ledger
    }

    public func saveBudget(_ ledger: PulseAutomaticStartLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: budgetKey)
    }

    /// Claim one automatic start in `sessionID` **before** the start is
    /// requested, so a request that never reports back cannot buy a second one.
    ///
    /// Returns the resulting ledger; the caller decides whether the start was
    /// allowed by checking it against ``PulseTrackingPolicy/automaticStartBudget(forAttempts:)``.
    @discardableResult
    public func claimAutomaticStart(inSession sessionID: String, at date: Date) -> PulseAutomaticStartLedger {
        var ledger = loadBudget()
        ledger.recordStart(inSession: sessionID, at: date)
        saveBudget(ledger)
        return ledger
    }

    /// Give back a claim when the start was never requested (no decision, an
    /// activity already showing, a request that threw before reaching the
    /// system). Only ever called on a path that did not create anything.
    @discardableResult
    public func refundAutomaticStart(inSession sessionID: String, at date: Date) -> PulseAutomaticStartLedger {
        var ledger = loadBudget()
        guard ledger.sessionID == sessionID, ledger.attempts > 0 else { return ledger }
        ledger.attempts -= 1
        ledger.updatedAt = date
        saveBudget(ledger)
        return ledger
    }

    /// Reset the session's budget. The coordinator calls this **only** from an
    /// explicit user action, never from a system lifecycle event.
    @discardableResult
    public func clearAutomaticStartBudget(sessionID: String, at date: Date) -> PulseAutomaticStartLedger {
        var ledger = loadBudget()
        ledger.clear(sessionID: sessionID, at: date)
        saveBudget(ledger)
        return ledger
    }
}
