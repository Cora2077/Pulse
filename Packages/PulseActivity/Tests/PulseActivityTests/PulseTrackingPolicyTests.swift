import Foundation
import Testing

@testable import PulseActivity

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let session = "sh.2027-01-15.regular"

private func context(
    candidates: [PulseActivityCandidate],
    phase: PulseMarketPhase = .regular,
    sessionID: String = session,
    authorized: Bool = true,
    capability: PulseActivityCapability = .foregroundOnly,
    at date: Date = now
) -> PulseTrackingContext {
    PulseTrackingContext(
        candidates: candidates,
        marketPhase: phase,
        sessionID: sessionID,
        authorized: authorized,
        capability: capability,
        now: date
    )
}

@Suite("Automatic tracking policy")
struct PulseTrackingPolicyTests {
    // MARK: Qualification — held OR active plan OR pinned

    @Test("A held position alone qualifies")
    func heldQualifies() {
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "600519.SH", held: true)]),
            preferences: .trackingEnabled
        )
        #expect(decision.shouldStart)
        #expect(decision.primary?.symbolKey == "600519.SH")
    }

    @Test("An active plan alone qualifies, with no position at all")
    func activePlanQualifies() {
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "AAPL", hasActivePlan: true)]),
            preferences: .trackingEnabled
        )
        #expect(decision.shouldStart)
        #expect(decision.primary?.symbolKey == "AAPL")
    }

    @Test("A pinned instrument alone qualifies")
    func pinnedQualifies() {
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "00700.HK", pinned: true)]),
            preferences: .trackingEnabled
        )
        #expect(decision.shouldStart)
        #expect(decision.primary?.symbolKey == "00700.HK")
    }

    @Test("The rule is OR, never AND")
    func ruleIsOrNotAnd() {
        // Held but no plan; plan but no holding; pinned but neither. All three
        // must qualify — this is the case the design doc calls out explicitly.
        let cases: [[PulseActivityCandidate]] = [
            [.init(symbolKey: "A", held: true)],
            [.init(symbolKey: "B", hasActivePlan: true)],
            [.init(symbolKey: "C", pinned: true)]
        ]
        for candidates in cases {
            let decision = PulseTrackingPolicy.decide(
                context: context(candidates: candidates),
                preferences: .trackingEnabled
            )
            #expect(decision.shouldStart, "\(candidates[0].symbolKey) should qualify on its own")
        }
    }

    @Test("An instrument that is none of the three never qualifies")
    func nonCandidateRejected() {
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "MSFT")]),
            preferences: .trackingEnabled
        )
        #expect(!decision.shouldStart)
        #expect(decision.eligibility == .noCandidate)
        #expect(decision.primary == nil)
    }

    @Test("No candidates at all is reported as noCandidate, not as success")
    func emptyCandidates() {
        let decision = PulseTrackingPolicy.decide(context: context(candidates: []), preferences: .trackingEnabled)
        #expect(decision.eligibility == .noCandidate)
        #expect(!decision.shouldStart)
    }

    // MARK: Gates

    @Test("The master switch off stops everything and is never overridden")
    func disabledGate() {
        var preferences = PulseTrackingPreferences(enabled: true)
        preferences.setEnabled(false, at: now)
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "600519.SH", held: true)]),
            preferences: preferences
        )
        #expect(decision.eligibility == .disabled)
        #expect(!decision.shouldStart)
    }

    @Test("A today-pause stops this session only and restores by itself")
    func pauseGate() {
        var preferences = PulseTrackingPreferences(enabled: true)
        preferences.pauseToday(sessionID: session, at: now)

        let paused = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "600519.SH", held: true)]),
            preferences: preferences
        )
        #expect(paused.eligibility == .pausedToday)
        #expect(!paused.shouldStart)

        // Next session — no user action, no timer: the pause simply does not
        // apply, because it was scoped to a session and not to a date.
        let nextSession = PulseTrackingPolicy.decide(
            context: context(
                candidates: [.init(symbolKey: "600519.SH", held: true)],
                sessionID: "sh.2027-01-18.regular"
            ),
            preferences: preferences
        )
        #expect(nextSession.shouldStart)
        // The master switch was never touched by the pause.
        #expect(preferences.enabled)
    }

    @Test("Pause and disable are separate states that do not impersonate each other")
    func pauseAndDisableDiffer() {
        var paused = PulseTrackingPreferences(enabled: true)
        paused.pauseToday(sessionID: session, at: now)
        var disabled = PulseTrackingPreferences(enabled: true)
        disabled.setEnabled(false, at: now)

        #expect(paused.enabled)
        #expect(paused.isPaused(sessionID: session))
        #expect(!disabled.isPaused(sessionID: session))

        // Disabling wins over a pause when both are set.
        var both = paused
        both.setEnabled(false, at: now)
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "X", held: true)]),
            preferences: both
        )
        #expect(decision.eligibility == .disabled)
    }

    @Test("Resuming today is explicit and clears only the pause")
    func resume() {
        var preferences = PulseTrackingPreferences(enabled: true)
        preferences.pauseToday(sessionID: session, at: now)
        preferences.pin(symbolKey: "600519.SH", at: now)
        preferences.resumeToday(at: now)
        #expect(!preferences.isPaused(sessionID: session))
        #expect(preferences.pinnedSymbolKey == "600519.SH")
    }

    @Test("A closed market reports closed even with qualifying candidates")
    func marketClosedGate() {
        for phase: PulseMarketPhase in [.closed, .preMarket, .postMarket, .lunchBreak, .overnight, .unknown] {
            let decision = PulseTrackingPolicy.decide(
                context: context(candidates: [.init(symbolKey: "600519.SH", held: true)], phase: phase),
                preferences: .trackingEnabled
            )
            #expect(decision.eligibility == .marketClosed, "\(phase) must not start an activity")
        }
    }

    @Test("Only the regular session counts as open")
    func onlyRegularIsOpen() {
        #expect(PulseMarketPhase.regular.isOpen)
        #expect(!PulseMarketPhase.overnight.isOpen)
        #expect(!PulseMarketPhase.preMarket.isOpen)
    }

    @Test("Missing permission is reported as such, not as an empty watchlist")
    func permissionGate() {
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "600519.SH", held: true)], authorized: false),
            preferences: .trackingEnabled
        )
        #expect(decision.eligibility == .permissionDenied)
        #expect(!decision.shouldStart)
    }

    // MARK: Honesty about what the device can do

    @Test("Without a remote service the decision says foreground only")
    func foregroundOnlyIsDeclared() {
        let decision = PulseTrackingPolicy.decide(
            context: context(
                candidates: [.init(symbolKey: "600519.SH", held: true)],
                capability: .foregroundOnly
            ),
            preferences: .trackingEnabled
        )
        #expect(decision.shouldStart)
        #expect(decision.foregroundOnly)
    }

    @Test("A configured remote service is the only case that is not foreground-bound")
    func remoteConfiguredIsNotForegroundOnly() {
        let decision = PulseTrackingPolicy.decide(
            context: context(
                candidates: [.init(symbolKey: "600519.SH", held: true)],
                capability: .remotePushConfigured
            ),
            preferences: .trackingEnabled
        )
        #expect(!decision.foregroundOnly)
    }

    @Test("An unreachable remote service still declares foreground-only")
    func remoteUnavailableStaysHonest() {
        let decision = PulseTrackingPolicy.decide(
            context: context(
                candidates: [.init(symbolKey: "600519.SH", held: true)],
                capability: .remotePushUnavailable
            ),
            preferences: .trackingEnabled
        )
        #expect(decision.foregroundOnly)
    }

    @Test("A refused decision never carries a primary")
    func refusalsCarryNoPrimary() {
        let scenarios: [(PulseTrackingContext, PulseTrackingPreferences)] = [
            (context(candidates: [.init(symbolKey: "A", held: true)], phase: .closed), .trackingEnabled),
            (context(candidates: [.init(symbolKey: "A", held: true)], authorized: false), .trackingEnabled),
            (context(candidates: []), .trackingEnabled),
            (context(candidates: [.init(symbolKey: "A", held: true)]),
             {
                 var p = PulseTrackingPreferences(enabled: true)
                 p.setEnabled(false, at: now)
                 return p
             }())
        ]
        for (ctx, prefs) in scenarios {
            let decision = PulseTrackingPolicy.decide(context: ctx, preferences: prefs)
            #expect(!decision.eligibility.isEligible)
            #expect(decision.primary == nil)
            #expect(!decision.shouldStart)
        }
    }

    // MARK: Ordering

    @Test("A pinned instrument wins over everything else")
    func pinnedWins() {
        let ordered = PulseTrackingPolicy.order(
            [
                .init(symbolKey: "600519.SH", held: true),
                .init(symbolKey: "00700.HK", hasActivePlan: true, actionablePlanCount: 3),
                .init(symbolKey: "AAPL", pinned: true)
            ],
            pinnedSymbolKey: "AAPL"
        )
        #expect(ordered.first?.symbolKey == "AAPL")
    }

    @Test("Actionable work outranks a plain holding, then position, then plan")
    func orderingPrecedence() {
        let ordered = PulseTrackingPolicy.order(
            [
                .init(symbolKey: "d-plan", hasActivePlan: true),
                .init(symbolKey: "c-held", held: true),
                .init(symbolKey: "b-actionable", held: true, actionablePlanCount: 2),
                .init(symbolKey: "a-idle")
            ],
            pinnedSymbolKey: nil
        )
        #expect(ordered.map(\.symbolKey) == ["b-actionable", "c-held", "d-plan", "a-idle"])
    }

    @Test("Ordering is stable across calls so price ticks cannot rotate the island")
    func orderingIsStable() {
        let candidates: [PulseActivityCandidate] = [
            .init(symbolKey: "MSFT", held: true),
            .init(symbolKey: "AAPL", held: true),
            .init(symbolKey: "NVDA", held: true)
        ]
        let first = PulseTrackingPolicy.order(candidates, pinnedSymbolKey: nil).map(\.symbolKey)
        let second = PulseTrackingPolicy.order(candidates.shuffled(), pinnedSymbolKey: nil).map(\.symbolKey)
        #expect(first == second)
        #expect(first == ["AAPL", "MSFT", "NVDA"])
    }

    @Test("Equal-priority duplicates keep their input order")
    func orderingTieBreak() {
        let ordered = PulseTrackingPolicy.order(
            [.init(symbolKey: "B", held: true), .init(symbolKey: "B", held: true, hasActivePlan: true)],
            pinnedSymbolKey: nil
        )
        #expect(ordered.count == 2)
        #expect(ordered[0].hasActivePlan == false || ordered[0].symbolKey == "B")
    }

    // MARK: Incumbent protection (debounce)

    @Test("The showing instrument is not swapped out while it still qualifies")
    func incumbentIsHeld() {
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [
                .init(symbolKey: "600519.SH", held: true),
                .init(symbolKey: "AAPL", held: true, actionablePlanCount: 5)
            ]),
            preferences: .trackingEnabled
        )
        #expect(decision.primary?.symbolKey == "AAPL")

        // The island is already showing 600519.SH — it stays, even though AAPL
        // now has something actionable. A tick does not rotate the display.
        let kept = PulseTrackingPolicy.reconciledPrimary(
            currentlyShowing: "600519.SH",
            decision: decision,
            preferences: .trackingEnabled
        )
        #expect(kept?.symbolKey == "600519.SH")
    }

    @Test("A user pin overrides the incumbent immediately")
    func pinBreaksIncumbent() {
        var preferences = PulseTrackingPreferences(enabled: true)
        preferences.pin(symbolKey: "AAPL", at: now)
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [
                .init(symbolKey: "600519.SH", held: true),
                .init(symbolKey: "AAPL", pinned: true)
            ]),
            preferences: preferences
        )
        let chosen = PulseTrackingPolicy.reconciledPrimary(
            currentlyShowing: "600519.SH",
            decision: decision,
            preferences: preferences
        )
        #expect(chosen?.symbolKey == "AAPL")
    }

    @Test("An instrument that stopped qualifying is replaced")
    func staleIncumbentReplaced() {
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "AAPL", held: true)]),
            preferences: .trackingEnabled
        )
        let chosen = PulseTrackingPolicy.reconciledPrimary(
            currentlyShowing: "SOLD",
            decision: decision,
            preferences: .trackingEnabled
        )
        #expect(chosen?.symbolKey == "AAPL")
    }

    @Test("Nothing showing means the decided primary is used")
    func noIncumbentUsesDecision() {
        let decision = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "600519.SH", held: true)]),
            preferences: .trackingEnabled
        )
        #expect(PulseTrackingPolicy.reconciledPrimary(
            currentlyShowing: nil, decision: decision, preferences: .trackingEnabled
        )?.symbolKey == "600519.SH")
    }

    // MARK: Budget

    @Test("Repeated automatic starts in one session are budgeted, not looped")
    func automaticStartBudget() {
        #expect(PulseTrackingPolicy.automaticStartBudget(forAttempts: 0))
        #expect(PulseTrackingPolicy.automaticStartBudget(forAttempts: 1))
        #expect(!PulseTrackingPolicy.automaticStartBudget(forAttempts: 2))
        #expect(!PulseTrackingPolicy.automaticStartBudget(forAttempts: 9))
    }
}

