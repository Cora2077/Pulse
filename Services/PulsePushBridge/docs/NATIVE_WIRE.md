# Native wire contract — Live Activity push payloads

This document is the precise, test-backed contract for the bytes the bridge
puts on the APNs `liveactivity` wire. It exists because the previous contract
claimed the device-side decoder could be configured with `.secondsSince1970`.
It cannot, and this file records what is true instead, with the native proof
that backs it.

## Official basis

Apple, *Starting and updating Live Activities with ActivityKit push
notifications*
(<https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications>):

> Set the fields for the `content-state` key to match your custom
> `ActivityAttributes.ContentState` type … Additionally, don't use any custom
> JSON encoding strategies to encode your data, because **the system always
> decodes JSON payloads for Live Activity updates using its default encoding
> strategies**. Custom encoding strategies will result in update failures.

There is no API — not in the app, not in the widget extension — that installs a
decoder for a push-delivered `content-state`. The decode happens inside the
system, against `PulseActivityAttributes.ContentState` (= `PulseActivityState`,
whose `Date` properties use default `Codable`), with `JSONDecoder`'s default
date strategy. That strategy interprets a bare number as **seconds since
2001-01-01T00:00:00Z**, and default `JSONEncoder` writes the same.

Consequence: a `Date` inside `content-state` written as UNIX seconds is decoded
31 years in the future (a 2026 instant becomes 2057), and a payload whose
`Date` fields are missing entirely fails to decode and the update is dropped.
Both failure modes existed; both are fixed at the source — the bridge — not by
any client decoder setting, which does not exist for this path.

## The two clocks on one wire

| Location | Unit | Consumer |
|---|---|---|
| `aps.timestamp` | **UNIX seconds** (1970) | APNs itself |
| `aps["stale-date"]` | **UNIX seconds** (1970) | APNs itself |
| `content-state.quoteSourceTime` | **2001-reference seconds** | system default decode → `Date` |
| `content-state.staleDate` | **2001-reference seconds** | system default decode → `Date` |
| `content-state.primary.quoteSourceTime` | **2001-reference seconds** | system default decode → `Date` |
| `content-state.plans.asOf` (when present) | **2001-reference seconds** | system default decode → `Date?` |
| `content-state.*Unix` mirrors | UNIX seconds (1970) | service-side diagnostics only; the native decoder ignores unknown keys |

The offset between the clocks is exactly `978307200` seconds
(`APPLE_REFERENCE_DATE_UNIX_SECONDS` in `src/util.js`). Conversion is a change
of **unit, never of time**: the source instant the client stamped is the
instant the device renders. No code path moves a source time to "now".

The `*Unix` mirrors (`quoteSourceTimeUnix`, `staleDateUnix`,
`primary.quoteSourceTimeUnix`) are kept on the wire deliberately: they are
unambiguously named, the system decoder ignores them, and they make a pushed
body inspectable without mental arithmetic. They are never what the device
decodes as a `Date`.

## Key names

The pushed `content-state` carries the Swift property names
(`quoteSourceTime`, `staleDate`, `primary`, `plans`, `status`, `sessionID`),
because the system decodes it as `PulseActivityState`. Enum values are the
Swift raw values (`live`, `regular`, `pending`, …).

## Input side (unchanged)

Dates the client uploads remain explicitly tagged and are converted once to
UNIX seconds for internal arithmetic:

```json
{ "encoding": "unixSeconds",           "value": 1700000000 }
{ "encoding": "appleReferenceSeconds", "value": 721692800 }
{ "encoding": "iso8601",               "value": "2026-10-16T13:30:00Z" }
```

The 2001-reference conversion happens exactly once, at the APNs boundary in
`materializeState`, and `checkApsShape` refuses to send a `content-state`
whose native date fields are missing or not finite numbers.

## `currencyCode: "POINTS"`

An index level is not a money amount. For the iOS main target (KOSPI / sector
indices) the bridge accepts `currencyCode: "POINTS"` as the explicit
index-points unit sentinel:

- It is matched **literally** — the only non-ISO value accepted. The general
  rule (`^[A-Z]{3,4}$`, e.g. `CNY`, `KRW`, `USDT`) is not widened.
- A points-quoted instrument keeps its own precision; it is never subject to
  the whole-unit formatting of its market's currency (a KOSPI index of
  3245.67 keeps its decimals even though KRW equities are whole-won).

## Native golden proof

`test/native-wire.test.js` pins the bridge's output against evidence produced
by Apple Swift 6.4 Foundation on macOS, compiled against the **real**
`PulseActivityState` from `Packages/PulseActivity`:

- `test/fixtures/native-date-content-state.json` — the exact APNs body the
  bridge emits for one fixed registration (T0 = 1700000000 UNIX).
- `test/fixtures/native-date-golden.json` — the Swift-side evidence:
  - a plain `JSONDecoder()` (default strategies — the system decode) decoded
    the fixture's `content-state` into the real `PulseActivityState` and
    recovered every intended instant exactly;
  - re-encoding that state with a plain `JSONEncoder()` reproduced the
    bridge's wire date numbers exactly;
  - the default encoder's output for five golden instants (including the 2001
    epoch → `0` and the UNIX epoch → `-978307200`) matches the bridge's
    `unixSecondsToAppleReference` on every one;
  - the outer `aps.timestamp` / `aps["stale-date"]` were recorded as UNIX.

