'use strict';

/**
 * The registry: every registration plus its durable push bookkeeping.
 *
 * The bookkeeping is the part that must survive a restart, because it is what
 * stops the service from becoming a notification spammer:
 *
 *   - `startsUsed`: how many automatic starts this *window* has already spent.
 *     Persisted, so restarting the process mid-window does not reset the budget
 *     and re-start an activity the user already dismissed.
 *   - `lastStartedWindowID` / `lastEndedWindowID`: so a window that has already
 *     been started or ended is not reopened by a later tick.
 *   - `deliveryRevision`: bumped only on a confirmed `accepted`. A failed push
 *     must not advance the revision, or the client would believe the screen is
 *     current when nothing arrived.
 *   - `tokenInvalid`: set when APNs says 410/BadDeviceToken. The token is kept
 *     but marked dead so it is visibly dead rather than silently retried.
 *
 * Everything here is plain functions over a frozen-by-convention object, which
 * keeps it trivially testable with an in-memory store and no clock of its own.
 */

const REGISTRY_VERSION = 1;
const MAX_ATTEMPTS_PER_PUSH = 4;

/** Fresh registry value. */
function emptyRegistry() {
  return { version: REGISTRY_VERSION, registrations: {} };
}

function emptyDeviceEntry(deviceID) {
  return {
    deviceID,
    createdAtUnix: null,
    updatedAtUnix: null,
    attributes: null,
    template: null,
    pushToStartToken: null,
    updateToken: null,
    activityID: null,
    enabled: true,
    pauseUntilUnix: null,
    windows: [],
    revision: null,
    planVersion: 0,
    activeActivity: null, // { windowID, activityID, startedAtUnix, pushToStart: bool }
    bookkeeping: {},
    sync: {
      lastAcceptedAtUnix: null,
      lastRejectedAtUnix: null,
      lastRejectionReason: null,
      lastOutcome: null,
      consecutiveFailures: 0,
      nextAttemptAtUnix: 0,
    },
  };
}

/**
 * Structural validation used when loading from disk.
 *
 * A file that fails this is treated as empty (the store already does that): the
 * alternative — trusting a partially corrupt schedule — could fire pushes for
 * windows nobody authorized.
 */
function validateRegistry(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('registry is not an object');
  if (raw.version !== REGISTRY_VERSION) throw new Error('registry version mismatch');
  if (!raw.registrations || typeof raw.registrations !== 'object' || Array.isArray(raw.registrations)) {
    throw new Error('registrations missing');
  }
  for (const [deviceID, entry] of Object.entries(raw.registrations)) {
    if (!entry || typeof entry !== 'object') throw new Error(`entry ${deviceID} is not an object`);
    if (entry.deviceID !== deviceID) throw new Error(`entry ${deviceID} is mislabelled`);
    if (typeof entry.enabled !== 'boolean') throw new Error(`entry ${deviceID} enabled is not boolean`);
    if (!Array.isArray(entry.windows)) throw new Error(`entry ${deviceID} windows is not an array`);
    if (!entry.bookkeeping || typeof entry.bookkeeping !== 'object') {
      throw new Error(`entry ${deviceID} bookkeeping missing`);
    }
  }
  return raw;
}

/** In-memory registry with the same surface as the durable one. */
class Registry {
  constructor({ store = null, now = () => Date.now(), logger = null } = {}) {
    this.now = now;
    this.logger = logger;
    this.store = store;
    this.data = store ? store.read() : emptyRegistry();
    if (!this.data.registrations) this.data = emptyRegistry();
  }

