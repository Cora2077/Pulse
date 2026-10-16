'use strict';

/**
 * Durable state: one JSON document per store, written atomically with mode
 * 0600, inside a directory this service created.
 *
 * Design constraints, in order of importance:
 *
 *   1. *Never write outside our own tree.* The state directory is stamped with
 *      an owner marker on first use. Every subsequent write re-verifies the
 *      directory's real path, refuses a symlinked directory, refuses a
 *      symlinked target file, and refuses a target whose resolved path escapes
 *      the root. A store that has been moved or replaced by a symlink fails
 *      closed instead of writing into it.
 *   2. *Never leave a half-written document.* Writes go to a temp file in the
 *      same directory (same filesystem, so the rename is atomic) with mode 0600
 *      applied at open time — not chmod'd afterwards, which would leave a
 *      window where the file is world-readable.
 *   3. *Never load attacker-shaped JSON.* Parsed documents pass through the
 *      caller's validator; a document that fails validation is treated as
 *      absent rather than partially trusted.
 */

const fs = require('node:fs');
const path = require('node:path');
const { isInsideRoot, isSymlink, logLine } = require('./util');

const OWNER_MARKER_NAME = 'OWNER';
const OWNER_MARKER_CONTENT = 'pulse-push-bridge-state-v1\n';
const FILE_MODE = 0o600;
const DIR_MODE = 0o700;

class StoreError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'StoreError';
    this.code = code;
  }
}

class AtomicJsonStore {
  /**
   * @param {object} options
   * @param {string} options.directory Absolute path of the service-owned dir.
   * @param {string} options.filename  Document name, a bare filename.
   * @param {() => object} options.emptyValue Factory for the absent state.
   * @param {(raw: unknown) => object} options.validate Reject-or-return.
   */
  constructor({ directory, filename, emptyValue, validate, logger = null }) {
    if (!path.isAbsolute(directory)) {
      throw new StoreError('state directory must be absolute', 'not-absolute');
    }
    if (filename !== path.basename(filename) || filename.includes('..')) {
      throw new StoreError('store filename must be a bare name', 'bad-filename');
    }
    this.root = directory;
    this.path = path.join(directory, filename);
    this.tmpPath = path.join(directory, `.${filename}.tmp`);
    this.emptyValue = emptyValue;
    this.validate = validate;
    this.logger = logger;
    this.ensureRoot();
  }

  /** Creates the root on first use and stamps it as ours. */
  ensureRoot() {
    if (!fs.existsSync(this.root)) {
      fs.mkdirSync(this.root, { recursive: true, mode: DIR_MODE });
    }
    const marker = path.join(this.root, OWNER_MARKER_NAME);
    if (!fs.existsSync(marker)) {
      // Adopting a directory is only allowed when it is empty. An operator who
      // points the service at `~/Documents` gets a refusal, not a service that
      // starts writing into their documents.
      const existing = fs.readdirSync(this.root);
      if (existing.length > 0) {
        throw new StoreError(
          `state directory is not empty and is not owned by this service: ${existing.slice(0, 5).join(', ')}`,
          'root-not-owned',
        );
      }
      fs.writeFileSync(marker, OWNER_MARKER_CONTENT, { mode: FILE_MODE, flag: 'wx' });
    }
    this.assertRootIsOurs();
  }

  /**
   * The ownership proof. Called before every read and write, not once at
   * startup, because the interesting attack is *moving the directory* while the
   * service runs.
   */
  assertRootIsOurs() {
    let stat;
    try {
      stat = fs.lstatSync(this.root);
    } catch {
      throw new StoreError('state directory disappeared', 'root-missing');
    }
    if (stat.isSymbolicLink()) {
      throw new StoreError('state directory is a symlink; refusing to use it', 'root-symlink');
    }
    if (!stat.isDirectory()) {
      throw new StoreError('state directory is not a directory', 'root-not-directory');
    }
    const marker = path.join(this.root, OWNER_MARKER_NAME);
    if (!fs.existsSync(marker) || fs.readFileSync(marker, 'utf8') !== OWNER_MARKER_CONTENT) {
      throw new StoreError(
        'state directory is not owned by this service (missing or wrong OWNER marker)',
        'root-not-owned',
      );
    }
  }

  assertTargetIsSafe() {
    this.assertRootIsOurs();
    if (isSymlink(this.path)) {
      throw new StoreError('state file is a symlink; refusing to write through it', 'target-symlink');
    }
    if (!isInsideRoot(this.root, this.path)) {
      throw new StoreError('resolved state path escapes the state directory', 'target-outside-root');
    }
    if (isSymlink(this.tmpPath)) {
      throw new StoreError('temp file path is a symlink', 'target-symlink');
    }
    if (!isInsideRoot(this.root, this.tmpPath)) {
      throw new StoreError('resolved temp path escapes the state directory', 'target-outside-root');
    }
  }

  /**
   * Reads the document.
   *
   * Returns `emptyValue()` for absent *or* corrupt *or* unvalidated state. A
   * corrupt registration file must not resurrect a half-parsed schedule that
   * would fire pushes nobody authorized.
   */
  read() {
    this.assertRootIsOurs();
    if (!fs.existsSync(this.path)) return this.emptyValue();
    if (isSymlink(this.path)) {
      this.warn('state-file-is-symlink');
      return this.emptyValue();
    }
    let text;
    try {
      text = fs.readFileSync(this.path, 'utf8');
    } catch (error) {
      this.warn('state-file-read-failed', { code: error.code });
      return this.emptyValue();
    }
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      this.warn('state-file-not-json');
      return this.emptyValue();
    }
    try {
      return this.validate(parsed);
    } catch (error) {
      this.warn('state-file-failed-validation', { reason: error.message });
      return this.emptyValue();
    }
  }

  /** Atomically replaces the document. Throws `StoreError` on a refused path. */
  write(value) {
    this.assertTargetIsSafe();
    const serialized = JSON.stringify(value);
    const fd = fs.openSync(this.tmpPath, 'w', FILE_MODE);
    try {
      fs.writeSync(fd, serialized, null, 'utf8');
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    // Re-check between write and rename: a file swapped in as a symlink during
    // the write window must not be linked over.
    this.assertTargetIsSafe();
    fs.renameSync(this.tmpPath, this.path);
    // The rename preserves the temp file's mode, but an operator's umask or a
    // pre-existing file with a wider mode is cheap to correct.
    fs.chmodSync(this.path, FILE_MODE);
  }

  /** Reads, mutates and writes, returning whatever the mutator returned. */
  update(mutator) {
    const current = this.read();
    const result = mutator(current);
    this.write(current);
    return result;
  }

  warn(event, details = {}) {
    if (this.logger) this.logger.warn(event, details);
    else process.stderr.write(logLine({ level: 'warn', event, ...details }) + '\n');
  }
}

module.exports = {
  AtomicJsonStore,
  DIR_MODE,
  FILE_MODE,
  OWNER_MARKER_CONTENT,
  OWNER_MARKER_NAME,
  StoreError,
};
