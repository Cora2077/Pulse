# PulseMobile — controlled plan, fill, and review operations for the iPhone v2 workbench

`PulseMobile` is a Swift 6 package (iOS 18 / macOS 14) that wraps the **existing
checked `PulseCore` APIs** in the shapes a mobile form needs: frozen drafts,
stable ids, explicit refusals that keep the user's input, and no recomputation of
anything the ledger already answers.

It does not own the ledger. Every write goes through an existing
`WatchlistStore` entry point; this package never replays transactions, recomputes
cost basis, or invents a progress number.

```swift
import PulseCore
import PulseMobile
```

## Why it exists

`WatchlistStore` is the sole publisher of accounts, persistence, and sync
notifications, and it is shared with the Mac app. A mobile sheet has different
needs than a Mac editor — it is dismissed, backgrounded, and resume-launched, and
it must never silently write into a ledger the user is not looking at — so this
package adds exactly three things and nothing else:

1. **Frozen drafts.** A form's state, `Codable` and `Sendable`, safe to hold
   across app launches. Each draft freezes the account it was opened in and the
   revision of the record it was opened from.
2. **Stable ids and idempotent retries.** A fill draft mints one transaction id
   and reuses it on every retry, so a retry is the same event: if the first
   attempt landed without the client seeing it, resubmitting returns that stored
   record rather than writing a second trade. A reused id with different facts is
   refused. Two independent fills at the same price and size are two drafts and
   therefore two events.
3. **Honest refusals.** Every write returns
   `MobileWorkflowOutcome<Draft, Value>`. A refusal carries a specific error
   *and the draft back*, so a form can restore what the user typed. A route this
   build does not wrap returns `.unsupported(...)` rather than approximating the
   store's rules.

## The three workflows

All three are `@MainActor` structs constructed around one store.

```swift
let plans = PlanWorkflow(store: store)
let fills = FillWorkflow(store: store)
let trades = TransactionWorkflow(store: store)
```

### Reading

```swift
// Every plan in the store's own display order (this is store.tradePlanEntries).
let entries: [TradePlanEntry] = plans.entries

// One plan, re-read live against a named ledger.
let entry = plans.entry(symbol: symbol, planID: planID, account: .financing)
```

### Creating and editing a plan

```swift
// New plan: price and quantity start NaN, so the form must supply real values.
var draft = PlanDraft.newPlan(symbol: symbol, in: store)
draft.kind = .buy
draft.price = 12.5
draft.quantity = 100
draft.note = "breakout retest"
draft.positionPool = .tactical
draft.fundingSource = .own          // intent only; never substituted for a fill

switch plans.save(draft) {
case .written(let plan):
    show(plan)
case .refused(let error, let kept):
    showError(error); restoreForm(with: kept)   // nothing was written
}
```

A new-plan draft mints its plan identity once (`newPlanID`). Saving the *same*
draft twice — the first attempt landed but the client never saw the answer —
returns the plan already stored under that identity; it does not file a second
plan, re-stamp `createdAt`, or append a revision. The same identity with
*changed* content is refused with `.stalePlanRevision`, because the draft never
froze a revision of the landed plan; reopen it as an edit. Editing drafts are
untouched by this: their identity is `planID` and their guard is the frozen
revision, which the create-retry path never bypasses.

Both `save` and `setStatus` write through `setTradePlan`, which writes the
store's **selected** ledger — so they refuse with `.accountChanged` (keeping the
draft) when the selection no longer matches the draft's frozen account. A plan
opened against one account is never filed into whichever account happens to be
on screen at save time.

```swift
// Editing an existing plan freezes its exact revision.
guard let entry = plans.entry(symbol: symbol, planID: planID),
      var draft = PlanDraft.editing(entry, in: store) else { return }
draft.price = 11.8

plans.save(draft)   // refuses with .stalePlanRevision if the plan moved
```

`save` starts from the **stored** plan when editing, so `id`, `createdAt`,
`filledTransactionID`, and `history` survive a price correction.
`setTradePlan` appends the prior configuration to `history` itself; this layer
does not duplicate that.

### Closing and reopening

```swift
plans.abandon(entry)   // .cancelled — "I gave up on this plan"
plans.revive(entry)    // .active    — back to waiting
```

