'use strict';

/**
 * The scheduler: decides, for one registration at one instant, what should
 * happen. Pure — it reads no clock and performs no I/O, so every rule below is
 * testable with a fake clock.
 *
 * The rules, and the failure each one prevents:
 *
 *   1. **Disabled or paused means nothing happens.** Hard gate, checked before
 *      windows. The user's pause is not "lower priority"; it is off.
 *   2. **Expired windows are never back-filled.** A window whose end is in the
 *      past produces nothing — not a start, not an end. If the process was down
 *      for three days, the three missed sessions must stay missed; catching up
 *      would fire a burst of notifications about markets that already closed.
 *   3. **At most one automatic start per window, counted durably.** Before
 *      starting, `startsUsed` for that window must be 0. `startsUsed` lives in
 *      the registry, so a process restart inside the same window does not
 *      re-arm it. This is the "restart bombardment" rule: restarting the
 *      service is not a way to get another notification.
 *   4. **A dismissal is respected.** If a start was already spent and the
 *      activity is gone, the window does not get a second one.
 *   5. **An expired *source* never becomes a fresh quote.** If the template's
 *      quote source time is older than the freshness window for its phase, the
 *      window produces `source-stale` and no push. Sending it with a
 *      current `timestamp` would be presenting an old number as a live one.
 *   6. **A permanent rejection stops the window.** APNs `410` on the
 *      push-to-start token means no more starts for that registration until a
 *      new token arrives.
 */

const { appleReferenceSecondsToUnix, unixSeconds } = require('./util');
const { MARKET_PHASES } = require('./payload');

/**
 * Freshness windows, mirroring `PulseStalenessPolicy` in Swift.
 *
 * Kept in step deliberately: the service and the app must agree on when a quote
 * stops being presentable, or the lock screen says "live" while the app says
 * "stale".
 */
const FRESHNESS_WINDOWS_SECONDS = {
  regular: 5 * 60,
  preMarket: 20 * 60,
  postMarket: 20 * 60,
  overnight: 20 * 60,
  lunchBreak: 20 * 60,
  closed: 24 * 60 * 60,
  unknown: 15 * 60,
};

/** Outcomes a window can produce in one tick. */
const WINDOW_ACTIONS = {
  IDLE: 'idle',
  NOT_YET: 'not-yet-open',
  START: 'start',
  UPDATE: 'update',
  END: 'end',
  SKIPPED_NO_START: 'skipped-no-token',
  SKIPPED_BUDGET: 'skipped-budget-spent',
  SKIPPED_STALE_SOURCE: 'skipped-stale-source',
  SKIPPED_TOKEN_DEAD: 'skipped-token-dead',
  SKIPPED_DISABLED: 'skipped-disabled',
  SKIPPED_PAUSED: 'skipped-paused',
};

/**
 * Effective source time, mirroring `PulseStalenessPolicy.effectiveSourceTime`:
 * a source that declares a delay has already aged its own quote.
 */
/**
 * Effective source time in UNIX seconds, mirroring
 * `PulseStalenessPolicy.effectiveSourceTime`: a source that declares a delay
 * has already aged its own quote.
 *
 * Reads `quoteSourceTimeUnix`, which `payload.normalizeStateDates` guarantees on
 * every validated template. A template without it is a programming error, not a
 * runtime condition, so it throws rather than returning a number that would
 * quietly disable the freshness gate.
 */
function effectiveSourceTimeUnix(template) {
  const base = template.quoteSourceTimeUnix;
  if (!Number.isInteger(base)) {
    throw new TypeError('template.quoteSourceTimeUnix is missing; normalize the state before scheduling');
  }
  const delay = template.primary.sourceDelay ?? 0;
  if (typeof delay !== 'number' || !Number.isFinite(delay) || delay < 0) {
    throw new TypeError('template.primary.sourceDelay must be a finite non-negative number');
  }
  return base + Math.floor(delay);
}

