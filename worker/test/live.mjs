/**
 * Integration test against a DEPLOYED relay.
 *
 *   node test/live.mjs https://battery-push.<subdomain>.workers.dev
 *
 * Unlike test/smoke.mjs — which stubs APNs — this talks to the real service and
 * the real Apple. It needs no Cloudflare credentials: every route here is
 * authenticated by a device secret this script generates and then throws away.
 *
 * The interesting assertion is the push. It uses a syntactically valid but
 * nonexistent device token, so Apple must reject it — and *which* rejection
 * comes back is the diagnosis:
 *
 *   BadDeviceToken        the whole chain works. Workers reached APNs over
 *                         HTTP/2, and Apple accepted our ES256 JWT, which means
 *                         the team id, key id, and .p8 all line up. Only the
 *                         made-up token was wrong — exactly as intended.
 *   InvalidProviderToken  reachable, but the JWT was refused: APNS_TEAM_ID,
 *                         APNS_KEY_ID, or APNS_KEY don't match each other.
 *   TopicDisallowed       key and team are fine, but BUNDLE_ID isn't an app id
 *                         under that team.
 *   (a hang or 5xx)       egress to api.push.apple.com is the problem.
 *
 * Everything it creates is removed on the way out.
 */

import assert from 'node:assert/strict';
import crypto from 'node:crypto';

const base = (process.argv[2] || process.env.RELAY_URL || '').replace(/\/$/, '');
if (!base) {
  console.error('usage: node test/live.mjs https://your-worker.workers.dev');
  process.exit(2);
}

const deviceId = crypto.randomUUID().toUpperCase();
const deviceSecret = crypto.randomBytes(32).toString('base64');
// Well-formed (64 hex chars) but not a real registration.
const fakeToken = crypto.randomBytes(32).toString('hex');

let failures = 0;
let pushKey = null;

async function check(name, fn) {
  try {
    await fn();
    console.log(`  ok  ${name}`);
  } catch (err) {
    failures++;
    console.error(`FAIL  ${name}\n      ${err.message}`);
  }
}

async function post(path, body) {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  let parsed = null;
  try { parsed = await res.json(); } catch { /* empty body */ }
  return { status: res.status, body: parsed };
}

console.log(`\nRelay: ${base}\n`);

await check('health responds and reports a bundle id', async () => {
  const res = await fetch(`${base}/v1/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.ok(body.bundleId, 'BUNDLE_ID is not configured');
  console.log(`      bundleId: ${body.bundleId}`);
});

await check('registers a device', async () => {
  const { status, body } = await post('/v1/device', {
    deviceId, deviceSecret, liveActivityToken: fakeToken, env: 'sandbox',
  });
  assert.equal(status, 200);
  assert.equal(body.paired, false);
  assert.equal(body.cloudPolling, false);
});

await check('rejects a wrong secret for a known device', async () => {
  const { status } = await post('/v1/device', {
    deviceId, deviceSecret: crypto.randomBytes(32).toString('base64'),
  });
  assert.equal(status, 403);
});

await check('pairing code round-trips and is single-use', async () => {
  const pair = await post('/v1/pair', { deviceId, deviceSecret });
  assert.equal(pair.status, 200);
  assert.match(pair.body.code, /^\d{6}$/);

  const claim = await post('/v1/pair/claim', { code: pair.body.code });
  assert.equal(claim.status, 200);
  assert.equal(claim.body.deviceId, deviceId);
  pushKey = claim.body.pushKey;

  const replay = await post('/v1/pair/claim', { code: pair.body.code });
  assert.equal(replay.status, 404, 'a burned code must not be reusable');
});

await check('THE ONE THAT MATTERS: a real APNs round-trip', async () => {
  const started = Date.now();
  const { status, body } = await post('/v1/push', {
    deviceId, pushKey,
    contentState: {
      sessionUtilization: 62.5,
      weeklyUtilization: 41,
      burnRatePerHour: 12.4,
      isSessionActive: true,
      didReset: false,
      updatedAt: Math.floor(Date.now() / 1000),
      sessionResetsAt: Math.floor(Date.now() / 1000) + 7200,
    },
    staleAfter: 720,
    relevanceScore: 62.5,
  });
  const elapsed = Date.now() - started;

  const reason = body?.activity?.reason;
  console.log(`      status ${status}, reason "${reason}", ${elapsed}ms`);

  if (body?.error === 'apns_key_invalid') {
    throw new Error(`APNS_KEY is misconfigured: ${body.detail}`);
  }
  assert.ok(reason, `no APNs reason came back — body was ${JSON.stringify(body)}`);

  if (reason === 'InvalidProviderToken') {
    throw new Error('Reached Apple, but the JWT was refused — check APNS_TEAM_ID / APNS_KEY_ID / APNS_KEY agree.');
  }
  if (reason === 'TopicDisallowed') {
    throw new Error('Key and team are valid, but BUNDLE_ID is not an app id under that team.');
  }
  assert.equal(reason, 'BadDeviceToken',
    `expected BadDeviceToken for a made-up token; got "${reason}"`);

  console.log('      → Workers reached APNs over HTTP/2 and Apple accepted the ES256 JWT.');
});

await check('rejects a forged push key', async () => {
  const { status } = await post('/v1/push', {
    deviceId, pushKey: crypto.randomBytes(32).toString('base64'),
    contentState: { sessionUtilization: 1, weeklyUtilization: 1 },
  });
  assert.equal(status, 403);
});

await check('refuses a bogus cloud-sync grant instead of storing it', async () => {
  const { status, body } = await post('/v1/cloud', {
    deviceId, deviceSecret, refreshToken: 'definitely-not-a-real-refresh-token',
  });
  // Anthropic rejects it (400 → grant_rejected); a 502 means the relay couldn't
  // reach the token endpoint, which is worth knowing too.
  assert.ok(status === 400 || status === 502, `unexpected ${status}`);
  if (status === 502) throw new Error('relay could not reach the Claude token endpoint');
  assert.equal(body.error, 'grant_rejected');
});

await check('cleans up after itself', async () => {
  const { status } = await post('/v1/unpair', { deviceId, deviceSecret, forget: true });
  assert.equal(status, 200);
  const after = await post('/v1/push', {
    deviceId, pushKey, contentState: { sessionUtilization: 1, weeklyUtilization: 1 },
  });
  assert.equal(after.status, 404, 'the device record should be gone');
});

console.log(failures ? `\n${failures} failing\n` : '\nall passing — the relay is live and reaching Apple\n');
process.exit(failures ? 1 : 0);