**`stop` is not a wrapped route.** `changeTradePlanStatus` accepts exactly
`.cancelled` and `.active`; there is no "mark it done" action anywhere in the
store or the Mac menu, because a `.done` plan is normally *derived* from its
linked fills completing. `plans.stop(entry)` therefore returns
`.unsupported("manually stopping a plan…")` rather than relabelling `abandon` as
`stop`, which would record a decision the user never made.

A `.done` status *can* be written, but only as a plan **edit**:

```swift
guard let draft = PlanDraft.editing(entry, in: store) else { return }
plans.setStatus(.done, on: draft)   // requires a frozen revision
```

### Recording a fill

```swift
guard let entry = plans.entry(symbol: symbol, planID: planID),
      var draft = FillDraft.recording(entry, in: store) else { return }

// draft.price and draft.quantity are nil. They stay nil until the user types
// them — this package never reads a quote, a plan's trigger price, or a
// previous fill into a fill draft.
draft.price = 98.75
draft.quantity = 40
draft.fee = 1.5

switch fills.submit(draft) {
case .written(let transaction):
    markRecorded(transaction)
case .refused(let error, let kept):
    // kept.transactionID is the SAME id — retrying resubmits the same event.
    showError(error); restoreForm(with: kept)
}
```

Submitting with `draft.price == nil` fails with `.fillPriceRequired`. This is
deliberate: `TradePlan` records an *intention*, never a fill, and the store only
sees the number it is handed.

**Retries are idempotent.** `FillDraft.transactionID` is minted once and reused
on every attempt. If a submit actually landed but the client never saw the
answer — a crash, a killed app, a lost confirmation — resubmitting the *same
draft value* returns the record that is already stored, with its original
`createdAt`. It does not mint a second trade and does not re-stamp the clock:

```swift
let submitted = draft            // keep the exact value you submitted
switch fills.submit(submitted) { ... }
// ... app dies, relaunches, the draft is restored from Codable ...
switch fills.submit(submitted) {   // same event
case .written(let transaction):  // the record written the first time
case .refused ...
}
```

The match is exact and total, and it is checked **before** the plan-existence
and plan-state gates — a first fill that completed the plan, or a completed plan
the user afterwards deleted, must not make its own retry look unwritten. The
lookup spans **every** ledger (transaction ids are unique store-wide), because a
cross-account fill is written into its destination ledger, not the frozen
source. A reused id describing *different* facts — price, quantity, fee, date,
funding, destination, note, plan link, or a sale-portion selection the
allocation history cannot prove — is **not** a retry: it is refused with
`.conflictingRetry(id)` and nothing is written. A portion selection is proven
from the allocation change the sale produced (the entry whose `priorRevision` is
the frozen one); a claim that cannot be demonstrated is refused rather than
adopted. Two genuinely independent fills at the same price and size carry
different ids and are always two events; there is no price/size lookup anywhere.

**Backfill** — writing down a fill that happened after the plan was stopped:

```swift
var draft = FillDraft.recording(entry, in: store, backfill: true)!
draft.price = 101
draft.quantity = 30
fills.submit(draft)
```

The store re-derives `canBackfillFill` from its own values, so a stale sheet
gains nothing. A partial backfill leaves the plan `.done` — the user's own
decision survives the entry.

**Standalone fills** — no plan behind them:

```swift
var draft = FillDraft.unlinked(symbol: symbol, kind: .buy, in: store)
draft.destinationAccount = .financing
draft.fundingSource = .own
draft.price = 42
draft.quantity = 100
fills.submit(draft)
```

A standalone **sale** is written into the ledger it names: `destinationAccount`
is the account whose shares it consumes, and it is honoured exactly — never
silently re-pointed at the frozen account the form was opened in. A standalone
sale cannot name portion cards (`addNamedTransaction` has no selection
parameter), so a draft carrying `salePortionQuantities` without a plan is
refused as `.unsupported("standalone sale portion selection")` rather than
validating the rows and dropping them at the write.

### Correcting and deleting a trade

```swift
guard let item = store.item(for: symbol),
      let original = item.transactions.first(where: { $0.id == tradeID }) else { return }

var draft = TransactionEditDraft.editing(original, symbol: symbol,
                                         account: .financing, in: store)
draft.price = 99.5
trades.save(draft)      // refuses .staleTransactionRecord if the record moved
```