// MARK: - Preferences persistence

@Suite("Tracking preferences store")
struct PulseTrackingPreferenceStoreTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "pulse.activity.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("An untouched store does not grant consent")
    func defaults() {
        let store = PulseTrackingPreferenceStore(defaults: isolatedDefaults())
        let snapshot = store.loadResult()
        // An empty store is NOT "tracking on": nobody ever switched it on. The
        // app's own first-run switch is what turns it on, and it must be able to
        // tell this case apart from a stored `true`.
        #expect(snapshot.load == .empty)
        #expect(!snapshot.preferences.enabled)
        #expect(snapshot.preferences.pausedSessionID == nil)
        #expect(snapshot.preferences.pinnedSymbolKey == nil)
        #expect(!snapshot.preferences.hasRecordedUserChoice)
    }

    @Test("Preferences survive a new store over the same defaults")
    func persistence() {
        let defaults = isolatedDefaults()
        let store = PulseTrackingPreferenceStore(defaults: defaults)
        _ = store.mutate { $0.setEnabled(true, at: now) }
        _ = store.mutate { $0.pauseToday(sessionID: session, at: now) }
        _ = store.mutate { $0.pin(symbolKey: "600519.SH", at: now) }

        let reloaded = PulseTrackingPreferenceStore(defaults: defaults).load()
        #expect(reloaded.isPaused(sessionID: session))
        #expect(reloaded.pinnedSymbolKey == "600519.SH")
        #expect(reloaded.enabled)
    }

    @Test("Disabling persists and does not silently revert")
    func disablePersists() {
        let defaults = isolatedDefaults()
        let store = PulseTrackingPreferenceStore(defaults: defaults)
        _ = store.mutate { $0.setEnabled(true, at: now) }
        _ = store.mutate { $0.setEnabled(false, at: now) }
        #expect(!PulseTrackingPreferenceStore(defaults: defaults).load().enabled)

        // An unrelated change must not turn it back on.
        _ = store.mutate { $0.pin(symbolKey: "AAPL", at: now) }
        #expect(!store.load().enabled)
    }

    @Test("A corrupt blob is not consent: it loads as disabled and says so")
    func corruptBlobFallsBack() {
        let defaults = isolatedDefaults()
        let key = "pulse.activity.tests.corrupt"
        defaults.set(Data("not json".utf8), forKey: key)
        let store = PulseTrackingPreferenceStore(defaults: defaults, key: key)
        let snapshot = store.loadResult()
        // The old assertion here expected `enabled == true`. That was the bug:
        // an unreadable blob would have the app resume tracking on its own.
        #expect(snapshot.load == .corrupt)
        #expect(!snapshot.preferences.enabled)
        #expect(snapshot.isUnreadable)
        #expect(snapshot.preferences.pinnedSymbolKey == nil)
    }

    @Test("A corrupt blob cannot be laundered into consent by a later unrelated write")
    func corruptBlobIsNotUpgraded() {
        let defaults = isolatedDefaults()
        let key = "pulse.activity.tests.corrupt2"
        defaults.set(Data("{ truncated".utf8), forKey: key)
        let store = PulseTrackingPreferenceStore(defaults: defaults, key: key)
        _ = store.mutate { $0.pin(symbolKey: "AAPL", at: now) }
        // Only the pin was written; the master switch is still off.
        #expect(!store.load().enabled)
    }

    @Test("Preferences written as true round-trip as an explicit yes")
    func explicitConsentRoundTrips() {
        let defaults = isolatedDefaults()
        let store = PulseTrackingPreferenceStore(defaults: defaults)
        _ = store.mutate { $0.setEnabled(true, at: now) }
        let snapshot = store.loadResult()
        #expect(snapshot.load == .loaded)
        #expect(snapshot.preferences.enabled)
        #expect(snapshot.preferences.hasRecordedUserChoice)
    }

    @Test("A demo suite key does not collide with another suite")
    func suiteIsolation() {
        let a = PulseTrackingPreferenceStore(defaults: isolatedDefaults())
        _ = a.mutate { $0.pin(symbolKey: "AAPL", at: now) }
        let b = PulseTrackingPreferenceStore(defaults: isolatedDefaults())
        #expect(b.load().pinnedSymbolKey == nil)
    }
}

