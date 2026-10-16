'use strict';

/**
 * The field-level red line, enforced on the wire.
 *
 * The Swift payload has no position/balance/note field *by construction*; this
 * module makes the same promise hold for anything a client sends. Two rules:
 *
 *   1. Every known object has an explicit allow-list of keys. Unknown keys are
 *      rejected — not stripped — so a client that starts sending a new field
 *      finds out immediately instead of silently having it dropped.
 *   2. Independently of the allow-list, a recursive scan rejects any key that
 *      *looks* sensitive anywhere in the body, at any depth. This is what stops
 *      a future allow-listed nesting point (`attributes`, say) from becoming a
 *      smuggling route for `accountBalance`.
 *
 * Stripping would be friendlier and wrong: if a client can post a position and
 * get a 200, the operator has no signal that private data is leaving the phone.
 */

/**
 * Keys that are never acceptable, at any depth, in any case.
 *
 * Matched on a normalized key (lowercase, non-alphanumerics removed) so
 * `cost_basis`, `costBasis` and `Cost Basis` are all one rule.
 */
const FORBIDDEN_KEY_PATTERNS = [
  // Account and identity
  /^account/, /^accountid$/, /^accountname$/, /^broker/, /^portfolio/, /^userid$/, /^email$/,
  /^phone$/, /^cardnumber$/, /^iban$/, /^taxid$/,
  // Money and position
  /balance/, /position/, /holding/, /shares/, /quantity/, /^qty$/, /size/, /notional/,
  /costbasis/, /avgcost/, /averagecost/, /pnl/, /profitloss/, /equity/, /margin/, /cash/,
  /networth/, /exposure/, /leverage/, /nav$/, /assetvalue/, /marketvalue/,
  // Fills and orders
  /^fill/, /^fills$/, /fillprice/, /filledquantity/, /execution/, /^executionprice$/,
  /^order/, /^orders$/, /tradeid/, /transactionid/, /^trade$/, /^trades$/,
  // Free-form personal content
  /note/, /memo/, /journal/, /comment/, /reason/, /thesis/, /remark/, /diary/,
  // Credentials and device identity.
  //
  // Note the deliberate absence of a bare `/sessionid/` rule: the Swift payload
  // has a legitimate `sessionID` (a market-session label like
  // `sh.2026-10-16.regular`), and matching it would reject the real payload.
  // A *session cookie* is caught by /cookie/ and by the `authorization` rules
  // below, which is where the actual credential lives.
  /token$/, /secret/, /password/, /passwd/, /credential/, /privatekey/, /apikey/, /api_key/,
  /cookie/, /^auth/, /^authorization/, /^bearer/, /deviceid$/, /idfa$/, /idfv$/, /advertisingid/,
  // A bearer/provider token anywhere except the two device tokens this API
  // exists to accept. `pushToStartToken` and `updateToken` are checked by exact
  // name below so that `providerToken`, `accessToken`, `sessionToken` and every
  // future variant stay rejected without an ever-growing suffix list.
  /(?:^|[^a-z])token$/,
];

/**
 * The only token-shaped keys this API accepts.
 *
 * They are device push tokens, which are credentials the *service* must hold to
 * do its job, and they are validated structurally (exact base64, exact byte
 * length) before storage. Anything else ending in `Token` is refused.
 */
const ALLOWED_TOKEN_KEYS = new Set(['pushtostarttoken', 'updatetoken']);

/**
 * Keys allowed on the wire but worth calling out: they are *not* rejected, they
 * are simply documented as forbidden so a reviewer can see the rule exists.
 */
const EXPLICITLY_FORBIDDEN_EXAMPLES = [
  'accountID', 'balance', 'position', 'quantity', 'costBasis', 'fillPrice',
  'realizedPnL', 'note', 'journal', 'apnsToken',
];

/** Normalizes a key for pattern matching. */
function normalizeKey(key) {
  return String(key).toLowerCase().replace(/[^a-z0-9]/g, '');
}

/** Returns the offending key path, or `null` when the body is clean. */
function findForbiddenKey(value, pathPrefix = '$', depth = 0) {
  if (depth > 12) return `${pathPrefix} (nesting too deep)`;
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i += 1) {
      const found = findForbiddenKey(value[i], `${pathPrefix}[${i}]`, depth + 1);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== 'object') return null;
  for (const [key, child] of Object.entries(value)) {
    const normalized = normalizeKey(key);
    const matched = FORBIDDEN_KEY_PATTERNS.find((pattern) => pattern.test(normalized));
    if (matched && !ALLOWED_TOKEN_KEYS.has(normalized)) return `${pathPrefix}.${key}`;
    const found = findForbiddenKey(child, `${pathPrefix}.${key}`, depth + 1);
    if (found) return found;
  }
  return null;
}

/**
 * Enforces an allow-list on one object.
 *
 * @returns {{ok: true} | {ok: false, reason: string, detail?: string}}
 */
function checkAllowedKeys(object, allowedKeys, label) {
  for (const key of Object.keys(object)) {
    if (!allowedKeys.includes(key)) {
      return { ok: false, reason: 'unknown-field', detail: `${label}.${key}` };
    }
  }
  return { ok: true };
}

/**
 * The full gate for one request body.
 *
 * The recursive denylist scan runs first so a body carrying `balance` reports
 * the sensitive-field error rather than the (also true, less useful)
 * unknown-field error.
 */
function screenBody(body, allowedKeys, label = 'body') {
  const forbidden = findForbiddenKey(body);
  if (forbidden) {
    return { ok: false, reason: 'sensitive-field-rejected', detail: forbidden };
  }
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return { ok: false, reason: 'not-an-object' };
  }
  return checkAllowedKeys(body, allowedKeys, label);
}

module.exports = {
  EXPLICITLY_FORBIDDEN_EXAMPLES,
  FORBIDDEN_KEY_PATTERNS,
  checkAllowedKeys,
  findForbiddenKey,
  normalizeKey,
  screenBody,
};
