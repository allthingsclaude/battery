/** APNs provider: ES256 JWT signing and the push itself. */

import { b64url, nowSeconds, utf8 } from './util.js';
import { putDevice } from './store.js';

const APNS_HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};

/**
 * Apple requires the provider JWT to be refreshed no more often than every 20
 * minutes and no less often than every 60. 45 splits the difference.
 */
const JWT_LIFETIME_SECONDS = 45 * 60;

// Cached per isolate. Isolates are recycled freely, so this is an optimisation
// rather than a guarantee — but under normal traffic it keeps us well inside
// Apple's "don't re-sign more than every 20 minutes" guidance.
let cachedJWT = null;

export async function providerToken(env) {
  const now = nowSeconds();
  if (cachedJWT && now - cachedJWT.iat < JWT_LIFETIME_SECONDS) return cachedJWT.token;

  const header = { alg: 'ES256', kid: env.APNS_KEY_ID };
  const claims = { iss: env.APNS_TEAM_ID, iat: now };
  const signingInput = `${b64url(utf8(JSON.stringify(header)))}.${b64url(utf8(JSON.stringify(claims)))}`;

  const key = await importSigningKey(env.APNS_KEY);
  // WebCrypto's ECDSA output is already the raw r‖s pair that JWS ES256 wants,
  // so there's no DER unwrapping to do.
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' }, key, utf8(signingInput),
  );

  const token = `${signingInput}.${b64url(new Uint8Array(signature))}`;
  cachedJWT = { token, iat: now };
  return token;
}

/** Configuration is wrong in a way no retry will fix — say so precisely. */
export class ApnsKeyError extends Error {}

/**
 * Import Apple's `.p8` (a PKCS#8 PEM) as an ECDSA P-256 signing key.
 *
 * Deliberately forgiving about how the secret was pasted, and deliberately loud
 * when it can't be: this is the fiddliest step of deployment, and a bare
 * `atob()` failure surfaces as an opaque 500 that tells you nothing.
 */
async function importSigningKey(pem) {
  if (!pem || !String(pem).trim()) {
    throw new ApnsKeyError('APNS_KEY is not set — run: wrangler secret put APNS_KEY < AuthKey_XXX.p8');
  }

  const cleaned = String(pem)
    .trim()
    // Shell heredocs and .dev.vars entries often arrive wrapped in quotes.
    .replace(/^(['"]{1,3})([\s\S]*)\1$/, '$2')
    // …and with newlines escaped rather than literal.
    .replace(/\\n/g, '\n')
    .trim();

  if (/BEGIN EC PRIVATE KEY/.test(cleaned)) {
    throw new ApnsKeyError(
      'APNS_KEY is a SEC1/PKCS#1 key, not the PKCS#8 that Apple issues. Convert it with: '
      + 'openssl pkcs8 -topk8 -nocrypt -in key.pem -out key.p8',
    );
  }
  if (!/BEGIN PRIVATE KEY/.test(cleaned)) {
    throw new ApnsKeyError(
      'APNS_KEY does not look like a .p8 file (no "BEGIN PRIVATE KEY" header). '
      + 'Upload the file Apple gave you verbatim.',
    );
  }

  const base64 = cleaned
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(base64)) {
    throw new ApnsKeyError('APNS_KEY body is not valid base64 — it may have been truncated or re-wrapped.');
  }

  let der;
  try {
    der = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  } catch {
    throw new ApnsKeyError('APNS_KEY body could not be base64-decoded.');
  }

  try {
    return await crypto.subtle.importKey(
      'pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'],
    );
  } catch {
    throw new ApnsKeyError('APNS_KEY decoded, but is not a P-256 private key. Is this really an APNs auth key?');
  }
}

/**
 * Build the `aps` dictionary for a Live Activity push.
 *
 * Shared by the Mac relay path and the cron poller so the two can't drift into
 * producing subtly different cards.
 */
export function activityPayload(env, opts) {
  const now = nowSeconds();
  const aps = { timestamp: now, event: opts.event, 'content-state': opts.contentState };

  if (opts.staleAfter > 0) aps['stale-date'] = now + Math.round(opts.staleAfter);
  if (typeof opts.relevanceScore === 'number') aps['relevance-score'] = opts.relevanceScore;
  if (opts.event === 'end') {
    // Without a dismissal date the ended card can linger up to four hours.
    aps['dismissal-date'] = now + Math.max(0, Math.round(opts.dismissAfter || 0));
  }
  if (opts.event === 'start') {
    // Must match the Swift type name exactly or ActivityKit silently drops it.
    aps['attributes-type'] = env.ATTRIBUTES_TYPE || 'UsageActivityAttributes';
    aps.attributes = opts.attributes;
  }
  if (opts.alert) {
    aps.alert = {
      title: String(opts.alert.title || ''),
      body: String(opts.alert.body || ''),
      sound: opts.alert.sound === false ? undefined : 'default',
    };
  }
  return { aps };
}

/**
 * POST to APNs, transparently discovering which environment a token belongs to.
 *
 * A development build's token is rejected by the production host with
 * `BadDeviceToken`, so we try the remembered environment first and fall back
 * once — then remember the answer so later pushes are a single request.
 */
export async function deliver(env, opts) {
  const order = opts.record.env
    ? [opts.record.env, opts.record.env === 'production' ? 'sandbox' : 'production']
    : ['production', 'sandbox'];

  let last = null;
  for (const environment of order) {
    const res = await postToAPNs(env, environment, opts);
    last = res;

    if (res.ok) {
      if (opts.record.env !== environment) {
        opts.record.env = environment;
        await putDevice(env, opts.deviceId, opts.record);
      }
      return { ok: true, status: 200, env: environment };
    }

    // Only a token/environment mismatch is worth retrying elsewhere.
    if (res.reason !== 'BadDeviceToken') break;
  }

  // 410 Gone means the token is dead for good — drop it so we stop trying.
  if (last && (last.status === 410 || last.reason === 'Unregistered')) {
    if (opts.token === opts.record.liveActivityToken) {
      opts.record.liveActivityToken = null;
      await putDevice(env, opts.deviceId, opts.record);
    }
    return { ok: false, status: 410, reason: 'Unregistered' };
  }

  return { ok: false, status: last ? last.status : 0, reason: last ? last.reason : 'no_response' };
}

async function postToAPNs(env, environment, opts) {
  const jwt = await providerToken(env);
  const res = await fetch(`${APNS_HOSTS[environment]}/3/device/${opts.token}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${jwt}`,
      'apns-topic': opts.topic,
      'apns-push-type': opts.pushType,
      'apns-priority': String(opts.priority),
      'apns-expiration': '0', // don't queue a stale usage number for later
      'content-type': 'application/json',
    },
    body: JSON.stringify(opts.payload),
  });

  if (res.status === 200) return { ok: true, status: 200 };

  let reason = 'unknown';
  try {
    const parsed = await res.json();
    if (parsed && parsed.reason) reason = parsed.reason;
  } catch { /* APNs occasionally returns an empty body on 5xx */ }
  return { ok: false, status: res.status, reason };
}

/** Silent push that wakes the iOS app so it can reload its Home Screen widgets. */
export async function deliverWidgetReload(env, deviceId, record) {
  if (!record.remoteToken) return null;
  return deliver(env, {
    record, deviceId, token: record.remoteToken,
    payload: { aps: { 'content-available': 1 } },
    pushType: 'background',
    topic: env.BUNDLE_ID,
    priority: 5,
  });
}
