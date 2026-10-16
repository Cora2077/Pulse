# PulsePushBridge — integration guide

A dependency-free Node.js service that drives the Pulse **Live Activity** from a
personal machine: it stores device registrations, decides when a pre-authorized
market window may start/update/end an activity, and talks to APNs.

It is **dry-run by default**. With no credentials it listens, validates, stores,
and reports `unconfigured` — it never claims a delivery it did not observe.

```
node --test                      # 153 tests, no network, no credentials
node bin/pulse-push-bridge.js --check    # validate config, do not bind
node bin/pulse-push-bridge.js            # dry-run on 127.0.0.1:8787
```

---

## 1. What this service is, and is not

**Is:** durable registration storage, a UTC session-window scheduler with a
one-automatic-start-per-window budget, an APNs transport pinned to Apple's two
hosts, and an honest delivery-status API.

**Quote modes differ deliberately.** The default `client` mode re-pushes an uploaded redacted snapshot without advancing its source time. Select `public` explicitly for independent Naver Korean equities/KOSPI, THS `88xxxx.SH` boards, and supported Tencent A-share/HK/US equities. `none` has no independent refresh capability.

A public source is fetched inside the scheduler before freshness is evaluated, only in authorized windows while enabled/not paused. Invalid, old, future or unavailable source data never becomes a fresh price. A quote refresh cannot confirm plan data: the original plan clock/revision is retained and its digest is marked pending.

This is not a guaranteed real-time market feed or unlimited-background promise. Sources are unofficial, phone authorization windows expire, APNs is budgeted by the OS, and real device delivery remains unverified.

---

## 2. Configuration

Every setting is an environment variable. There is deliberately **no flag** for
any secret, so a credential cannot leak via shell history or `ps`.

| Variable | Default | Notes |
|---|---|---|
| `PULSE_PUSH_MODE` | `dry-run` | `live` is required to actually send. |
| `PULSE_PUSH_BEARER_TOKEN` | — | Required in live mode, **≥32 chars**. |
| `PULSE_PUSH_HOST` | `127.0.0.1` | Non-loopback requires the opt-in below. |
| `PULSE_PUSH_ALLOW_NON_LOOPBACK` | `0` | Must be `1` to bind a public address. |
| `PULSE_PUSH_PORT` | `8787` | `0` = ephemeral (tests). |
| `PULSE_PUSH_STATE_DIR` | `~/.local/state/pulse-push-bridge` | Must not be `/`. |
| `PULSE_PUSH_UPDATE_INTERVAL_SECONDS` | `60` | Update cadence; min 15. |
| `PULSE_PUSH_MAX_WINDOWS_PER_REGISTRATION` | `8` | Max authorized windows. |
| `PULSE_PUSH_QUOTE_SOURCE` | `client` | Registered sources: `client`, `none`, `public`; only `public` independently refreshes supported symbols. |
| `PULSE_PUSH_APNS_ENV` | `sandbox` | `sandbox` \| `production`. |
| `PULSE_PUSH_APNS_KEY_PATH` | — | Path to the `.p8`. Read on demand. |
| `PULSE_PUSH_APNS_KEY_ID` | — | Key ID. |
| `PULSE_PUSH_APNS_TEAM_ID` | — | Team ID. |
| `PULSE_PUSH_APNS_TOPIC` | — | Full Live Activity topic, e.g. `app.pulse.ios.dev.push-type.liveactivity` (not just the bundle id). |

`GET /v1/status` lists exactly which of these are missing as
`missingRequirements`, and `deliveryReady` is false until all are present. A missing
credential is a **runtime state**, not a crash: the service starts, serves, and
reports `unconfigured`.

### Deployment: TLS

The service speaks plain HTTP and is meant to sit behind an **operator-managed
reverse proxy** that terminates TLS. Do not bind `0.0.0.0` without both the
opt-in variable and a proxy in front. The bearer token is the only
authentication, so it must not cross a network in the clear.

---

## 3. HTTP API

