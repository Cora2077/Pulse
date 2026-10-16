# iPhone v2 implementation ownership and integration contract

2026-10-16. Lead owns architecture, financial-data safety, all existing-file edits, Xcode project/build integration, application state integration, review and actual simulator acceptance. Do not alter the running Mac app or its real data. All new previews/tests use isolated data.

## Parallel workers (current: WorkBuddy Step-5-Preview; Kimi K3 for hard tasks)

The user changed routine workers to `step-5-preview` on 2026-10-16 after the plugin catalog reported multiplier 0. Do not start new DeepSeek 4.1 tasks. Kimi K3 is explicitly permitted for difficult implementation and independent review. Older model names in historical briefs describe previous runs, not the current assignment.

- **mobile-workflows** owns only `Packages/PulseMobile/**`: package, frozen account/version draft models, checked plan/trade/review workflow wrapper over existing PulseCore, focused tests. It must not rewrite the ledger or change PulseCore. Expose an API and a usage sample; Lead integrates the UI.
- **activity-surfaces** owns only `Packages/PulseActivity/**` and `PulseWidgets/**`: shareable Codable activity payload, pure automatic tracking policy/pause/staleness tests, iOS ActivityKit lifecycle coordinator and WidgetKit/Dynamic Island/Watch small-family layouts. No ledger writes or default network registration. Publish a precise public API; Lead owns target embedding and app integration.
- **snapshot-sync** owns only `Packages/PulseSync/**`: stable revision/operation identifiers, durable pending snapshot/baseline, transport abstraction, strict optimistic concurrency, CloudKit private single-record/asset implementation and in-memory transport tests. No existing-file edits, no real iCloud access. Lead integrates both applications.

Scopes do not overlap. If another scope needs a change, report the exact required change instead of editing it. Existing uncommitted work is intentional. Do not reset/checkout, sign/install, commit/push, read credential stores, or touch real account files.

## Required shared semantics

- No auto trading. A plan, its price condition, manual conditions and its recorded execution progress are separate things.
- Real fill price is user-entered, never silently filled from a plan/quote. Actual execution account must be explicit and frozen while drafting.
- Every write uses existing checked PulseCore APIs and freezes the original record/revision; retain draft on error. Shared financing/source-card/oversell constraints remain authoritative.
- Retries keep stable operation/transaction IDs; two independent same-price/same-size fills are not the same event.
- Sync financial conflicts fail closed: no silent LWW and no local pending data overwritten by a remote snapshot. A full snapshot must commit atomically. Idempotent retry only when both operation ID and content agree.
- Automatic tracking preferences persist; held OR active-plan OR pinned candidates qualify. Today pause and permanent disable differ. Permission/missing service states are honest. No recurring manual start as the normal UX.
- Activity payload contains public quotes and redacted pending-plan count only by default. Source time/stale state are real; no fake current time. Activity and Watch views do not mutate transactions.
- No private keys, tokens or actual accounts in files, fixtures, logs or examples.

## Build coordination

Lead owns `project.yml`, PulseIOS app files, all existing packages/files and the default Xcode derived data/builds. Workers should run their focused package tests with an isolated `/tmp/fff-ios-<scope>-build` scratch path to avoid shared-build collisions. No worker invokes Xcode generation or touches generated project files.

## End state, not a mock milestone

The approved functional scope is documented in [v2 design](../iphone-plan-2026-10-16/README.md). Core screens and plan/fill flows need real state/persistence, not fixed arrays disguised as application behavior. CloudKit/APNs readiness must distinguish implementation/build verification from real-device/user-account integration. No claim of remote automatic start without permissions, tokens and a configured service.