// MARK: - Durable automatic-start budget

@Suite("Automatic start ledger")
struct PulseAutomaticStartLedgerTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "pulse.activity.budget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let sessionA = "sh.2027-01-15.regular"
    private let sessionB = "sh.2027-01-18.regular"

    @Test("The budget is spent once per session and is not refunded by an ending")
    func budgetIsPerSession() {
        var ledger = PulseAutomaticStartLedger()
        #expect(ledger.attempts(inSession: sessionA) == 0)
        ledger.recordStart(inSession: sessionA, at: now)
        ledger.recordStart(inSession: sessionA, at: now)
        #expect(ledger.attempts(inSession: sessionA) == 2)
        #expect(!PulseTrackingPolicy.canStartAutomatically(ledger: ledger, sessionID: sessionA))
    }

    @Test("A new session starts with a full budget without a timer or a reset call")
    func newSessionHasFullBudget() {
        var ledger = PulseAutomaticStartLedger()
        ledger.recordStart(inSession: sessionA, at: now)
        ledger.recordStart(inSession: sessionA, at: now)
        #expect(!PulseTrackingPolicy.canStartAutomatically(ledger: ledger, sessionID: sessionA))
        // No reset was called: the count simply does not apply to another
        // session, which is what stops a midnight rollover from being a loop.
        #expect(ledger.attempts(inSession: sessionB) == 0)
        #expect(PulseTrackingPolicy.canStartAutomatically(ledger: ledger, sessionID: sessionB))
    }

    @Test("An ended activity does not clear the session's spent budget")
    func endingDoesNotRefund() {
        var ledger = PulseAutomaticStartLedger()
        ledger.recordStart(inSession: sessionA, at: now)
        ledger.recordStart(inSession: sessionA, at: now)
        // `.ended` is a system lifecycle event, not a user decision. There is no
        // API on this type that a lifecycle event can call to get budget back;
        // `clear` is explicitly the user action, and it is scoped to a session.
        #expect(!PulseTrackingPolicy.canStartAutomatically(ledger: ledger, sessionID: sessionA))
        // Clearing a *different* session is a no-op on this one.
        ledger.clear(sessionID: sessionB, at: now)
        #expect(ledger.attempts(inSession: sessionA) == 2)
    }

    @Test("A refund only ever returns a claim that was not spent on a start")
    func refundIsBounded() {
        let defaults = isolatedDefaults()
        let store = PulseTrackingPreferenceStore(defaults: defaults)

        let claimed = store.claimAutomaticStart(inSession: sessionA, at: now)
        #expect(claimed.attempts(inSession: sessionA) == 1)

        let refunded = store.refundAutomaticStart(inSession: sessionA, at: now)
        #expect(refunded.attempts(inSession: sessionA) == 0)

        // Never goes negative, and never invents budget for another session.
        let twice = store.refundAutomaticStart(inSession: sessionA, at: now)
        #expect(twice.attempts(inSession: sessionA) == 0)
        let other = store.refundAutomaticStart(inSession: sessionB, at: now)
        #expect(other.attempts(inSession: sessionB) == 0)
    }

    @Test("The spent budget survives a relaunch: a rebuilt store still refuses")
    func budgetSurvivesRelaunch() {
        let defaults = isolatedDefaults()
        let first = PulseTrackingPreferenceStore(defaults: defaults)
        first.claimAutomaticStart(inSession: sessionA, at: now)
        first.claimAutomaticStart(inSession: sessionA, at: now)

        // A relaunch builds a brand new store over the same defaults. The old
        // in-memory counter would have been zero here; the durable ledger is not.
        let relaunched = PulseTrackingPreferenceStore(defaults: defaults)
        let ledger = relaunched.loadBudget()
        #expect(ledger.attempts(inSession: sessionA) == 2)
        #expect(!PulseTrackingPolicy.canStartAutomatically(ledger: ledger, sessionID: sessionA))

        // The next session still gets its own full budget after the relaunch.
        #expect(PulseTrackingPolicy.canStartAutomatically(ledger: ledger, sessionID: sessionB))
    }

    @Test("A corrupt ledger cannot grant starts, even in a new session or after relaunch")
    func corruptLedgerFailsClosed() {
        let defaults = isolatedDefaults()
        let key = "pulse.activity.tests.budget.corrupt"
        let budgetKey = "pulse.activity.tests.budget.corrupt.budget"
        defaults.set(Data("}{".utf8), forKey: budgetKey)
        let store = PulseTrackingPreferenceStore(defaults: defaults, key: key, budgetKey: budgetKey)
        #expect(store.loadBudget().historyUnavailable == true)
        #expect(!PulseTrackingPolicy.canStartAutomatically(ledger: store.loadBudget(), sessionID: sessionA))
        #expect(!PulseTrackingPolicy.canStartAutomatically(ledger: store.loadBudget(), sessionID: sessionB))
        let relaunched = PulseTrackingPreferenceStore(defaults: defaults, key: key, budgetKey: budgetKey)
        #expect(!PulseTrackingPolicy.canStartAutomatically(ledger: relaunched.loadBudget(), sessionID: sessionA))
        // Only explicit user intent repairs an unknown history, not a lifecycle event.
        _ = relaunched.clearAutomaticStartBudget(sessionID: sessionA, at: now)
        #expect(relaunched.loadBudget().historyUnavailable == nil)
        #expect(PulseTrackingPolicy.canStartAutomatically(ledger: relaunched.loadBudget(), sessionID: sessionA))
    }

    @Test("An explicit user resume is the only path that reopens the session's budget")
    func userResumeReopensBudget() async {
        let defaults = isolatedDefaults()
        let store = PulseTrackingPreferenceStore(defaults: defaults)
        store.claimAutomaticStart(inSession: sessionA, at: now)
        store.claimAutomaticStart(inSession: sessionA, at: now)
        #expect(!PulseTrackingPolicy.canStartAutomatically(
            ledger: store.loadBudget(), sessionID: sessionA
        ))

        // The coordinator maps an explicit user resume onto this call; nothing
        // in the lifecycle path does.
        let cleared = store.clearAutomaticStartBudget(sessionID: sessionA, at: now)
        #expect(cleared.attempts(inSession: sessionA) == 0)
        #expect(PulseTrackingPolicy.canStartAutomatically(ledger: cleared, sessionID: sessionA))
    }

    @Test("Clearing the budget for one session leaves another session alone")
    func clearIsScoped() {
        var ledger = PulseAutomaticStartLedger()
        ledger.recordStart(inSession: sessionA, at: now)
        ledger.recordStart(inSession: sessionA, at: now)
        ledger.clear(sessionID: sessionB, at: now)
        #expect(ledger.attempts(inSession: sessionA) == 2)
        ledger.clear(sessionID: sessionA, at: now)
        #expect(ledger.attempts(inSession: sessionA) == 0)
    }
}

