'use strict';

/**
 * APNs provider authentication: a JWT signed with ES256 (P-256 + SHA-256).
 *
 * Two details are easy to get wrong and both are silent:
 *
 *   1. **Signature encoding.** JWS ES256 requires the raw IEEE-P1363 form
 *      (`r || s`, 64 bytes). OpenSSL, and therefore the first thing most people
 *      reach for, emits DER (`SEQUENCE { INTEGER r, INTEGER s }`). Apple rejects
 *      the DER form; the fix is `dsaEncoding: 'ieee-p1363'`, which is requested
 *      explicitly below and asserted in tests by re-verifying the signature.
 *   2. **Token lifetime.** APNs rejects a provider token older than one hour and
 *      treats frequent regeneration as abuse. Tokens are cached and refreshed
 *      at 50 minutes, never per request.
 *
 * The private key is read from the path in the environment, held as a KeyObject
 * in memory, and never serialized, logged, copied into state, or written to a
 * test fixture. Tests generate a throwaway key in-process.
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const { logLine, encodeBase64 } = require('./util');

/** APNs refuses tokens older than 3600 s; refresh well before that. */
const TOKEN_TTL_SECONDS = 50 * 60;

const ES256_RAW_SIGNATURE_BYTES = 64;

class ApnsAuthError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'ApnsAuthError';
    this.code = code;
  }
}

/**
 * Signs and caches provider tokens.
 *
 * The clock is injected so a test can prove the refresh boundary without
 * waiting 50 minutes, and so a production run cannot be affected by a test's
 * fake clock.
 */
class ApnsTokenProvider {
  constructor({ keyPath, keyId, teamId, now = () => Date.now(), logger = null }) {
    this.keyPath = keyPath;
    this.keyId = keyId;
    this.teamId = teamId;
    this.now = now;
    this.logger = logger;
    this.cached = null; // { token, issuedAtSeconds }
  }

  /**
   * Loads the .p8 on demand.
   *
   * Deliberately *not* cached across calls to `loadPrivateKey` during errors:
   * an unreadable key is re-reported rather than remembered as a crash.
   */
  loadPrivateKey() {
    let pem;
    try {
      pem = fs.readFileSync(this.keyPath, 'utf8');
    } catch (error) {
      throw new ApnsAuthError('APNs private key is not readable', `key-${error.code ?? 'error'}`);
    }
    if (!/-----BEGIN PRIVATE KEY-----/.test(pem)) {
      throw new ApnsAuthError('APNs private key is not PKCS#8 PEM', 'key-format');
    }
    try {
      return crypto.createPrivateKey({ key: pem, format: 'pem' });
    } catch {
      throw new ApnsAuthError('APNs private key could not be parsed', 'key-parse');
    }
  }

  /** Seconds since the epoch, from the injected clock. */
  nowSeconds() {
    return Math.floor(this.now() / 1000);
  }

  /**
   * Returns a valid provider token, minting one only when the cached token is
   * absent or older than ``TOKEN_TTL_SECONDS``.
   */
  token() {
    const nowSeconds = this.nowSeconds();
    if (this.cached && nowSeconds - this.cached.issuedAtSeconds < TOKEN_TTL_SECONDS) {
      return this.cached.token;
    }
    const token = this.mint(nowSeconds);
    this.cached = { token, issuedAtSeconds: nowSeconds };
    if (this.logger) this.logger.info('apns-provider-token-minted', { kid: '[present]' });
    return token;
  }

  /** Builds and signs one JWT. Exposed for tests; not for request paths. */
  mint(issuedAtSeconds = this.nowSeconds()) {
    const header = { alg: 'ES256', kid: this.keyId, typ: 'JWT' };
    const claims = { iss: this.teamId, iat: issuedAtSeconds };
    const signingInput = `${b64urlJson(header)}.${b64urlJson(claims)}`;
    const key = this.loadPrivateKey();
    const signature = crypto.sign('sha256', Buffer.from(signingInput, 'utf8'), {
      key,
      // The one line that makes this a JWS ES256 signature rather than DER.
      dsaEncoding: 'ieee-p1363',
    });
    if (signature.length !== ES256_RAW_SIGNATURE_BYTES) {
      throw new ApnsAuthError('ES256 signature is not IEEE-P1363 (64 bytes)', 'signature-encoding');
    }
    return `${signingInput}.${signature.toString('base64url')}`;
  }

  /** Drops the cache, e.g. after APNs answered 403 InvalidProviderToken. */
  invalidate() {
    this.cached = null;
  }
}

function b64urlJson(value) {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
}

/**
 * Verifies a minted token the way APNs would, using the public key.
 *
 * Exists so the test suite can prove the signature is a real ES256 JWS
 * signature over the exact signing input, not merely 64 bytes long.
 */
function verifyMintedToken(token, publicKey) {
  const parts = token.split('.');
  if (parts.length !== 3) return { ok: false, reason: 'bad-jws-shape' };
  const [header, claims, signature] = parts;
  const signatureBuffer = Buffer.from(signature, 'base64url');
  if (signatureBuffer.length !== ES256_RAW_SIGNATURE_BYTES) {
    return { ok: false, reason: 'signature-not-64-bytes', length: signatureBuffer.length };
  }
  const valid = crypto.verify(
    'sha256',
    Buffer.from(`${header}.${claims}`, 'utf8'),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    signatureBuffer,
  );
  if (!valid) return { ok: false, reason: 'signature-invalid' };
  const decodedHeader = JSON.parse(Buffer.from(header, 'base64url').toString('utf8'));
  const decodedClaims = JSON.parse(Buffer.from(claims, 'base64url').toString('utf8'));
  return { ok: true, header: decodedHeader, claims: decodedClaims };
}

/** Generates a throwaway P-256 key pair for tests. Never written to disk. */
function generateTestKeyPair() {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return {
    privateKey,
    publicKey,
    privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  };
}

module.exports = {
  ApnsAuthError,
  ApnsTokenProvider,
  ES256_RAW_SIGNATURE_BYTES,
  TOKEN_TTL_SECONDS,
  encodeBase64,
  generateTestKeyPair,
  logLine,
  verifyMintedToken,
};
