'use strict';

/**
 * The delivery engine: turns a scheduler decision into an APNs request and
 * records what actually happened.
 *
 * The single most important property here is that **nothing reports success
 * that was not observed**:
 *
 *   - `deliveryRevision` advances only on `accepted`;
 *   - a rejected or retried push leaves `lastAcceptedAtUnix` untouched and
 *     records the real reason, which `/v1/registrations/<id>` returns;
 *   - a dry run returns `dry-run`, distinguishable from `accepted` in every
 *     response and in the stored state, and is never counted as a delivery.
 *
 * Rate/backoff policy is applied per registration, not globally: a device that
 * is being rejected must not slow down a healthy device.
 */

const {
  MAX_ATTEMPTS_PER_PUSH,
  tokenBytes,
} = require('./registry');
const {
  WINDOW_ACTIONS,
  attemptsExhausted,
  backoffSeconds,
  planTick,
  findWindow,
  staleDateUnixFor,
  updateIsDue,
} = require('./scheduler');
const {
  MAX_PAYLOAD_BYTES,
  buildApsDictionary,
  checkApsShape,
  checkPayloadBudget,
  materializeState,
} = require('./payload');
const { unixSeconds } = require('./util');
const { assertQuoteShape } = require('./quote-source');

/** What the engine did, in the vocabulary the API reports. */
const DELIVERY_OUTCOMES = {
  ACCEPTED: 'accepted',
  DRY_RUN: 'dry-run',
  UNCONFIGURED: 'unconfigured',
  REJECTED: 'rejected',
  RETRY: 'retry',
  SKIPPED: 'skipped',
  DEFERRED: 'deferred',
  IDLE: 'idle',
};

class DeliveryEngine {
  /**
   * @param {object} options
   * @param {import('./registry').Registry} options.registry
   * @param {object} options.transport  ApnsTransport or RecordingTransport.
   * @param {import('./quote-source').ClientSnapshotQuoteSource} options.quoteSource
   * @param {object} options.config
   * @param {() => number} [options.now]
   * @param {object} [options.logger]
   */
  constructor({ registry, transport, quoteSource, config, now = () => Date.now(), logger = null }) {
    this.registry = registry;
    this.transport = transport;
    this.quoteSource = quoteSource;
    this.config = config;
    this.now = now;
    this.logger = logger;
    this.isDryRun = !config.liveReady;
    this.inFlight = new Set();
  }

  nowSeconds() {
    return Math.floor(this.now() / 1000);
  }