The full-edit draft owns every optional metadata field, so clearing one is a
statement: `save` passes `replaceOptionalMetadata: true`, and a cleared note or
review is actually cleared (the store's legacy nil-refill merge is *not*
applied). Clearing the funding annotation stores `.unmarked` — "the user says
this is unclassified" — never `nil`, which reads as "nobody has said anything".
Identity, `createdAt`, the account, and the plan link stay frozen either way.

```swift
trades.delete(symbol: symbol, transaction: original, account: .financing)
```

Both refuse a record that changed since the form was drawn — including a change
made by a **review edit on another device**, which no timestamp comparison would
catch. That is why the frozen original is the whole record and not just a date.

### Writing a review

Open the draft **from the stored record**, so it freezes what it is about to
overwrite:

```swift
let draft = ReviewDraft.editing(storedTransaction, symbol: symbol)
draft.note = "executed at the open"
draft.review = PositionTransactionReview(
    followedPlan: true,
    retrospective: "held to plan",
    strategy: "size up next time",
    nextReviewDate: someDate,
    nextReviewNote: "watch earnings"
)
trades.saveReview(draft)      // refuses .staleTransactionRecord if it moved
```

The review route writes only the note and the review. Ledger values, dates, and
order are untouched, and plan-linked market values still cannot be changed
through it. Saving the same review twice succeeds as a no-op rather than
reporting an error.

`saveReview` is guarded even though `updateTransactionReview` is not.
`WatchlistStore.updateTransactionReview` addresses a record by **id alone** and
writes the **selected** ledger, so on its own it would overwrite a review another
device wrote in the meantime. The draft's frozen record is the guard:

- a draft carrying **no** `expected` record is refused with
  `.staleTransactionRecord` — an unchecked write through this route is the hazard
  the freeze exists to stop;
- a draft whose record changed is refused the same way, and the user's text comes
  back in `outcome.draft`;
- naming an `account` other than the selected ledger is refused with
  `.accountChanged`, because the store would write a different ledger than the
  one the check just read;
- a note longer than the store's 4,000-character limit is refused before the
  write — the store's review route answers `false` rather than throwing, so the
  limit the value routes enforce is applied here.

## Refusal semantics

`MobileWorkflowOutcome` is not a `Result`: the failure case carries the draft.

```swift
public enum MobileWorkflowOutcome<Draft: Sendable, Value: Sendable>: Sendable {
    case written(Value)
    case refused(MobileWorkflowError, draft: Draft)

    var value: Value? { get }
    var error: MobileWorkflowError? { get }
    var draft: Draft? { get }
    var didWrite: Bool { get }
}
```

`MobileWorkflowError` keeps two families apart:

- `.unsupported(route)` — this build does not wrap that path. The associated
  string names it precisely, so a caller can tell "not built yet" from "refused".
- everything else — a real refusal the user can act on: `.stalePlanRevision`,
  `.staleTransactionRecord`, `.conflictingRetry`, `.accountChanged`,
  `.accountModeChanged`, `.destinationNotAllowed`, `.fundingNotAllowed`,
  `.fillPriceRequired`, `.negativePosition`, `.immutablePlanContext`, and so on.

A refusal **never** leaves a partial write. Each check runs before the store is
reached, and the store's own routes validate a complete candidate before
publishing anything.

## What this layer deliberately does not do

| Not done | Why |
| --- | --- |
| Fill in a price or quantity | The store cannot enforce this; the rule lives at the one place a mobile fill is assembled. There is no quote, plan-price, or last-fill fallback anywhere. |
| Pick an account | `nil` means "whichever is selected", which is the silent redirect the frozen `AccountFreeze` exists to prevent. Every ledger read is scoped to the frozen account, and a moved selection is refused. |
| Move a plan fill to another ledger's source | `recordTradePlanFill` searches the selected ledger and hardcodes its source, so there is no parameter for it. A frozen-draft mismatch is refused rather than re-pointed. |
| Recompute progress, remaining size, or available shares | Every one of those has an existing reader — `TradePlanEntry`, `TradePlanExecutionProgress`, `availableSalePlanQuantity`. A mobile copy would be a second accounting rule. |
| Write `.done` as an *action* | `changeTradePlanStatus` refuses it. Use `setStatus(_:on:)` on an edit draft, or `abandon` for the close-without-filling action. |
| Standalone or plan-linked **calibration** (`.adjustment`) | Both store routes refuse it; the only path that accepts it is import/calibration, which is not a mobile form. Returns `.unsupported`. |
| Standalone sale **portion selection** | `addNamedTransaction` has no selection parameter, so the named cards could be validated and then silently dropped. Returns `.unsupported`; only plan-linked sales carry portions. |
| Re-wrap condition normalization | `TradePlanCondition.normalized()` is internal to PulseCore. The store performs the real check; this layer only catches what is publicly observable (duplicate ids, empty titles) so a rejection has a message. |
| Delete a plan without naming its account | `deleteTradePlan(_:for:account:)` addresses a named ledger. A confirmation sheet that outlived an account switch must not remove a same-id plan from a ledger the user never opened. |