  #persist() {
    if (this.store) this.store.write(this.data);
  }

  nowSeconds() {
    return Math.floor(this.now() / 1000);
  }

  get size() {
    return Object.keys(this.data.registrations).length;
  }

  has(deviceID) {
    return Object.prototype.hasOwnProperty.call(this.data.registrations, deviceID);
  }

  get(deviceID) {
    return this.data.registrations[deviceID] ?? null;
  }

  list() {
    return Object.values(this.data.registrations);
  }

  /**
   * Creates or replaces a registration.
   *
   * `startsUsed` is *not* reset when the window list changes: editing windows is
   * not a way to buy more automatic starts in the window that is running now.
   * The budget is keyed by window ID, so a renamed window is a new window only
   * if it is genuinely a different one.
   */
  put(deviceID, incoming) {
    const nowSeconds = this.nowSeconds();
    const existing = this.data.registrations[deviceID];
    const entry = existing ? { ...existing } : emptyDeviceEntry(deviceID);

    entry.deviceID = deviceID;
    entry.createdAtUnix = existing?.createdAtUnix ?? nowSeconds;
    entry.updatedAtUnix = nowSeconds;
    entry.attributes = incoming.attributes;
    entry.template = incoming.template;
    entry.pushToStartToken = incoming.pushToStartToken;
    entry.updateToken = incoming.updateToken;
    entry.enabled = incoming.enabled;
    entry.pauseUntilUnix = incoming.pauseUntilUnix;
    entry.windows = incoming.windows;
    entry.revision = incoming.revision;
    entry.planVersion = (existing?.planVersion ?? 0) + 1;
    entry.bookkeeping = entry.bookkeeping ?? {};
    if (incoming.activityID) {
      entry.activityID = incoming.activityID;
      const window = entry.windows.find(w => w.startSeconds <= nowSeconds && nowSeconds < w.endSeconds);
      if (entry.updateToken && window && !entry.activeActivity && incoming.enabled) {
        entry.activeActivity = { windowID: window.id, activityID: incoming.activityID,
          startedAtUnix: nowSeconds, pushToStart: false };
        const saved = this.windowState(entry, window.id);
        this.setWindowState(entry, window.id, { startsUsed: Math.max(1, saved.startsUsed) });
      } else if (entry.activeActivity && entry.updateToken) {
        entry.activeActivity = { ...entry.activeActivity, activityID: incoming.activityID };
      }
    }

    // A new/refreshed push-to-start token clears any previous invalidation.
    if (incoming.pushToStartToken) entry.pushToStartTokenInvalid = false;
    if (incoming.updateToken) entry.updateTokenInvalid = false;

    // Keep the known activity until the delivery engine has attempted a real
    // end on its UPDATE token. Disabling must not erase the only addressable
    // activity state before the scheduler can clean it up.

    this.data.registrations[deviceID] = entry;
    this.#persist();
    return entry;
  }

  /** Removes a registration. Returns the removed entry, or null. */
  remove(deviceID) {
    if (!this.has(deviceID)) return null;
    const entry = this.data.registrations[deviceID];
    delete this.data.registrations[deviceID];
    this.#persist();
    return entry;
  }

  /** Applies a mutator to one entry and persists. Returns the entry. */
  mutate(deviceID, mutator) {
    const entry = this.data.registrations[deviceID];
    if (!entry) return null;
    mutator(entry);
    this.#persist();
    return entry;
  }

  // --- bookkeeping ---------------------------------------------------------

  /** Per-window counters for one device. */
  windowState(entry, windowID) {
    return entry.bookkeeping[windowID] ?? {
      startsUsed: 0,
      lastStartAtUnix: null,
      updateSentAtUnix: null,
      endedAtUnix: null,
      lastPlanVersion: null,
      attempts: 0,
    };
  }

  setWindowState(entry, windowID, patch) {
    const current = this.windowState(entry, windowID);
    entry.bookkeeping[windowID] = { ...current, ...patch };
  }

  /**
   * Drops bookkeeping for windows that are long past.
   *
   * Kept for a day past the window end so a late `end` push or an operator
   * inspecting the file can still see what happened, then removed. Without this
   * the file grows forever on a device that registers many windows.
   */
  prune(entry, { nowSeconds, retainSeconds = 24 * 3600 } = {}) {
    const byID = new Map(entry.windows.map((w) => [w.id, w]));
    for (const windowID of Object.keys(entry.bookkeeping)) {
      const window = byID.get(windowID);
      const state = entry.bookkeeping[windowID];
      const lastActivity = Math.max(
        state.lastStartAtUnix ?? 0,
        state.updateSentAtUnix ?? 0,
        state.endedAtUnix ?? 0,
      );
      const windowEnd = window ? window.endSeconds : 0;
      const expires = Math.max(lastActivity, windowEnd) + retainSeconds;
      if (nowSeconds > expires) delete entry.bookkeeping[windowID];
    }
  }
}

/**
 * The raw token bytes for a stored token.
 *
 * Stored tokens are `{ kind, bytes }` because the kind is what makes the byte
 * length check meaningful. The transport only ever wants the bytes, so this is
 * the one place that unwraps them — a single function to review rather than a
 * `.bytes` sprinkled at every call site (where a missing unwrap would send
 * `[object Object]` to Apple).
 */
function tokenBytes(token) {
  if (!token) return null;
  if (Buffer.isBuffer(token)) return token;
  return Buffer.isBuffer(token.bytes) ? token.bytes : null;
}

module.exports = {
  MAX_ATTEMPTS_PER_PUSH,
  REGISTRY_VERSION,
  Registry,
  emptyDeviceEntry,
  emptyRegistry,
  tokenBytes,
  validateRegistry,
};