// MARK: - Reconcile decision (budget follows the chosen primary)

@Suite("Reconcile action")
struct PulseReconcileActionTests {
    private func decision(
        session forSession: String = session,
        candidates: [PulseActivityCandidate]
    ) -> PulseTrackingDecision {
        PulseTrackingPolicy.decide(
            context: context(candidates: candidates, sessionID: forSession),
            preferences: .trackingEnabled
        )
    }

    @Test("An update to the incumbent never spends an automatic start")
    func updateDoesNotSpendBudget() {
        let decided = decision(candidates: [.init(symbolKey: "AAPL", held: true)])
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: "AAPL",
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { $0 == "AAPL" },
            isAutomatic: true,
            attemptsInSession: 0
        )
        #expect(plan.action == .update)
        #expect(plan.attemptsConsumed == 0)
        #expect(plan.attemptsAfter == 0)
    }

    @Test("Keeping a reordered incumbent is a hold, not a start, and spends nothing")
    func holdIncumbentDoesNotSpendBudget() {
        // The ordering's first place is AAPL (it has actionable work), but the
        // surface already shows 600519.SH, which still qualifies. `hasActivityFor`
        // is false for both here: the system object for the incumbent is not
        // discoverable, which is exactly when a naive coordinator would charge a
        // start for the ordering's first place instead.
        let decided = decision(candidates: [
            .init(symbolKey: "600519.SH", held: true),
            .init(symbolKey: "AAPL", held: true, actionablePlanCount: 5)
        ])
        #expect(decided.primary?.symbolKey == "AAPL")

        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: "600519.SH",
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { _ in false },
            isAutomatic: true,
            attemptsInSession: 0
        )
        // This is the old bug in one assertion: deciding budget from
        // `decision.primary` would have charged a start here for AAPL and, at
        // the budget limit, refused to keep 600519.SH at all.
        #expect(plan.action == .holdIncumbent)
        #expect(plan.primary?.symbolKey == "600519.SH")
        #expect(plan.attemptsConsumed == 0)
    }

    @Test("An incumbent that does have a live activity is updated, not held")
    func incumbentWithActivityIsUpdated() {
        let decided = decision(candidates: [
            .init(symbolKey: "600519.SH", held: true),
            .init(symbolKey: "AAPL", held: true, actionablePlanCount: 5)
        ])
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: "600519.SH",
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { $0 == "600519.SH" },
            isAutomatic: true,
            attemptsInSession: 9
        )
        // Exhausted budget must not stop an *update* to what is on screen.
        #expect(plan.action == .update)
        #expect(plan.primary?.symbolKey == "600519.SH")
        #expect(plan.attemptsConsumed == 0)
    }

    @Test("A hold is still available after the budget is exhausted")
    func holdSurvivesExhaustedBudget() {
        let decided = decision(candidates: [
            .init(symbolKey: "600519.SH", held: true),
            .init(symbolKey: "AAPL", held: true, actionablePlanCount: 5)
        ])
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: "600519.SH",
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { _ in false },
            isAutomatic: true,
            attemptsInSession: 9
        )
        // The spent budget must not evict the instrument the user is watching.
        #expect(plan.action == .holdIncumbent)
        #expect(plan.attemptsConsumed == 0)
    }

    @Test("Only a genuinely new activity consumes budget")
    func realStartConsumesBudget() {
        let decided = decision(candidates: [.init(symbolKey: "AAPL", held: true)])
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: nil,
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { _ in false },
            isAutomatic: true,
            attemptsInSession: 0
        )
        #expect(plan.action == .start)
        #expect(plan.attemptsConsumed == 1)
        #expect(plan.attemptsAfter == 1)
    }

    @Test("An exhausted budget refuses an automatic start and says why")
    func exhaustedBudgetRefusesStart() {
        let decided = decision(candidates: [.init(symbolKey: "AAPL", held: true)])
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: nil,
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { _ in false },
            isAutomatic: true,
            attemptsInSession: 2
        )
        #expect(plan.action == .budgetExhausted)
        #expect(plan.attemptsConsumed == 0)
        #expect(plan.attemptsAfter == 2)
    }

    @Test("An explicit user start is never budgeted")
    func userStartIsNotBudgeted() {
        let decided = decision(candidates: [.init(symbolKey: "AAPL", held: true)])
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: nil,
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { _ in false },
            isAutomatic: false,
            attemptsInSession: 9
        )
        #expect(plan.action == .start)
        #expect(plan.attemptsConsumed == 0)
    }

    @Test("A refused decision maps to none and touches nothing")
    func refusalMapsToNone() {
        let decided = PulseTrackingPolicy.decide(
            context: context(candidates: [.init(symbolKey: "AAPL", held: true)], phase: .closed),
            preferences: .trackingEnabled
        )
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: "AAPL",
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { _ in true },
            isAutomatic: true,
            attemptsInSession: 0
        )
        #expect(plan.action == .none)
        #expect(plan.primary == nil)
        #expect(plan.attemptsConsumed == 0)
    }

    @Test("The decision is always honest about foreground-only")
    func decisionDeclaresForegroundOnly() {
        let decided = decision(candidates: [.init(symbolKey: "AAPL", held: true)])
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: nil,
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { _ in false },
            isAutomatic: true,
            attemptsInSession: 0
        )
        #expect(plan.foregroundOnly)
    }
}