## Account and revision freezing

Every draft carries an `AccountFreeze`:

```swift
public struct AccountFreeze {
    let account: BrokerageAccountID
    let brokerageAccountsEnabled: Bool
}
```

`matches(_:store)` compares both facts against the live store. The ordering flag
is part of the freeze because "brokerage accounts are enabled" decides whether
`.unassigned` is even a legal destination — a draft opened before that setting
flipped must not silently acquire the new meaning. It is `Codable`, so it
survives the relaunch that makes the check necessary.

**Every ledger read is scoped to the frozen account, and a moved selection is
refused for plan-linked and standalone fills, plan saves, and status edits
alike.** This matters because the store's own readers are selection-scoped:

- `WatchlistStore.item(for:)` and `retainedHistoryItem(for:)` read the *selected*
  ledger. A wrapper that used them would resolve a namesake plan in whatever
  ledger happened to be on screen.
- `recordTradePlanFill` searches `allItems` — the selected ledger — and hardcodes
  `source = activeBrokerageAccountID`. There is **no** parameter that aims a plan
  fill at a named ledger's source, so a mismatch cannot be worked around by
  naming another account: it must be refused.

So `FillWorkflow` resolves a draft's ledger from its freeze via
`brokeragePortfolio(for:)` (the named-ledger accessor, which does not change the
selection) and refuses with `.accountChanged` / `.accountModeChanged` /
`.accountUnavailable` when the store no longer matches. The user's typed price and
size come back untouched. The same discipline applies to `TransactionWorkflow`'s
named-ledger reads, to `PlanWorkflow.entry(symbol:planID:account:)` reading both
the plan and its fills from the ledger asked about, and to `PlanWorkflow.save` /
`setStatus`: because `setTradePlan` can only write the selected ledger, a plan
draft whose frozen account is no longer selected is refused with the draft kept.
`abandon` / `revive` / `delete` address the entry's account **by name** — their
preflight reads that ledger, never the selection, so a namesake plan in the
selected ledger is never judged or touched.

A **destination** is a separate, explicitly chosen thing and may legitimately
differ from the frozen source: a buy may be filed into a chosen account, and a
sale may consume shares held in another. `recordTradePlanFill` records the plan's
own ledger as `sourceAccountID` while writing the fill into the destination, and
the wrapper passes the destination through unchanged — the source stays fixed.

Plan drafts additionally carry a `PlanRevisionStamp` — the plan's `updatedAt`
**and** a content digest. The digest is a real **SHA-256 over a deterministic,
complete `JSONEncoder` encoding** (`sortedKeys`, pinned date strategy) of the
whole plan, so it covers `history`, every condition and its linked
`InstrumentEvent`, and any field added to `TradePlan` later, with no hand-picked
field list to fall out of date and no separator for free text to forge. Because
the encoding is not hand-ordered, a reordered condition array is a real change
and moves the digest. If a plan is genuinely not encodable the digest is the
sentinel `PlanRevisionStamp.unencodableDigest` and `matches` **fails closed** —
an unreadable revision is never honoured.

The timestamp alone is what the store compares (`expectedPlanUpdatedAt`); the
digest catches what that comparison cannot, such as a peer revision that changed
content without moving the clock (a sync merge is the real route for this).
Transaction edit drafts carry the whole `PositionTransaction` as their stamp,
because that is exactly what `updateTransaction(_:expected:account:)` compares.

## Testing

Focused tests run against isolated `UserDefaults` suites only — never
`.standard`, never a real account:

```sh
swift test --package-path Packages/PulseMobile --disable-sandbox \
  --scratch-path /tmp/fff-ios-mobile-workflows-build
```