/** The deadline the device should show, derived from source time only. */
function staleDateUnixFor(template, { nowUnix = null } = {}) {
  const phase = MARKET_PHASES.has(template.primary.marketPhase) ? template.primary.marketPhase : 'unknown';
  const window = FRESHNESS_WINDOWS_SECONDS[phase] ?? FRESHNESS_WINDOWS_SECONDS.unknown;
  return effectiveSourceTimeUnix(template) + window;
}

function isSourceFresh(template, nowUnix) {
  return nowUnix < staleDateUnixFor(template);
}

function findWindow(entry, nowUnix) {
  return entry.windows.find((w) => nowUnix >= w.startSeconds && nowUnix < w.endSeconds) ?? null;
}

/**
 * Decides what one registration should do now.
 *
 * @returns {{
 *   action: string,
 *   windowID: string|null,
 *   reason: string|null,
 *   shouldEndActivity: boolean,
 * }}
 */
function planTick(entry, { nowUnix }) {
  const idle = { action: WINDOW_ACTIONS.IDLE, windowID: null, reason: null, shouldEndActivity: false };

  // Gate 1: the user turned automatic tracking off.
  if (!entry.enabled) {
    return {
      action: WINDOW_ACTIONS.SKIPPED_DISABLED,
      windowID: null,
      reason: 'disabled',
      shouldEndActivity: Boolean(entry.activeActivity),
    };
  }

  // Gate 2: paused. `pauseUntil` may be in the past, in which case it simply
  // stops applying — it never re-arms anything by itself.
  if (entry.pauseUntilUnix !== null && entry.pauseUntilUnix !== undefined && nowUnix < entry.pauseUntilUnix) {
    return {
      action: WINDOW_ACTIONS.SKIPPED_PAUSED,
      windowID: null,
      reason: 'paused',
      shouldEndActivity: Boolean(entry.activeActivity),
    };
  }

  const active = entry.activeActivity;
  const currentWindow = findWindow(entry, nowUnix);

  // An activity started in a window that has since closed must be ended, even
  // if no *new* window is open: the surface should stop showing a session that
  // is over.
  if (active) {
    const activeWindow = entry.windows.find((w) => w.id === active.windowID) ?? null;
    if (activeWindow && nowUnix >= activeWindow.endSeconds) {
      const state = entry.bookkeeping[active.windowID] ?? {};
      if (state.endedAtUnix) {
        // Already ended; clear the local marker so it is not re-sent.
        return { action: WINDOW_ACTIONS.IDLE, windowID: active.windowID, reason: 'already-ended', shouldEndActivity: false, clearActive: true };
      }
      return { action: WINDOW_ACTIONS.END, windowID: active.windowID, reason: 'window-closed', shouldEndActivity: false };
    }
    if (!activeWindow && active.windowID !== (currentWindow?.id ?? null)) {
      // The window definition disappeared (client edited the schedule). Treat it
      // as closed rather than letting the activity outlive its authorization.
      return { action: WINDOW_ACTIONS.END, windowID: active.windowID, reason: 'window-removed', shouldEndActivity: false };
    }
  }

  if (!currentWindow) return idle;

  const windowState = entry.bookkeeping[currentWindow.id] ?? {
    startsUsed: 0, lastStartAtUnix: null, updateSentAtUnix: null, endedAtUnix: null, lastPlanVersion: null, attempts: 0,
  };

  // A window that already ran to completion produces nothing, forever.
  if (windowState.endedAtUnix) {
    return { action: WINDOW_ACTIONS.IDLE, windowID: currentWindow.id, reason: 'window-ended', shouldEndActivity: false };
  }

  // The token that would perform the start is dead.
  if (entry.pushToStartTokenInvalid && !active) {
    return { action: WINDOW_ACTIONS.SKIPPED_TOKEN_DEAD, windowID: currentWindow.id, reason: 'push-to-start-token-invalid', shouldEndActivity: false };
  }

  if (!active) {
    // Rule 3: one automatic start per window, checked against durable state.
    if (windowState.startsUsed >= 1) {
      return {
        action: WINDOW_ACTIONS.SKIPPED_BUDGET,
        windowID: currentWindow.id,
        reason: 'automatic-start-already-used',
        shouldEndActivity: false,
      };
    }
    if (!currentWindow.autoStart) {
      return { action: WINDOW_ACTIONS.SKIPPED_BUDGET, windowID: currentWindow.id, reason: 'auto-start-not-authorized', shouldEndActivity: false };
    }
    if (!entry.pushToStartToken) {
      // Only an *update* token exists. There is no way to start from it, so the
      // honest answer is "skipped", not "started".
      return { action: WINDOW_ACTIONS.SKIPPED_NO_START, windowID: currentWindow.id, reason: 'no-push-to-start-token', shouldEndActivity: false };
    }
    // Rule 5: never present an old source as current.
    if (!isSourceFresh(entry.template, nowUnix)) {
      return {
        action: WINDOW_ACTIONS.SKIPPED_STALE_SOURCE,
        windowID: currentWindow.id,
        reason: 'quote-source-stale',
        shouldEndActivity: false,
      };
    }
    return { action: WINDOW_ACTIONS.START, windowID: currentWindow.id, reason: null, shouldEndActivity: false };
  }

  // An activity is running: refresh it, subject to the cadence.
  if (active.updateTokenInvalid) {
    return { action: WINDOW_ACTIONS.SKIPPED_TOKEN_DEAD, windowID: currentWindow.id, reason: 'update-token-invalid', shouldEndActivity: false };
  }
  if (!isSourceFresh(entry.template, nowUnix)) {
    return { action: WINDOW_ACTIONS.SKIPPED_STALE_SOURCE, windowID: currentWindow.id, reason: 'quote-source-stale', shouldEndActivity: false };
  }
  return { action: WINDOW_ACTIONS.UPDATE, windowID: currentWindow.id, reason: null, shouldEndActivity: false };
}

