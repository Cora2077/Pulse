# iPhone implementation status — Lead checkpoint

> **当前接力说明以 [HOME-HANDOFF.md](HOME-HANDOFF.md) 为准。** 以下保留早期验收历史，含旧的完成表述；不能据此宣称最新 Mac 还原工作已全部结束。2026-10-16 下班前已补入 iOS 源码的 Git 跟踪，真实账本和模拟器私有数据不随源码上传。

Updated 2026-10-16 ~14:12 Asia/Shanghai. Final in-environment acceptance complete. Not a physical-device release claim: real CloudKit two-device CAS, APNs round-trip, Watch mirroring and physical install remain external gates (below). No actual iCloud/APNs call, physical-device install, purchase, commit/push or user-ledger import has occurred. Mac compile used the existing stable signer and did NOT replace the daily installed app.

## Final verified evidence

- Core: **1021 tests / 99 suites passed** — `/tmp/fff-core-final-tests.log`.
- PulseMobile: **85 tests / 5 suites passed** — `/tmp/fff-mobile-current-tests.log`.
- PulseSync: **52 tests / 8 suites passed** (final, including conflict-confirmation validation) — `/tmp/fff-sync-final-tests.log`.
- PulseActivity: **101 tests / 12 suites passed** (final, including corrupt automatic-start budget fails closed across relaunch and new sessions) — `/tmp/fff-activity-final-h.log` after corrupt-budget fix; earlier run `/tmp/fff-activity-corrupt-budget.log`.
- Node push bridge: **152 tests passed** — `/tmp/fff-push-source-capability-tests.log`.
- Native app (H, final): **12 unit + 5 UI tests all passed** — result `/tmp/fff-ios-results-20261016-h`, log `/tmp/fff-ios-final-h.log`. Includes app-level sync race/backup tests, push-configuration safety tests (no credential in endpoint, no credential reuse across endpoints, demo environment cannot configure remote service), blank actual-fill price, partial-fill progress, dark + accessibility-large text, and **system-confirmed automatic ActivityKit start** (test asserts the OS reports exactly 1 activity; `liveactivitiesd` logs confirm "Starting activity … state: active" and repeated updates; staleness expiry at 5 min works as designed).
- Small-screen acceptance: iPhone 18 Pro (1206pt wide) — 2 core UI tests passed, screenshots visually inspected — result `/tmp/fff-ios-small-pro`.
- Dark/accessibility screenshots visually inspected and saved under [acceptance evidence](../verification/iphone-acceptance-20261016/). All are explicit synthetic demo data.
- App icon: fixed after the screenshot exposed a black PNG (3-channel bitmap has no AppKit context); now verified opaque 1024² and compiled into `Assets.car` (2 AppIcon renditions).
- Mac final build after all shared changes: **BUILD SUCCEEDED**, stable signer — `/tmp/fff-mac-final-h.log`.
- Public source smoke (13:12): Samsung / SK Hynix / THS bank all returned real prices with source timestamps, ages 0/0/2 s.
- `git diff --check` clean; `scripts/dev-ios.sh` and `scripts/dsh-worker.sh` syntax valid; helper end-to-end `--run --demo` passed (bash-127).

## Still external (not done here, must not be claimed)

- Dynamic Island visual: the OS confirms the activity is active and updated; screenshots do not show island content (simulator rendering limitation/transition masking). Lock-screen and island visuals on a **physical iPhone** remain to be confirmed.
- Watch Smart Stack mirroring: `.supplementalActivityFamilies([.small])` is implemented, but replication requires real paired devices — unverified.
- APNs: backend emits full Apple contract (attributes-type, attributes, alert, input-push-token, correct inner date unit), tested against fake transport only. Real push-to-start/update round-trip needs signed entitlement + physical device.
- iCloud: CloudKit transport is implemented and tested with locally constructed CKRecords; real two-device sync requires the user's authorized container and signed builds — never accessed.
- Advanced mixed-portion sale selection and position adjustments remain explicitly refused (not silently dropped) in iPhone forms.

## Goal disposition

All in-environment work is complete: built, tested, simulator-accepted on two device sizes + dark/large-text; external conditions are documented. Goal `goal-23fcd4d4-3c67-4f47-9ffb-6185f6fe9597` may be marked complete. No background jobs remain.


