'use strict';

/**
 * Composition root: wires config, store, registry, transport, engine and server.
 *
 * Keeping the wiring in one file is what makes the security posture auditable at
 * a glance — in particular that the transport is chosen by *mode*, and that
 * dry-run can never reach the network:
 *
 *   - `liveReady` (mode=live AND every credential present) -> real `ApnsTransport`
 *     to a fixed Apple host;
 *   - anything else -> `RecordingTransport`, which opens no socket at all. It
 *     reports `unconfigured`, never `accepted`, so a misconfigured service
 *     cannot look like a working one.
 */

const path = require('node:path');

const { describeConfig, loadConfig } = require('./config');
const { AtomicJsonStore } = require('./store');
const { Registry, validateRegistry, emptyRegistry } = require('./registry');
const { ApnsTokenProvider } = require('./apns-auth');
const { ApnsTransport, RecordingTransport } = require('./apns-client');
const { createQuoteSource } = require('./quote-source');
const { DeliveryEngine } = require('./delivery');
const { PushBridgeServer } = require('./server');
const { logLine } = require('./util');

/** A logger that writes single-line redacted JSON and never throws. */
function createLogger({ stream = process.stdout, level = 'info' } = {}) {
  const levels = ['debug', 'info', 'warn', 'error'];
  const threshold = levels.indexOf(level);
  const emit = (lvl, event, details = {}) => {
    if (levels.indexOf(lvl) < threshold) return;
    try {
      stream.write(logLine({ level: lvl, event, ...details }) + '\n');
    } catch {
      // A broken stdout must not take the service down.
    }
  };
  return {
    debug: (event, details) => emit('debug', event, details),
    info: (event, details) => emit('info', event, details),
    warn: (event, details) => emit('warn', event, details),
    error: (event, details) => emit('error', event, details),
  };
}

/**
 * Builds a fully wired bridge.
 *
 * @param {object} [options]
 * @param {object} [options.env] Override for tests.
 * @param {() => number} [options.now]
 * @param {boolean} [options.inMemory] Skip the durable store entirely.
 * @param {object} [options.transport] Force a transport (tests).
 * @param {object} [options.logger]
 */
function createBridge(options = {}) {
  const {
    env = process.env,
    now = () => Date.now(),
    inMemory = false,
    transport: forcedTransport = null,
    logger = createLogger({ level: env.PULSE_PUSH_LOG_LEVEL ?? 'info' }),
  } = options;

  const config = loadConfig(env);

  const store = inMemory
    ? null
    : new AtomicJsonStore({
      directory: config.stateDir,
      filename: 'registry.json',
      emptyValue: emptyRegistry,
      validate: validateRegistry,
      logger,
    });

  const registry = new Registry({ store, now, logger });

  const quoteSource = createQuoteSource(config.quoteSource, { logger });

  let transport = forcedTransport;
  if (!transport) {
    if (config.liveReady) {
      const tokenProvider = new ApnsTokenProvider({
        keyPath: config.apnsKeyPath,
        keyId: config.apnsKeyId,
        teamId: config.apnsTeamId,
        now,
        logger,
      });
      transport = new ApnsTransport({
        host: config.apnsHost,
        topic: config.apnsTopic,
        tokenProvider: () => tokenProvider.token(),
        logger,
      });
      // 403 ExpiredProviderToken: drop the cached provider token so the next
      // attempt mints a fresh one instead of failing the same way.
      const originalSend = transport.send.bind(transport);
      transport.send = async (tokenBytes, aps, sendOptions) => {
        const result = await originalSend(tokenBytes, aps, sendOptions);
        if (result.refreshProviderToken) tokenProvider.invalidate();
        return result;
      };
    } else {
      // Dry-run or unconfigured: no socket, by construction.
      transport = new RecordingTransport({ simulateAccepted: false });
    }
  }

  const engine = new DeliveryEngine({ registry, transport, quoteSource, config, now, logger });
  const server = new PushBridgeServer({ config, registry, engine, quoteSource, now, logger });

  return {
    config,
    store,
    registry,
    quoteSource,
    transport,
    engine,
    server,
    now,
    logger,
    describe: () => describeConfig(config),
  };
}

/**
 * The scheduler loop.
 *
 * A single `setInterval`-style loop with an in-flight guard: ticks are
 * sequential, and a slow tick delays the next one rather than overlapping with
 * it. The interval is the *poll* cadence, not the push cadence; the engine's own
 * `updateIntervalSeconds` governs how often a running activity is refreshed.
 */
class SchedulerLoop {
  constructor({ engine, now = () => Date.now(), logger = null, pollIntervalMs = 5_000 }) {
    this.engine = engine;
    this.now = now;
    this.logger = logger;
    this.pollIntervalMs = pollIntervalMs;
    this.timer = null;
    this.running = false;
    this.ticks = 0;
    this.lastResults = [];
  }

  /** Runs one pass. Exposed so tests can drive the loop without timers. */
  async tickOnce({ force = false } = {}) {
    if (this.running) return { skipped: 'already-running' };
    this.running = true;
    try {
      this.lastResults = await this.engine.runOnce({ force });
      this.ticks += 1;
      return { results: this.lastResults };
    } finally {
      this.running = false;
    }
  }

  start() {
    if (this.timer) return;
    const schedule = () => {
      this.timer = setTimeout(async () => {
        try {
          await this.tickOnce();
        } catch (error) {
          if (this.logger) this.logger.error('scheduler-tick-failed', { message: error.message });
        }
        if (this.timer !== null) schedule();
      }, this.pollIntervalMs);
      // Do not hold the event loop open just for the scheduler.
      if (typeof this.timer.unref === 'function') this.timer.unref();
    };
    schedule();
  }

  stop() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }
}

module.exports = {
  SchedulerLoop,
  createBridge,
  createLogger,
  path,
};