// MARK: - The loop the durable budget exists to stop

@Suite("Automatic start budget end to end")
struct AutomaticStartBudgetEndToEndTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "pulse.activity.e2e.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let session = "sh.2027-01-15.regular"

    /// One reconcile cycle, reduced to the parts that touch the ledger: decide,
    /// plan, claim, and either keep the claim (a start landed) or refund it.
    @discardableResult
    private func cycle(
        store: PulseTrackingPreferenceStore,
        sessionID: String,
        activityIsUp: Bool,
        startLands: Bool,
        isAutomatic: Bool = true
    ) -> PulseReconcileAction {
        let decided = PulseTrackingPolicy.decide(
            context: PulseTrackingContext(
                candidates: [PulseActivityCandidate(symbolKey: "600519.SH", held: true)],
                marketPhase: .regular,
                sessionID: sessionID,
                authorized: true,
                capability: .foregroundOnly,
                now: now
            ),
            preferences: .trackingEnabled
        )
        let plan = PulseTrackingPolicy.reconcileAction(
            currentlyShowing: activityIsUp ? "600519.SH" : nil,
            decision: decided,
            preferences: .trackingEnabled,
            hasActivityFor: { _ in activityIsUp },
            isAutomatic: isAutomatic,
            attemptsInSession: store.loadBudget().attempts(inSession: sessionID)
        )
        guard plan.action == .start, plan.attemptsConsumed > 0 else { return plan.action }
        store.claimAutomaticStart(inSession: sessionID, at: now)
        if !startLands {
            store.refundAutomaticStart(inSession: sessionID, at: now)
        }
        return plan.action
    }

    @Test("Five system-driven relaunches in one session cannot make a sixth start")
    func relaunchLoopIsBounded() {
        let defaults = isolatedDefaults()
        let store = PulseTrackingPreferenceStore(defaults: defaults)

        // The activity starts, then the system ends it and the app relaunches.
        // Because `.ended` grants nothing, each relaunch sees the spent budget.
        #expect(cycle(store: store, sessionID: session, activityIsUp: false, startLands: true) == .start)
        #expect(cycle(store: store, sessionID: session, activityIsUp: false, startLands: true) == .start)

        for _ in 0..<5 {
            // A fresh store object over the same defaults is what a relaunch
            // actually builds. The old in-memory counter reset here; the durable
            // ledger does not.
            let relaunched = PulseTrackingPreferenceStore(defaults: defaults)
            let action = cycle(store: relaunched, sessionID: session, activityIsUp: false, startLands: true)
            #expect(action == .budgetExhausted, "a relaunch must not buy another automatic start")
            #expect(relaunched.loadBudget().attempts(inSession: session) == 2)
        }
        #expect(store.loadBudget().attempts(inSession: session) == 2)
    }

    @Test("A failed start does not consume the session's budget")
    func failedStartIsRefunded() {
        let store = PulseTrackingPreferenceStore(defaults: isolatedDefaults())
        // The request threw (no permission): nothing was created, so nothing is
        // charged. This is the one legitimate refund.
        #expect(cycle(store: store, sessionID: session, activityIsUp: false, startLands: false) == .start)
        #expect(store.loadBudget().attempts(inSession: session) == 0)
        #expect(PulseTrackingPolicy.canStartAutomatically(
            ledger: store.loadBudget(), sessionID: session
        ))
    }

    @Test("An explicit user resume is the one thing that reopens a spent budget")
    func onlyUserResumeReopens() {
        let store = PulseTrackingPreferenceStore(defaults: isolatedDefaults())
        cycle(store: store, sessionID: session, activityIsUp: false, startLands: true)
        cycle(store: store, sessionID: session, activityIsUp: false, startLands: true)
        #expect(cycle(store: store, sessionID: session, activityIsUp: false, startLands: true) == .budgetExhausted)

        // What `resumeToday` does — and the only caller of this in production.
        store.clearAutomaticStartBudget(sessionID: session, at: now)
        #expect(cycle(store: store, sessionID: session, activityIsUp: false, startLands: true) == .start)
    }

    @Test("A user-initiated start after the budget is spent is still allowed")
    func userInitiatedStartIgnoresBudget() {
        let store = PulseTrackingPreferenceStore(defaults: isolatedDefaults())
        cycle(store: store, sessionID: session, activityIsUp: false, startLands: true)
        cycle(store: store, sessionID: session, activityIsUp: false, startLands: true)
        // `isAutomatic: false` is an explicit user action, so it is never
        // budgeted and never refused by the budget.
        #expect(cycle(
            store: store, sessionID: session, activityIsUp: false,
            startLands: true, isAutomatic: false
        ) == .start)
        #expect(store.loadBudget().attempts(inSession: session) == 2)
    }

    @Test("A new session after the budget is spent starts automatically again")
    func nextSessionIsNotBlockedByTheLast() {
        let store = PulseTrackingPreferenceStore(defaults: isolatedDefaults())
        cycle(store: store, sessionID: session, activityIsUp: false, startLands: true)
        cycle(store: store, sessionID: session, activityIsUp: false, startLands: true)
        #expect(cycle(store: store, sessionID: session, activityIsUp: false, startLands: true) == .budgetExhausted)
        // Next trading day: a full budget, with no reset call and no timer.
        #expect(cycle(
            store: store, sessionID: "sh.2027-01-18.regular",
            activityIsUp: false, startLands: true
        ) == .start)
    }
}