`--disable-sandbox` is required when the DSH file sandbox blocks `sandbox-exec`,
which SwiftPM needs to compile manifests; it is about the local build process and
does not change what the tests touch. `--scratch-path` keeps this package's build
out of the shared derived data.

`MobileFixture.isolatedStore()` creates a store over a fresh suite, enables named
ledgers, selects `.financing`, adds a fictional symbol, and every test removes
its own persistent domain on the way out. `MobileFixture.replaceStoredPlan`
writes a plan through the store's own peer-snapshot route
(`applySyncSnapshot`), which is how a test constructs "content moved, clock did
not" — `setTradePlan` always re-stamps `updatedAt` and so cannot produce it.

The suite is **85 tests in 5 suites**, covering the four hardening areas: account
switching for plan-linked and standalone drafts (including a namesake plan in the
other ledger), idempotent retries across a simulated relaunch, after the plan
completed, after the plan was deleted, and across ledgers (including a
cross-account sale's portion proof), conflicting retries (values, note, plan, and
portion intent), digest completeness and fail-closed behaviour, and stale/absent
review expectations. iOS 18 is verified by cross-compiling:

```sh
swift build --package-path Packages/PulseMobile --disable-sandbox \
  --scratch-path /tmp/fff-ios-mobile-ios-build \
  --triple arm64-apple-ios18.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"
```

## Integration notes for the app layer

- Add `Packages/PulseMobile` to `project.yml` and the iOS target. This package
  does not edit `project.yml` or any app file.
- Construct one workflow per store. They are stateless value types; there is
  nothing to keep alive.
- The wrappers are `@MainActor` because `WatchlistStore` is.
- `PlanDraft`, `FillDraft`, `TransactionEditDraft`, and `ReviewDraft` are
  `Codable`, so a form can persist its draft and resume after a relaunch — which
  is precisely when the frozen revision and account checks start mattering.

## Known uncovered paths

- `.adjustment` calibration, plan-linked and standalone (reported
  `.unsupported`; not implemented).
- Manually setting a plan to `.done` as a list *action* (reported
  `.unsupported`; `setStatus(_:on:)` covers the edit intent only).
- Standalone sale **portion selection** (reported `.unsupported`; the store's
  standalone sale route cannot store the selection — only plan-linked sales
  carry portions).