Regeneration procedure (requires a macOS Swift toolchain; never hand-edit the
fixtures — the suite fails if the fixture and the code drift apart):

```sh
mkdir -p /tmp/pulse-golden
node /tmp/pulse-golden/emit-body.cjs /tmp/pulse-golden/native-date-content-state.json
swiftc -O -o /tmp/pulse-golden/golden \
  Packages/PulseActivity/Sources/PulseActivity/PulseActivityState.swift \
  /tmp/pulse-golden/main.swift
/tmp/pulse-golden/golden \
  /tmp/pulse-golden/native-date-content-state.json \
  /tmp/pulse-golden/native-date-golden.json
cp /tmp/pulse-golden/native-date-*.json Services/PulsePushBridge/test/fixtures/
```

The generator scripts are transient (they live in `/tmp` at generation time);
both are reproduced in full in the appendix below so the proof is always
reproducible. `main.swift` decodes with default strategies into the real
`PulseActivityState`, asserts every instant round-trips, and `fatalError`s
otherwise, so the golden file exists only when the proof held. The
counterfactual was also verified natively: `{"date":1700000000}` decoded with
default strategies lands in **2054** (a 2026 instant would land in 2057),
while the corrected `{"date":721692800}` lands exactly on the intended 2023
instant.

## Appendix: the generator scripts

`emit-body.cjs` — emits the APNs body from the bridge's real code:

```js
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const BRIDGE = '<absolute path to Services/PulsePushBridge>';
const { buildApsDictionary, materializeState, validateState } = require(path.join(BRIDGE, 'src/payload'));
const { registrationBody } = require(path.join(BRIDGE, 'test/helpers'));
const { unixSecondsToAppleReference } = require(path.join(BRIDGE, 'src/util'));

const T0 = 1_700_000_000;
const body = registrationBody({
  quoteSourceTimeUnix: T0,
  plans: {
    priceConditionReachedCount: 1,
    manualReviewCount: 2,
    remainingPlanCount: 3,
    asOf: { encoding: 'appleReferenceSeconds', value: unixSecondsToAppleReference(T0 - 60) },
    syncState: 'pending',
  },
});
const validated = validateState(body.template, 'template');
if (!validated.ok) throw new Error(`validation failed: ${JSON.stringify(validated)}`);
const state = materializeState(validated.value, { quoteSourceTimeUnix: T0, staleDateUnix: T0 + 300 });
const aps = buildApsDictionary(state, {
  event: 'update', nowUnix: T0 + 10, staleDateUnix: T0 + 300, relevanceScore: 80,
});
fs.writeFileSync(process.argv[2], JSON.stringify(aps, null, 2) + '\n');
```

`main.swift` — compiled with the real `PulseActivityState.swift`; decodes the
bridge's body with default strategies, asserts the round-trip, records the
goldens:

```swift
import Foundation

func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError("golden proof failed: \(message)") }
}

let args = CommandLine.arguments
let bodyData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
let aps = body["aps"] as! [String: Any]
let contentState = aps["content-state"] as! [String: Any]
let contentStateData = try JSONSerialization.data(withJSONObject: contentState)

// The decode the system performs on a Live Activity push: default strategies,
// not configurable by the app.
let state = try JSONDecoder().decode(PulseActivityState.self, from: contentStateData)

require(abs(state.quoteSourceTime.timeIntervalSince1970 - 1_700_000_000) < 0.0005, "quoteSourceTime")
require(abs(state.primary.quoteSourceTime.timeIntervalSince1970 - 1_700_000_000) < 0.0005, "primary.quoteSourceTime")
require(abs(state.staleDate.timeIntervalSince1970 - 1_700_000_300) < 0.0005, "staleDate")
require(abs(state.plans.asOf!.timeIntervalSince1970 - 1_699_999_940) < 0.0005, "plans.asOf")
require(state.status == .live && state.plans.syncState == .pending, "enums")

// Re-encoding with the default encoder must reproduce the bridge's numbers.
let encoder = JSONEncoder()
let reencoded = try JSONSerialization.jsonObject(with: encoder.encode(state)) as! [String: Any]
require((reencoded["quoteSourceTime"] as! Double) == (contentState["quoteSourceTime"] as! Double), "re-encode")
// (staleDate, primary.quoteSourceTime and plans.asOf checked the same way;
//  the full program is the one that produced test/fixtures/native-date-golden.json)

// Golden instants, including the two epoch boundaries that pin the sign.
require(Date(timeIntervalSince1970: 978_307_200).timeIntervalSinceReferenceDate == 0, "reference epoch")
struct DateBox: Codable { var date: Date }
for (name, unix) in [("quote-source", 1_700_000_000.0), ("stale-date", 1_700_000_300.0),
                     ("plan-as-of", 1_699_999_940.0), ("reference-epoch", 978_307_200.0),
                     ("unix-epoch", 0.0)] {
    let date = Date(timeIntervalSince1970: unix)
    let encoded = String(data: try encoder.encode(DateBox(date: date)), encoding: .utf8)!
    print(name, unix, date.timeIntervalSinceReferenceDate, encoded)
}
```