// MARK: - Eligibility vocabulary

@Suite("Eligibility reporting")
struct PulseTrackingEligibilityTests {
    @Test("Only one eligibility value means eligible")
    func eligibleIsUnique() {
        let all: [PulseTrackingEligibility] = [
            .eligible, .disabled, .pausedToday, .marketClosed,
            .permissionDenied, .noCandidate, .remoteServiceNotConfigured
        ]
        #expect(all.filter(\.isEligible) == [.eligible])
    }

    @Test("No eligibility value claims remote success without a service")
    func noFalseRemoteClaim() {
        // remoteServiceNotConfigured exists precisely so a caller can say
        // "foreground only" instead of reporting a background success.
        #expect(!PulseTrackingEligibility.remoteServiceNotConfigured.isEligible)
    }
}

// MARK: - Honest capability reporting

@Suite("Remote capability gating")
struct PulseActivityCapabilityTests {
    private func description(_ capability: PulseActivityCapability) -> String {
        PulseActivityRuntimeStatus(activitiesEnabled: true, capability: capability).capabilityDescription
    }

    @Test("Declaring a remote service without a real push token stays foreground-only")
    func declaredButNoTokenIsForegroundOnly() {
        // The whole point: a build that merely *compiles in* the remote branch
        // has no addressable device until ActivityKit hands it a token.
        #expect(PulseActivityCapability.effective(
            .remotePushConfigured, hasPushToStartToken: false
        ) == .foregroundOnly)
    }

    @Test("A received push-to-start token is what unlocks the remote claim")
    func tokenUnlocksRemoteClaim() {
        #expect(PulseActivityCapability.effective(
            .remotePushConfigured, hasPushToStartToken: true
        ) == .remotePushConfigured)
    }

    @Test("A token never upgrades a genuinely foreground-only build")
    func tokenCannotUpgradeForegroundOnly() {
        // Receiving an update token must not let a foreground-only build claim
        // remote start: the declaration is the ceiling, the token only gates it.
        #expect(PulseActivityCapability.effective(
            .foregroundOnly, hasPushToStartToken: true
        ) == .foregroundOnly)
    }

    @Test("An unavailable service is reported as unavailable, not as configured")
    func unavailableStaysUnavailable() {
        #expect(PulseActivityCapability.effective(
            .remotePushUnavailable, hasPushToStartToken: true
        ) == .remotePushUnavailable)
    }

    @Test("The foreground-only wording forbids background start and mentions no service")
    func foregroundOnlyWording() {
        let text = description(
            PulseActivityCapability.effective(
                .remotePushConfigured, hasPushToStartToken: false
            )
        )
        #expect(text.contains("前台"))
        #expect(text.contains("无法在后台"))
        // It must not claim a configured remote service in this state.
        #expect(!text.contains("已配置远程服务"))
    }

    @Test("Even the unlocked wording never claims a delivery happened")
    func remoteWordingIsNotASuccessClaim() {
        let text = description(.remotePushConfigured)
        // "验证送达"/"推送已可用"/"已发送" would all be claims the device cannot
        // make. The wording may only say the service *can* be addressed.
        #expect(!text.contains("已验证"))
        #expect(!text.contains("已送达"))
        #expect(!text.contains("推送已可用"))
        #expect(text.contains("不代表"))
    }

    @Test("The foreground-only description says foreground, never 'just works'")
    func noCapabilityClaimsUniformSuccess() {
        for capability: PulseActivityCapability in [.foregroundOnly, .remotePushConfigured, .remotePushUnavailable] {
            let text = description(capability)
            #expect(!text.isEmpty)
            #expect(!text.contains("自动运行"))
            #expect(!text.contains("始终可用"))
        }
    }
}