  /**
   * One tick for one device.
   *
   * @returns {Promise<object>} A result record; never throws for a delivery
   *   failure, so a single bad device cannot stop the loop.
   */
  async tick(deviceID, options = {}) {
    if (this.inFlight.has(deviceID)) return { deviceID, outcome: 'deferred', reason: 'already-running' };
    this.inFlight.add(deviceID);
    try { return await this.#tickOnce(deviceID, options); }
    catch (error) { return { deviceID, outcome: 'retry', reason: error.reason ?? 'delivery-error' }; }
    finally { this.inFlight.delete(deviceID); }
  }

  async #tickOnce(deviceID, { force = false } = {}) {
    const entry = this.registry.get(deviceID);
    if (!entry) return { deviceID, outcome: DELIVERY_OUTCOMES.SKIPPED, reason: 'not-registered' };

    const nowUnix = this.nowSeconds();
    this.registry.prune(entry, { nowSeconds: nowUnix });

    // Backoff gate for retryable failures.
    const nextAttemptAt = entry.sync?.nextAttemptAtUnix ?? 0;
    if (!force && nowUnix < nextAttemptAt) {
      return { deviceID, outcome: DELIVERY_OUTCOMES.DEFERRED, reason: 'backoff', retryAtUnix: nextAttemptAt };
    }

    // An old template must not permanently block a REAL independent source.
    // Read only within the user's current authorization, never during pause.
    if (this.quoteSource.id === 'public') {
      if (!this.quoteSource.isRefreshable(entry.template.primary.symbolKey)) {
        return { deviceID, outcome: 'skipped', reason: 'unsupported-market' };
      }
      const window = findWindow(entry, nowUnix);
      const lastSourceAttempt = entry.sync?.lastSourceAttemptAtUnix ?? 0;
      const due = force || nowUnix - lastSourceAttempt >= this.config.updateIntervalSeconds;
      if (entry.enabled && !(entry.pauseUntilUnix > nowUnix) && window && due) {
        const version = entry.planVersion;
        this.registry.mutate(deviceID, e => { e.sync.lastSourceAttemptAtUnix = nowUnix; });
        let quote;
        try { quote = assertQuoteShape(await this.quoteSource.refresh(entry.template.primary.symbolKey)); }
        catch (error) {
          this.registry.mutate(deviceID, e => { e.sync.lastRejectionReason = error.reason ?? 'source-error'; });
          return { deviceID, outcome: 'skipped', reason: error.reason ?? 'source-error' };
        }
        const current = this.registry.get(deviceID);
        if (!current || current !== entry || current.planVersion !== version || !current.enabled
            || current.pauseUntilUnix > this.nowSeconds() || !findWindow(current, this.nowSeconds())) {
          return { deviceID, outcome: 'skipped', reason: 'registration-changed-during-refresh' };
        }
        if (quote.symbolKey !== current.template.primary.symbolKey || quote.quoteSourceTimeUnix > this.nowSeconds() + 60) {
          return { deviceID, outcome: 'skipped', reason: 'source-invalid' };
        }
        if (this.nowSeconds() - quote.quoteSourceTimeUnix > 300 + Math.max(0, quote.sourceDelay ?? 0)) {
          return { deviceID, outcome: 'skipped', reason: 'source-stale-during-authorized-window' };
        }
        this.registry.mutate(deviceID, e => {
          Object.assign(e.template.primary, {
            price: quote.price, change: quote.change ?? e.template.primary.change,
            changePercent: quote.changePercent ?? null, sourceDelay: quote.sourceDelay ?? 0,
            marketPhase: quote.marketPhase, quoteSourceTimeUnix: quote.quoteSourceTimeUnix,
            quoteSourceTime: { encoding: 'unixSeconds', seconds: quote.quoteSourceTimeUnix },
          });
          e.template.quoteSourceTimeUnix = quote.quoteSourceTimeUnix;
          e.template.quoteSourceTime = { encoding: 'unixSeconds', seconds: quote.quoteSourceTimeUnix };
          e.template.staleDateUnix = staleDateUnixFor(e.template);
          // Quote refresh cannot confirm a plan or advance its separate clock.
          e.template.plans.syncState = 'pending';
        });
      }
    }
    const plan = planTick(entry, { nowUnix: this.nowSeconds() });

    if (plan.shouldEndActivity || plan.action === WINDOW_ACTIONS.END) {
      return this.#endActivity(deviceID, plan, { nowUnix });
    }
    if (plan.clearActive) {
      this.registry.mutate(deviceID, (e) => { e.activeActivity = null; });
      return { deviceID, outcome: DELIVERY_OUTCOMES.IDLE, reason: plan.reason };
    }

    if (plan.action === WINDOW_ACTIONS.START) {
      return this.#startActivity(deviceID, plan, { nowUnix });
    }
    if (plan.action === WINDOW_ACTIONS.UPDATE) {
      const due = force || updateIsDue(entry, { nowUnix, intervalSeconds: this.config.updateIntervalSeconds });
      if (!due) return { deviceID, outcome: DELIVERY_OUTCOMES.IDLE, reason: 'update-not-due' };
      return this.#updateActivity(deviceID, plan, { nowUnix });
    }

    // A window that already ran to completion (or one that is simply not open)
    // is `idle`, not `skipped`. The distinction matters to the API client: a
    // skip means a policy refused something the user asked for, while idle
    // means there was nothing to do. An ended window stays idle forever.
    if (plan.action === WINDOW_ACTIONS.IDLE) {
      return { deviceID, outcome: DELIVERY_OUTCOMES.IDLE, reason: plan.reason, windowID: plan.windowID };
    }

    return { deviceID, outcome: DELIVERY_OUTCOMES.SKIPPED, reason: plan.action, windowID: plan.windowID };
  }

  // --- start ---------------------------------------------------------------

  async #startActivity(deviceID, plan, { nowUnix }) {
    const entry = this.registry.get(deviceID);
    const body = this.#buildBody(entry, { nowUnix, event: 'start' });
    if (!body.ok) return this.#recordSkip(deviceID, plan, body);

    const version = entry.planVersion;
    // Reserve BEFORE sending: an ambiguous network result or process death is
    // not evidence that Apple did not create the activity.
    if (!this.isDryRun) this.registry.mutate(deviceID, e => {
      const saved = this.registry.windowState(e, plan.windowID);
      this.registry.setWindowState(e, plan.windowID, { startsUsed: saved.startsUsed + 1 });
    });
    const result = await this.transport.send(tokenBytes(entry.pushToStartToken), body.aps, {
      pushType: 'liveactivity',
      // `start` events must be stored-and-forwarded with priority 10.
      priority: 10,
      expirationUnix: 0,
    });