/**
 * Whether the periodic update cadence allows another update now.
 *
 * Separate from `planTick` because it is a *rate* decision about an action that
 * is otherwise allowed, and because the tests for it want to vary only the
 * interval.
 */
function updateIsDue(entry, { nowUnix, intervalSeconds }) {
  const active = entry.activeActivity;
  if (!active) return false;
  const state = entry.bookkeeping[active.windowID] ?? {};
  const last = state.updateSentAtUnix ?? active.startedAtUnix ?? 0;
  if (nowUnix - last < intervalSeconds) return false;
  // A plan/template edit is an explicit user action and is not rate-limited: the
  // user just changed something and is looking at the screen.
  const planChanged = state.lastPlanVersion !== null && state.lastPlanVersion !== entry.planVersion;
  if (planChanged) return true;
  return true;
}

/**
 * Backoff for a retryable failure.
 *
 * Exponential from `baseSeconds`, capped, with deterministic jitter derived from
 * the device id so a fleet of devices does not retry in lockstep. Deterministic
 * rather than random so tests can assert it.
 */
function backoffSeconds(attempt, { baseSeconds = 5, maxSeconds = 300, deviceID = '' } = {}) {
  const exponent = Math.max(0, Math.min(attempt, 10));
  const raw = Math.min(baseSeconds * 2 ** exponent, maxSeconds);
  let hash = 0;
  for (let i = 0; i < deviceID.length; i += 1) hash = (hash * 31 + deviceID.charCodeAt(i)) % 997;
  const jitter = Math.floor(raw * 0.2 * (hash / 997));
  return raw + jitter;
}

/** True when a retryable failure has been retried too many times. */
function attemptsExhausted(attempts, maxAttempts) {
  return attempts >= maxAttempts;
}

module.exports = {
  FRESHNESS_WINDOWS_SECONDS,
  WINDOW_ACTIONS,
  attemptsExhausted,
  backoffSeconds,
  effectiveSourceTimeUnix,
  findWindow,
  isSourceFresh,
  planTick,
  staleDateUnixFor,
  unixSeconds,
  updateIsDue,
};