## Current verified evidence

- Core: **1021 tests / 99 suites passed**. Log `/tmp/fff-core-final-tests.log` (bash-110 collected).
- PulseMobile: **85 tests / 5 suites passed**. Log `/tmp/fff-mobile-current-tests.log` (bash-101 collected). Actual app now uses these wrappers; ephemeral `acceptedTrades` cache removed.
- PulseSync: **52 tests / 8 suites passed** before the latest additional confirmation-validation callback. Log `/tmp/fff-sync-current-tests.log` (bash-102 collected). Needs final rerun after last API addition.
- PulseActivity: **101 tests / 12 suites passed** before the latest iOS-specific token/dismissal observer wiring. Log `/tmp/fff-activity-current-tests.log` (bash-103 collected). Native iOS compile also covered later observer code; final package rerun still desirable.
- Native application-level XCTest: **8 passed**, including three real app-controller sync/backup tests. Result `/tmp/fff-ios-unit-results-20261016-e`; log `/tmp/fff-ios-unit-final.log` (bash-116 collected).
- Latest fully settled native unit+UI baseline: `/tmp/fff-ios-ui-results-20261016-c` passed 5 application unit tests + 3 actual UI tests (bash-99 collected).
- Run D added dark/accessibility UI coverage: its **4 UI tests passed**, but its new app-level sync tests FAILED. The failure exposed a REAL directory-URL trailing-slash comparison bug that blocked applied metadata and conflict backups. Fixed the containment checks using normalized absolute paths, then verified all three app sync tests in E. D stalled in failure-diagnostics collection after test cases finished and was cancelled/collected (bash-111); do NOT report D as an overall pass.
- Node backend: **153 tests passed** after Lead integrated independent quote refresh, in-flight registration guards, pre-send start budget reservations, proper start attributes/alert, default Swift Codable date output, index units/plan revision passthrough, and update-token-only ends. Log `/tmp/fff-push-final-tests.log`.
- Actual public-endpoint smoke at ~13:12:12 CST: Samsung `005930.KS`, SK Hynix `000660.KS`, THS bank `881155.SH` all returned finite prices and their own source timestamps, with measured source ages 0/0/2 sec. No credentials or APNs involved. These were REAL source probes, separate from synthetic app acceptance screenshots.
- Mac target built successfully with stable local signer (bash-109 collected), but more Mac UI/shared sync edits followed: final Mac rebuild still required. Log `/tmp/fff-mac-integration-build.log`.

## Latest full acceptance and current jobs

- **F passed and collected (bash-117)**: 8 application unit tests + 4 UI tests, including the new application-sync races/backups and dark/large text. Result `/tmp/fff-ios-results-20261016-f`, log `/tmp/fff-ios-full-final.log`.
- Actual default/dark simulator screenshots have been visually inspected and copied to [acceptance evidence](../verification/iphone-acceptance-20261016/). They show synthetic demo data explicitly, not the user's account.
- A simulator attempt to inspect the Dynamic Island after launching the demo with automatic activity enabled showed the app's local status but did NOT provide positive visual evidence of the island outside the app. Do not present `/tmp/fff-native-dynamic-island.png` as a successful surface screenshot. This needs further diagnosis or real-device verification.
- **bash-123 passed and collected**: final Mac compile after latest shared/UI edits, `/tmp/fff-mac-final-build.log`. Stable signer, no daily install.
- **bash-124 passed and collected**: final PulseSync package tests, **52 tests**, `/tmp/fff-sync-final-tests.log`.
- **bash-125 passed and collected**: final PulseActivity package tests, **101 tests**, `/tmp/fff-activity-final-tests.log`.
- **bash-127 passed and collected**: simulator helper end-to-end `--run --demo`, `/tmp/fff-ios-helper-run.log`. The real demo app is left open in the simulator. No active background verification/worker jobs remain.
- `git diff --check` and both helper shell syntax checks passed. No duplicate Xcode job is running.

## Implementation now integrated

