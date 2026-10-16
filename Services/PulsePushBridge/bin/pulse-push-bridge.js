#!/usr/bin/env node
'use strict';

/**
 * Entry point.
 *
 *   node bin/pulse-push-bridge.js            # dry-run, 127.0.0.1
 *   node bin/pulse-push-bridge.js --check    # validate config and exit
 *
 * There is no `--host`, no `--token`, no `--key` flag. Everything comes from the
 * environment, so a shell history or a process listing cannot leak a credential,
 * and an operator cannot accidentally point the service somewhere by typing.
 */

const { createBridge, createLogger, SchedulerLoop } = require('../src/bridge');
const { ConfigError } = require('../src/config');
const { StoreError } = require('../src/store');

function main(argv) {
  const checkOnly = argv.includes('--check');
  const onceTick = argv.includes('--tick-once');

  let bridge;
  try {
    bridge = createBridge();
  } catch (error) {
    if (error instanceof ConfigError || error instanceof StoreError) {
      process.stderr.write(JSON.stringify({ level: 'error', event: 'startup-refused', reason: error.message }) + '\n');
      process.exitCode = 2;
      return;
    }
    throw error;
  }

  const { config } = bridge;
  bridge.logger.info('startup', bridge.describe());

  if (!config.liveReady) {
    bridge.logger.warn('not-live', {
      mode: config.mode,
      missing: config.missingLiveRequirements,
      effect: 'no push will leave this process; the API reports unconfigured',
    });
  }

  if (checkOnly) {
    // `--check` deliberately does not open the port: it is the "is my
    // configuration sane" command, and it must not disturb a running instance.
    process.stdout.write(JSON.stringify({ ok: true, config: bridge.describe() }, null, 2) + '\n');
    return;
  }

  const loop = new SchedulerLoop({ engine: bridge.engine, logger: bridge.logger });

  bridge.server.listen().then((address) => {
    const shown = typeof address === 'object' && address ? `${address.address}:${address.port}` : String(address);
    bridge.logger.info('listening', { address: shown, mode: config.mode });
    if (onceTick) {
      loop.tickOnce({ force: true }).then((result) => {
        process.stdout.write(JSON.stringify({ tick: result }, null, 2) + '\n');
        return bridge.server.close();
      }).then(() => {
        loop.stop();
      });
      return;
    }
    loop.start();
  }).catch((error) => {
    bridge.logger.error('listen-failed', { message: error.message });
    process.exitCode = 1;
  });

  const shutdown = (signal) => {
    bridge.logger.info('shutdown', { signal });
    loop.stop();
    bridge.server.close().then(() => process.exit(0));
    // A stuck close must not hang a supervisor's restart.
    setTimeout(() => process.exit(0), 2_000).unref();
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = { main };