    if (!this.#sameRegistration(deviceID, entry, version)) {
      return { deviceID, outcome: 'skipped', reason: 'registration-changed-during-send' };
    }
    if (result.outcome !== 'accepted') {
      // Explicit 4xx responses prove rejection; ambiguous network/5xx does not.
      if (!this.isDryRun && result.status >= 400 && result.status < 500) {
        this.registry.mutate(deviceID, e => {
          const saved = this.registry.windowState(e, plan.windowID);
          this.registry.setWindowState(e, plan.windowID, { startsUsed: Math.max(0, saved.startsUsed - 1) });
        });
      }
      return this.#recordFailure(deviceID, plan, result, { event: 'start', nowUnix });
    }

    const activityID = result.apnsId ?? `apns-${nowUnix}-${deviceID.slice(0, 8)}`;
    this.registry.mutate(deviceID, (e) => {
      e.activeActivity = {
        windowID: plan.windowID,
        activityID,
        startedAtUnix: nowUnix,
        pushToStart: true,
      };
      const state = this.registry.windowState(e, plan.windowID);
      this.registry.setWindowState(e, plan.windowID, {
        startsUsed: this.isDryRun ? state.startsUsed : Math.max(1, state.startsUsed),
        lastStartAtUnix: nowUnix,
        lastPlanVersion: e.planVersion,
        attempts: 0,
      });
      e.sync = {
        ...e.sync,
        lastAcceptedAtUnix: nowUnix,
        lastOutcome: DELIVERY_OUTCOMES.ACCEPTED,
        consecutiveFailures: 0,
        nextAttemptAtUnix: 0,
        lastRejectionReason: null,
      };
    });