- Cross-account **sale** execution (`brokerageAccountID` naming a ledger other
  than the plan's) is passed through to the store, which owns its rules; this
  layer checks the account freeze and the executing ledger's allocation revision
  but does not reproduce `recordCrossAccountPlanSale`'s own validation.
- Sync conflict resolution. That belongs to `PulseSync`.

## Hardening changes — API additions and integration notes

The following are the real, breaking-for-callers changes made in this pass. All
are additive except where noted; nothing in `PulseCore` or the app targets was
touched.

**New on the draft models**

| API | Note |
| --- | --- |
| `ReviewDraft.expected: TransactionRevisionStamp?` | New stored property. A `ReviewDraft` built without it is now **refused** by `saveReview`. Build drafts with the new factory. |
| `ReviewDraft.editing(_:symbol:)` | New factory: freezes the stored record. Use this instead of the memberwise initializer. |
| `PlanRevisionStamp.unencodableDigest` | Sentinel for a plan whose canonical encoding failed. `matches` returns `false` for such a stamp. |
| `PlanRevisionStamp.canonicalEncoding(of:)` | Internal; exposed for tests to assert determinism directly. |
| `FillDraft.describes(_:)` | Public. Whether a stored record *is* the event this draft already states. Now also compares the normalized note and the plan link (plan id and named source), and the retry path additionally proves a named sale-portion selection from the allocation history of the ledger the record lives in. |
| `FillDraft.submittedDestination` / `submittedFundingSource` | Public helpers mirroring what a submission writes. |
| `PlanDraft.newPlanID: UUID?` | New stored property, minted once by `newPlan(symbol:in:)`. The identity a new plan keeps across retries of the same draft: a repeated `save` adopts the landed plan instead of minting a second one, and changed content under the same identity is refused. Optional, so drafts persisted by an older build still decode (they keep the old mint-per-save behaviour, with the store's id-uniqueness as backstop). |
| `MobileWorkflowError.conflictingRetry(UUID)` | New case: a reused id describing different facts. Add it to any exhaustive `switch`. |

**Changed signatures (batch-update required)**

- `TransactionWorkflow.saveReview(_:account:)` now returns
  `MobileWorkflowOutcome<ReviewDraft, PositionTransaction>`; it previously
  returned `MobileWorkflowOutcome<ReviewDraft, PositionTransactionReview?>`. The
  success payload is now the **stored record**, so a caller can read back the
  note/review the store actually saved rather than a rebuilt guess. It also now
  refuses a draft with no `expected`, a draft whose record moved, and a named
  `account` other than the selected ledger (`.accountChanged`).
- `FillWorkflow.linkedFills(symbol:planID:account:)` — `account` is now a
  **required** `BrokerageAccountID`, not `BrokerageAccountID? = nil`. A summary
  about a draft's plan must name the ledger it is about; passing the selection
  implicitly is what the hardening removes.
- `PlanWorkflow.entry(symbol:planID:account:)` keeps its signature but now reads
  the plan **and its fills** from `account` (previously the plan came from the
  selected ledger). This is a behaviour change, not a compile error.

**Behaviour changes with no signature change**

- `FillWorkflow.submit` applies the account freeze to plan-linked fills exactly
  as it already did for unlinked ones. A plan draft submitted after a global
  account switch is refused with `.accountChanged` (or `.accountModeChanged` /
  `.accountUnavailable`) and the input is returned — where it previously wrote
  into whatever ledger was selected.
- `FillWorkflow.submit` recognises an already-written retry **before** the
  plan-existence, plan-state, and plan-revision gates, and searches **every**
  ledger for the id: a retry of a fill that completed the plan, of a fill whose
  plan was since deleted, and of a cross-account fill written into its
  destination ledger all succeed and return the stored record.
- `FillWorkflow.submit` refuses a plan-scoped draft that froze **no** plan
  revision (`.stalePlanRevision`) instead of falling back to the live plan's
  `updatedAt` — the fail-open gap is closed, matching the review draft's
  mandatory expectation.
- `FillWorkflow.submit` writes a standalone sale into the destination ledger
  the draft named; it previously consumed the frozen account regardless. A
  standalone sale carrying `salePortionQuantities` is refused as
  `.unsupported`.
- `FillWorkflow.destinationLedger(for:)` resolves through the frozen account.
- `PlanWorkflow.save` and `setStatus(_:on:)` refuse with `.accountChanged` when
  the store's selection no longer matches the draft's frozen account, keeping
  the draft. They previously wrote the plan into whichever ledger was selected
  (a behaviour an earlier test pinned; the contract is now the freeze, aligned
  with `delete` and with the iOS `savePlan` guard).
- `PlanWorkflow.abandon` / `revive` read the entry's **named** ledger for the
  liveness and availability preflight, never the selection; the write was
  always named-ledger-correct.
- `PlanWorkflow.save` writes a new plan under the draft's `newPlanID` and
  adopts the landed plan on an identical retry (see the model table).
- `TransactionWorkflow.save` passes `replaceOptionalMetadata: true`: clearing
  the note or review now actually clears them, and clearing funding stores
  `.unmarked` rather than `nil`. Values, identity, and plan links are
  unchanged by this.
- `TransactionWorkflow.saveReview` refuses a note over the store's
  4,000-character limit before writing.
- `PlanRevisionStamp.matches` and `digest(of:)` use the new complete encoding.
  Any `contentDigest` string persisted by an older build will no longer match;
  a resumed draft from before this change is correctly treated as stale and must
  be re-opened. This is the intended fail-closed direction.
- `TransactionWorkflow.saveReview` no longer treats the store's `false` as
  unconditionally successful: `false` is only a success once the record and
  payload have been verified, and the return value reports the stored record.

**Integration cautions for the app layer**

- `ReviewDraft` must be produced by `ReviewDraft.editing(_:symbol:)`; a
  hand-built draft without `expected` will refuse every save.
- `FillWorkflow.submit` must be called with the *same draft value* to be a retry.
  Calling `FillDraft.recording(_:in:)` again mints a new trade date and a new
  draft, which is honestly a different event — persist and reuse the draft.
- When the app switches the global account while a fill sheet is open, keep the
  sheet and surface the refusal; do **not** silently rebuild the draft against
  the new selection, which is the silent redirect this hardening prevents.
- `Task`/`async` callers: all three workflows remain `@MainActor`.