Bearer auth is required on **every** route except `/v1/health`. The comparison
is constant-time; the token is never logged, echoed, or included in an error.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/v1/health` | Liveness only. No config detail. Unauthenticated. |
| `GET` | `/v1/status` | Mode, readiness, per-device delivery state. |
| `PUT` | `/v1/registrations/<deviceID>` | Create or replace a registration. |
| `GET` | `/v1/registrations/<deviceID>` | Read one registration (redacted). |
| `DELETE` | `/v1/registrations/<deviceID>` | Revoke: stop all pushes for this device. |
| `POST` | `/v1/registrations/<deviceID>/pause` | Pause until a UTC instant. |
| `POST` | `/v1/quotes/refresh` | Report freshness capability for a symbol key. |

There are **no wildcards, no proxy route, and no URL field anywhere in the
accepted schema**. `<deviceID>` is validated as an opaque 8–128 char
`[A-Za-z0-9_-]` token and is never used as a filesystem path.

`PUT` returns `planVersion`, which increments whenever the schedule or template
changes. A client that sees an unchanged `planVersion` after an edit knows the
edit did not land.

### Registration body

```jsonc
{
  "attributes": {                       // mirrors PulseActivityAttributes
    "symbolKey": "AAPL",
    "destination": { "instrumentDetail": { "symbolKey": "AAPL" } }
  },
  "template": { /* a complete PulseActivityState — see §4 */ },
  "pushToStartToken": { "base64": "…" },  // 32 or 44 bytes
  "updateToken":       { "base64": "…" }, // 32 bytes
  "activityID": "…",                      // optional
  "enabled": true,
  "pauseUntil": "2026-10-20T00:00:00Z",   // optional, ≤30 days ahead
  "windows": [
    { "id": "w1", "start": "2026-10-16T13:30:00Z",
      "end": "2026-10-16T20:00:00Z", "autoStart": true }
  ],
  "revision": 7                           // optional, echoed back
}
```

Windows are **UTC instants**, maximum **8 hours** each, and may not overlap
(overlaps are rejected rather than merged, because merging would silently change
how many automatic starts the user authorized).

### Refused fields

A recursive scan rejects any sensitive-looking key **at any depth**: account,
balance, position, holding, quantity/qty, cost basis, average cost, PnL,
fills/orders/executions, portfolio, broker, notes/memo/journal, and credentials.

The only token-shaped keys accepted are exactly `pushToStartToken` and
`updateToken`. Unknown keys are **rejected, not stripped** — a client that starts
sending a new field gets a `400` immediately instead of silently losing data:

```json
{"error":"invalid-registration","reason":"sensitive-field-rejected","detail":"$.accountBalance"}
```

### Backward-compatible fields

`plans.asOf` and `plans.syncState` are **tolerated** for clients that already
send them, validated when present, and carried through untouched:

- `plans.asOf` — a date. Plan-side clock only. **Not used for freshness.**
- `plans.syncState` — one of `local` | `synced` | `pending` | `unavailable`
  (`PulsePlanSyncState`). An unknown value is refused, not coerced.

These are accepted so a newer client keeps working against this service; they do
not make the service assert anything about plan sync it cannot verify.

---

## 4. Wire format and the date-unit trap

> **This is the single most important section for the client implementer.**

Two different clocks appear on this wire, and confusing them shifts every date
by **31 years**.

| Location | Unit |
|---|---|
| APNs `aps.timestamp`, `aps["stale-date"]` | **UNIX seconds** (since 1970) |
| Dates *inside* `content-state` that this service emits | **Apple reference seconds** (since 2001), matching default Swift Codable |
| Swift `JSONEncoder` default for `Date` | **Apple reference seconds** (since 2001) |

The offset is `978307200` seconds. APS envelope dates are UNIX; native Date fields inside `content-state` are **2001-reference seconds** under their real Swift property names. The system controls the ActivityKit decoder and uses its **default strategies**. An app cannot fix an incompatible push by configuring its own JSONDecoder.

Do not set a custom `.secondsSince1970` strategy for the system content-state contract. See [native Swift golden verification](docs/NATIVE_WIRE.md): the actual Node output decodes into the real PulseActivityState using bare JSONDecoder, and re-encodes to the same date values.

Input dates use explicit tags below; those tags are normalized internally, then converted to native reference seconds only when building the APNs body. Outer `aps.timestamp` and `aps.stale-date` remain UNIX seconds.

### Dates on input are tagged

Every date the client uploads must declare its encoding, because guessing is how
a quote ends up 31 years old:

```json
{ "encoding": "unixSeconds",           "value": 1700000000 }
{ "encoding": "appleReferenceSeconds", "value": 721700000 }
{ "encoding": "iso8601",               "value": "2026-10-16T13:30:00Z" }
```

An unknown `encoding` is a `400`. Windows and `pauseUntil` accept ISO-8601
strings, which is the recommended form for those fields.

### APNs body shape

```jsonc
{ "aps": {
    "timestamp": 1700000200,          // UNIX s — when this push was made
    "event": "update",                // start | update | end
    "content-state": { /* PulseActivityState, Date fields in native 2001-reference seconds */ },
    "stale-date": 1700000300,         // UNIX s — derived from SOURCE time
    "relevance-score": 50
} }
```

`timestamp` and `stale-date` are **different fields with different meanings**,
and the service keeps them different:

- `timestamp` = when this push was made. Moving it forward is truthful.
- `stale-date` = source time + the freshness window for the market phase.
  It is **derived from the source time**, never from "now".

**No code path replaces an unchanged quote's source time with the current
time.** If no new quote has arrived, `quoteSourceTimeUnix` in the pushed state is
byte-for-byte the value the client uploaded, and `stale-date` is unmoved. When
the source is older than its freshness window, the tick produces
`skipped-stale-source` and no push at all.

`event` is `start`, `update`, or `end`. Starts and ends use priority 10; updates
use 5 so APNs may coalesce them.

---

## 5. Freshness policy

Mirrors `PulseStalenessPolicy`
(`Packages/PulseActivity/Sources/PulseActivity/PulseActivityState.swift`) — the
service and the app must agree, or the lock screen says "live" while the app says
"stale". The Swift defaults are `openMarketWindow: 5 min`,
`extendedSessionWindow: 20 min`, `closedMarketWindow: 24 h`,
`unknownPhaseWindow: 15 min`, which is exactly the table below.

| Market phase | Window |
|---|---|
| `regular` | 5 min |
| `preMarket`, `postMarket`, `overnight`, `lunchBreak` | 20 min |
| `unknown` | 15 min |
| `closed` | 24 h |

Effective source time = `quoteSourceTime` + the client-declared `sourceDelay`, so
a feed that admits a 15-minute delay has already aged its own quote.

Only three statuses are pushable: `live`, `stale`, `marketClosed`. The service
refuses to push `disabled`, `pausedToday`, `permissionRequired`, `noCandidate` —
those are *local* decisions, and asserting one would claim knowledge it lacks.

---

## 6. Scheduling semantics

1. **Disabled or paused does nothing.** A hard gate, checked before windows.
   Pause is not "lower priority"; it is off.
2. **Expired windows are never back-filled.** A window whose end is past
   produces nothing. A three-day outage stays three missed sessions — catching
   up would fire a burst about markets that already closed.
3. **At most one automatic start attempt per window, reserved durably before sending.** `startsUsed`
   lives in the persisted registry, so **restarting the process is not a way to
   get another notification**.
4. **A dismissal is respected.** A spent start does not get a second one.
5. **An expired source never becomes a fresh quote** (§4).
6. **`410` on the push-to-start token stops starts** until a new token arrives.

`end` is delivered only on the activity update token, never on a push-to-start
token. If no update token exists, the local state still stops claiming the window is
active — the service reports `skipped`/`no-token` rather than pretending.

### Outcomes

`accepted`, `dry-run`, `unconfigured`, `rejected`, `retry`, `skipped`,
`deferred`, `idle`.

`accepted` is the **only** outcome that advances `lastAcceptedAtUnix`. A rejected
or retried push leaves it untouched and records the real reason, which
`GET /v1/registrations/<id>` returns. `idle` means nothing to do; `skipped` means
a policy refused something the user asked for. `dry-run` is never counted as a
delivery.

Retries use exponential backoff with deterministic per-device jitter (so a fleet
does not retry in lockstep), capped, and per-registration — a device being
rejected does not slow down a healthy one.

---

## 7. Security properties

All enforced in code and covered by tests:

- **Dry-run by default.** Live mode requires an explicit `PULSE_PUSH_MODE=live`
  **and** a ≥32-char bearer token **and** a readable `.p8`. Otherwise the
  transport is a `RecordingTransport` that opens no socket.
- **Bearer auth on every route but `/v1/health`**, compared in constant time.
- **Fixed APNs hosts only.** The host must be `api.sandbox.push.apple.com` or
  `api.push.apple.com`; anything else throws at construction. The request path is
  built from the **decoded token bytes**, hex-encoded — no caller-supplied string
  reaches the URL. **SSRF is impossible by construction, not by filtering.**
- **No proxy, no webhook, no outbound fetch route.**
- **Loopback by default.** A non-loopback bind additionally requires
  `PULSE_PUSH_ALLOW_NON_LOOPBACK=1`.
- **Strict directory ownership.** The state dir carries an `OWNER` marker;
  every read *and* write re-verifies it. A symlinked directory, a symlinked
  target, or a path resolving outside the root fails closed. Adoption is allowed
  only for an empty directory.
- **`0600` files in a `0700` directory**, written atomically via
  `open(mode) → write → fsync → rename`, then re-verified before the rename.
- **`ES256` JWT signed with `dsaEncoding: 'ieee-p1363'`** (raw `r||s`, 64 bytes).
  OpenSSL's default DER form is silently rejected by Apple; tests re-verify the
  signature to prove the encoding.
- **Provider tokens cached 50 min** — APNs rejects tokens older than an hour and
  treats frequent regeneration as abuse.
- **Secrets never logged.** Startup output redacts the token and lists only the
  key file's basename. Tokens, request bodies, and private keys never appear in
  logs.
- **Payload ≤ 4096 bytes**, checked on the serialized dictionary before sending.
- **Body cap 64 KB**, `application/json` only, duplicate JSON keys rejected (a
  classic allow-list bypass that `JSON.parse` would silently accept).

---

## 8. Actual independent-source coverage

| Mode / source | Supported keys | Boundary |
|---|---|---|
| `client` (default) | Uploaded snapshot only | No independent refresh; old source time preserved |
| `public` / Naver | Six-digit `.KS` / `.KQ`, `KOSPI.KS` | Requires actual source timestamp |
| `public` / THS | `88xxxx.SH`, including `881155.SH` | Index points, not a fabricated currency |
| `public` / Tencent | Supported A-share/HK/US equities | HK delay is explicit; unsupported indices/metals refused |
| `none` | None | No quote-refresh capability |

The global `REFRESHABLE_MARKETS` stays empty to avoid advertising public capability for a default client-only instance. Query the selected instance's `supportedMarkets()` / status API. Live smoke on 2026-10-16 returned actual Samsung, SK Hynix and THS bank prices with source ages 0/0/2 seconds; this is source connectivity evidence, not APNs delivery evidence.

Native start payloads now include `attributes-type`, Codable attributes, the required visible alert, and iOS18 `input-push-token: 1`. A known client-created activity with its own update token is adopted rather than started again. End events target only the activity UPDATE token, never a push-to-start token. Without it the API reports the missing-token limitation rather than pretending to end the device surface.

A start attempt is durably reserved BEFORE sending. A lost acknowledgement / ambiguous network or 5xx does not buy a second automatic start; explicit APNs 4xx rejection can refund the unused claim. Registration changes during source fetch or send prevent stale acknowledgements from restoring old state.

These requirements follow [Apple's ActivityKit push contract](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications). Native content-state dates use default Swift Codable reference seconds; outer APS timestamps remain UNIX seconds.

---

## 9. Client integration notes

1. **Keep native default Codable dates inside content-state** (§4); the system decoder cannot be configured by the app.
2. Send dates tagged with an explicit `encoding`.
3. Register with `PUT`; store the returned `planVersion`.
4. Authorize windows as UTC instants, ≤8 h each, non-overlapping.
5. On `enabled: false` or `pauseUntil`, the service ends a running activity and
   stops. Pause and disable are distinct states.
6. `DELETE` revokes. It ends a running activity and returns
   `activityEnded` / `endReason`.
7. Re-upload on a real quote refresh. **The service will not manufacture one.**

---

## 10. Testing

```
node --test
```

153 tests, no network and no credentials. Fake clock, fake APNs transport, fake
quote source. The suite covers: unconfigured-never-dials, auth and path
validation, pause vs disable, no duplicate start in one window, budget surviving
restart, stale source never presented as fresh, later-window recovery, revoke
stopping pushes, retry/backoff, the 4 KB cap, and token non-leakage.

---

## 11. Known gaps

- **Unofficial quote sources have no availability or latency SLA.** Unsupported symbols fail explicitly; see §8.
- **No in-process TLS.** Requires a reverse proxy.
- **No multi-user tenancy.** One bearer token; designed for personal use.
- **No APNs `liveactivity` end-to-end verification.** The transport is tested
  against a fake. A real device round-trip has not been performed from this
  environment, and must not be claimed until it has.
- **`.p8` handling is read-on-demand**, not memory-locked.