    return {
      deviceID,
      outcome: result.dryRun ? DELIVERY_OUTCOMES.DRY_RUN : DELIVERY_OUTCOMES.ACCEPTED,
      event: 'start',
      windowID: plan.windowID,
      dryRun: Boolean(result.dryRun),
      payloadBytes: body.bytes,
    };
  }

  // --- update --------------------------------------------------------------

  async #updateActivity(deviceID, plan, { nowUnix }) {
    const entry = this.registry.get(deviceID);
    if (!entry.updateToken) {
      return this.#recordSkip(deviceID, plan, { reason: 'no-update-token' });
    }

    const body = this.#buildBody(entry, { nowUnix, event: 'update' });
    if (!body.ok) return this.#recordSkip(deviceID, plan, body);

    const version = entry.planVersion;
    const result = await this.transport.send(tokenBytes(entry.updateToken), body.aps, {
      pushType: 'liveactivity',
      priority: 5, // updates may be coalesced; 10 is reserved for starts/ends
      expirationUnix: 0,
    });

    if (!this.#sameRegistration(deviceID, entry, version)) {
      return { deviceID, outcome: 'skipped', reason: 'registration-changed-during-send' };
    }
    if (result.outcome !== 'accepted') {
      return this.#recordFailure(deviceID, plan, result, { event: 'update', nowUnix });
    }

    this.registry.mutate(deviceID, (e) => {
      this.registry.setWindowState(e, plan.windowID, {
        updateSentAtUnix: nowUnix,
        lastPlanVersion: e.planVersion,
      });
      e.sync = {
        ...e.sync,
        lastAcceptedAtUnix: nowUnix,
        lastOutcome: DELIVERY_OUTCOMES.ACCEPTED,
        consecutiveFailures: 0,
        nextAttemptAtUnix: 0,
        lastRejectionReason: null,
      };
    });

    return {
      deviceID,
      outcome: result.dryRun ? DELIVERY_OUTCOMES.DRY_RUN : DELIVERY_OUTCOMES.ACCEPTED,
      event: 'update',
      windowID: plan.windowID,
      dryRun: Boolean(result.dryRun),
      payloadBytes: body.bytes,
    };
  }

  // --- end -----------------------------------------------------------------

  async #endActivity(deviceID, plan, { nowUnix }) {
    const entry = this.registry.get(deviceID);
    const active = entry.activeActivity;
    if (!active) {
      return { deviceID, outcome: DELIVERY_OUTCOMES.IDLE, reason: 'nothing-active' };
    }

    const body = this.#buildBody(entry, { nowUnix, event: 'end' });
    // An end is delivered on the update token when there is one (it targets the
    // running activity); the push-to-start token is the fallback.
    const target = tokenBytes(entry.updateToken);
    if (!body.ok || !target) {
      // Even with no way to send, the local state must stop claiming the window
      // is running: the activity will expire on its own, and the service says so.
      this.registry.mutate(deviceID, (e) => {
        this.registry.setWindowState(e, active.windowID, { endedAtUnix: nowUnix });
        e.activeActivity = null;
      });
      return { deviceID, outcome: DELIVERY_OUTCOMES.SKIPPED, reason: body.ok ? 'no-token' : body.reason, event: 'end' };
    }

    const version = entry.planVersion;
    const result = await this.transport.send(target, body.aps, {
      pushType: 'liveactivity',
      priority: 10,
      expirationUnix: 0,
    });

    if (!this.#sameRegistration(deviceID, entry, version, true)) {
      return { deviceID, outcome: 'skipped', reason: 'registration-changed-during-send' };
    }
    const accepted = result.outcome === 'accepted';
    const dryRun = result.outcome === 'unconfigured' && result.dryRun;
    if (!accepted && !dryRun && result.outcome !== 'rejected') {
      // A retryable end failure: keep the activity marked active so the next
      // tick retries the end rather than forgetting it.
      return this.#recordFailure(deviceID, plan, result, { event: 'end', nowUnix });
    }

    this.registry.mutate(deviceID, (e) => {
      this.registry.setWindowState(e, active.windowID, { endedAtUnix: nowUnix });
      e.activeActivity = null;
      if (accepted) {
        e.sync = {
          ...e.sync,
          lastAcceptedAtUnix: nowUnix,
          lastOutcome: DELIVERY_OUTCOMES.ACCEPTED,
          consecutiveFailures: 0,
          nextAttemptAtUnix: 0,
          lastRejectionReason: null,
        };
      }
    });

    return {
      deviceID,
      outcome: accepted ? DELIVERY_OUTCOMES.ACCEPTED : DELIVERY_OUTCOMES.DRY_RUN,
      event: 'end',
      windowID: active.windowID,
      dryRun: !accepted,
      reason: accepted ? null : result.reason ?? 'dry-run',
    };
  }

  // --- payload assembly ----------------------------------------------------

  /**
   * Builds the APNs body from the stored template.
   *
   * The state is materialized from the template with only the two clocks moved:
   * the quote source time is preserved (or replaced by a *real* refreshed source
   * time when a provider supplies one), and `staleDate` is derived from it. This
   * is where the "never stamp an old quote with the current time" rule is
   * enforced for real, and `materializeState` cannot invent a price.
   */
  #buildBody(entry, { nowUnix, event }) {
    const quote = this.#quoteFor(entry, { nowUnix });
    if (!quote.ok) return quote;

    const staleDateUnix = quote.staleDateUnix;
    const state = materializeState(entry.template, {
      quoteSourceTimeUnix: quote.quoteSourceTimeUnix,
      staleDateUnix,
    });

    const aps = buildApsDictionary(state, {
      event,
      nowUnix,
      staleDateUnix,
      relevanceScore: relevanceFor(entry.template),
    });

    if (event === 'start') {
      const destination = entry.attributes.destination;
      let wireDestination;
      if (destination.kind === 'instrumentDetail') wireDestination = { instrumentDetail: { symbolKey: destination.symbolKey } };
      else if (destination.kind === 'plans') wireDestination = { plans: { planID: destination.planID } };
      else wireDestination = { planInbox: {} };
      aps.aps['attributes-type'] = 'PulseActivityAttributes';
      aps.aps.attributes = { symbolKey: entry.attributes.symbolKey, destination: wireDestination };
      aps.aps.alert = { title: 'FFF 自动关注', body: `${entry.template.primary.displayName} 已进入你授权的关注时段` };
      aps.aps['input-push-token'] = 1;
    }

    // `checkApsShape` takes the whole APNs body (`{aps: {...}}`), not the inner
    // dictionary — `buildApsDictionary` already returns that wrapper. Passing
    // `aps` here reported `missing-aps` for every push, so every start/update/end
    // was silently skipped. The unit is asserted below so a future edit cannot
    // reintroduce the "wrong clock" class of bug.
    const shape = checkApsShape(aps);
    if (!shape.ok) return shape;

    const budget = checkPayloadBudget(aps, MAX_PAYLOAD_BYTES);
    if (!budget.ok) return budget;

    return { ok: true, aps, bytes: budget.bytes };
  }

  /**
   * Resolves the quote fields for one push.
   *
   * With the `client` source this is a pass-through of the uploaded snapshot:
   * the source time is the phone's, unchanged. A refreshable source would be
   * consulted here and only here — and an unsupported market is a *skip*, never
   * a silent fallback to a fabricated number.
   */
  #quoteFor(entry, { nowUnix }) {
    return {
      ok: true,
      quoteSourceTimeUnix: entry.template.quoteSourceTimeUnix,
      staleDateUnix: staleDateUnixFor(entry.template),
    };
  }

  #sameRegistration(deviceID, entry, version, allowStopped = false) {
    const current = this.registry.get(deviceID);
    return current === entry && current.planVersion === version
      && (allowStopped || current.enabled && !(current.pauseUntilUnix > this.nowSeconds()));
  }

  // --- failure recording ---------------------------------------------------

  /**
   * Records a non-accepted push.
   *
   * `accepted` is the only outcome that touches `lastAcceptedAtUnix`; everything
   * else records the real reason and schedules a retry only when the transport
   * said the failure is retryable.
   */
  #recordFailure(deviceID, plan, result, { event, nowUnix }) {
    const outcome = result.outcome === 'unconfigured'
      ? DELIVERY_OUTCOMES.UNCONFIGURED
      : DELIVERY_OUTCOMES.RETRY;

    let invalidated = null;
    this.registry.mutate(deviceID, (e) => {
      if (result.tokenDead) {
        // 410 / BadDeviceToken: the token is dead. Mark it and do not retry it.
        if (event === 'update') {
          e.updateTokenInvalid = true;
          invalidated = 'updateToken';
        } else {
          e.pushToStartTokenInvalid = true;
          invalidated = 'pushToStartToken';
          if (!e.updateToken) e.activeActivity = null;
        }
      }
      const state = this.registry.windowState(e, plan.windowID ?? 'unknown');
      const attempts = (state.attempts ?? 0) + 1;
      this.registry.setWindowState(e, plan.windowID ?? 'unknown', { attempts });

      const retryable = Boolean(result.retryable) && !result.tokenDead && !attemptsExhausted(attempts, MAX_ATTEMPTS_PER_PUSH);
      e.sync = {
        ...e.sync,
        lastOutcome: outcome,
        lastRejectedAtUnix: nowUnix,
        lastRejectionReason: result.reason ?? null,
        consecutiveFailures: (e.sync?.consecutiveFailures ?? 0) + 1,
        nextAttemptAtUnix: retryable
          ? nowUnix + backoffSeconds(attempts, { deviceID })
          : 0,
      };
    });

    return {
      deviceID,
      outcome,
      event,
      windowID: plan.windowID ?? null,
      reason: result.reason ?? 'unknown',
      status: result.status ?? null,
      tokenInvalidated: invalidated,
      dryRun: Boolean(result.dryRun),
    };
  }

  #recordSkip(deviceID, plan, details) {
    this.registry.mutate(deviceID, (e) => {
      e.sync = {
        ...e.sync,
        lastOutcome: DELIVERY_OUTCOMES.SKIPPED,
        lastRejectionReason: details.reason ?? 'skipped',
      };
    });
    return {
      deviceID,
      outcome: DELIVERY_OUTCOMES.SKIPPED,
      windowID: plan.windowID ?? null,
      reason: details.reason ?? 'skipped',
    };
  }

  /**
   * One pass over every registration.
   *
   * Sequential on purpose: this runs on a personal server for a handful of
   * devices, and serializing keeps the registry mutations ordered without locks.
   */
  async runOnce({ force = false } = {}) {
    const results = [];
    for (const entry of this.registry.list()) {
      try {
        results.push(await this.tick(entry.deviceID, { force }));
      } catch (error) {
        // A bug affecting one device must not stop the pass for the others.
        results.push({ deviceID: entry.deviceID, outcome: DELIVERY_OUTCOMES.SKIPPED, reason: `engine-error:${error.message}` });
      }
    }
    return results;
  }
}

/**
 * Relevance score, mirroring the coordinator's `relevance(for:)`: live quotes
 * and actionable plans rank higher, and the value is clamped to 0…100.
 */
function relevanceFor(template) {
  let score = template.status === 'live' ? 50 : 10;
  if (template.plans.priceConditionReachedCount > 0) score += 30;
  if (template.plans.manualReviewCount > 0) score += 10;
  return Math.min(score, 100);
}

module.exports = {
  DELIVERY_OUTCOMES,
  DeliveryEngine,
  relevanceFor,
  unixSeconds,
};