- [App state](../../PulseIOS/Sources/App/IPhoneAppState.swift): real store/providers, checked PulseMobile plan/fill/edit/review wrappers, stable draft IDs and expected records, blank actual-fill price, frozen source vs explicit executing account. No broker orders.
- [Shared application sync adapter](../../SharedAppSupport/SnapshotSyncController.swift): exact applied remote parent frozen at local change time; explicit ancestry between consecutive local operations; serial submission; no racing remote UI overwrite; startup crash-window recovery; explicit conflict choices with both snapshots backed up before resolution; protected metadata files. Directory URL containment bug is now covered by real iOS app tests.
- Sync actor: exact(nil) parent, reentrancy protections, persistence failure honesty, CloudKit metadata/payload validation, and explicit remote/pending versions for conflict confirmations. New optional `validateConfirmation` callback checks UI-generation changes across a resolution fetch.
- iPhone and Mac both use the shared controller. Mac CloudKit is explicit opt-in, requires authorized build container, first makes a manual backup, and refuses dual-master operation with existing FolderSync. Mac UI toggle is restart-applied, current daily app untouched.
- Actual settings expose iPhone conflict handling and private push-service configuration. Bearer stored only in this app's Keychain after user-local input; default initialization does not read Keychain or request a service. HTTPS only except DEBUG loopback, redirects denied, root endpoint validation, no credential reuse across unknown endpoints.
- Activity binding uses held OR active-plan OR pinned; one-time persistent automatic preference, market-day pause, actual unit/currency and independent plan-sync timestamp. Widget scheme now matches `fff-pulse`; native instrument/plan links open read-only app routes.
- Activity coordinator now observes remotely created activities via `activityUpdates`, observes local lifecycle too, prevents treating programmatic end as a user dismissal, and uses a separate push-start-observer flag rather than confusing any existing token task with that observer. Token relay after background remote start can use the REAL activity content even without a fresh foreground quote.
- Actual app icon exists; candle touch pinch/long-press crosshair implemented. Dark/accessibility layout rendered via a synthetic-demo-only launch flag; still must inspect exported screenshots rather than rely on UI assertions alone.
- [Simulator helper](../../scripts/dev-ios.sh) builds/runs/tests only a simulator. End-to-end `--run --demo` still needs final check.

## Model/workers history

Routine workers changed to Step-5-Preview per user; no new DeepSeek 4.1 workers. Kimi K3 completed difficult financial and sync fixes and native-wire review. Step tasks for public-source/client/app-binding/delivery remained in long speculative work; Lead explicitly cancelled them and completed integration directly. All their job outputs have been collected; no hidden worker is still writing these files.

## Remaining acceptance/known boundaries

- Collect F; inspect real default and dark/large screenshots, make visual fixes if needed. Run final Mac build, Sync/Activity package tests, backend suite, and `git diff --check`.
- Public source is now implemented and wired, but service docs still have OLD unsupported-market/client-decoder claims. Update them to native default-Date wire, actual supported sources, full `.push-type.liveactivity` topic and conservative start-attempt budget semantics. Keep default source `client` honest: it still cannot independently refresh.
- Native push-service readiness should explicitly distinguish public-source refresh vs client snapshot mode. Existing local-only activity -> newly configured push-capable activity handoff needs targeted real-device verification; do not claim uninterrupted APNs delivery from simulator tests.
- Automatic-start ledger corruption still needs a narrow audit: an existing pure test says corruption reads as empty budget; do not equate that with a fail-closed safety guarantee.
- Advanced mixed-portion sale selection and position adjustments remain explicitly unsupported in the iPhone forms. Existing checked Core rules refuse rather than silently dropping those facts. Review editor preserves checkpoint fields it never displays.
- Real iCloud two-device CAS, paid signed push entitlement, APNs start/update/end on a physical iPhone, Apple Watch Smart Stack mirroring, and the actual iPhone install are external gates, NOT verified. Do not purchase/sign into Apple accounts or request secrets in chat.
- Current iOS source is local-only under the repository's pre-existing `/PulseiOS/` ignore rule (case-insensitive filesystem). Do not silently remove that publishing policy or commit it. `.dsh-home` now explicitly ignored to prevent accidental publication of local worker/account state.

## Runtime

Booted iPhone 18 Pro Max simulator `7242C29C-F1E0-4FE8-9D5A-1661D6E5D113`, iOS27; deployment iOS18. Paired Watch simulator exists but remains unverified. Goal `goal-23fcd4d4-3c67-4f47-9ffb-6185f6fe9597`, revision 5, armed after human “继续”. Continue real integration work; do not mark complete just because the app compiles.
