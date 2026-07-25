/**
 * End-to-end smoke test for the push relay, run with plain Node:
 *
 *   node test/smoke.mjs
 *
 * It exercises the real handler against an in-memory KV and a stubbed APNs, and
 * — the part worth having — verifies the ES256 provider JWT with an independent
 * WebCrypto verify. A malformed JWT is otherwise invisible until Apple rejects
 * it in production with an opaque 403.
 */

import assert from 'node:assert/strict';

const worker = (await import('../src/index.js')).default;

// ── fixtures ─────────────────────────────────────────────────────────────

/** A throwaway P-256 key in the PKCS#8 PEM shape Apple hands out as a .p8. */
async function makeAuthKey() {
  const pair = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  const body = Buffer.from(pkcs8).toString('base64').match(/.{1,64}/g).join('\n');
  return {
    pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`,
    publicKey: pair.publicKey,
  };
}

function makeKV() {
  const store = new Map();
  return {
    store,
    async get(key, options) {
      const value = store.get(key);
      if (value === undefined) return null;
      return options?.type === 'json' ? JSON.parse(value) : value;
    },
    async put(key, value) { store.set(key, value); },
    async delete(key) { store.delete(key); },
    async list({ prefix = '' } = {}) {
      const keys = [...store.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name }));
      return { keys, list_complete: true, cursor: null };
    },
  };
}

const post = (path, body) =>
  new Request(`https://relay.test${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });

// ── harness ──────────────────────────────────────────────────────────────

const authKey = await makeAuthKey();
const env = {
  DEVICES: makeKV(),
  BUNDLE_ID: 'com.example.battery',
  APNS_TEAM_ID: 'TEAM123456',
  APNS_KEY_ID: 'KEY7654321',
  ATTRIBUTES_TYPE: 'UsageActivityAttributes',
  APNS_KEY: authKey.pem,
  CLOUD_KEY: 'test-encryption-key-not-a-real-one',
};

/** Every APNs request the worker made, in order. */
const apnsCalls = [];
/** Per-host status overrides, so we can simulate a sandbox-only token. */
let apnsBehaviour = () => ({ status: 200, body: {} });

/** Anthropic stubs — the cron path talks to the token and usage endpoints. */
const anthropicCalls = [];
let tokenBehaviour = () => ({
  status: 200,
  body: { access_token: 'access-1', refresh_token: 'refresh-1', expires_in: 28800 },
});
let usageBehaviour = () => ({
  status: 200,
  body: {
    five_hour: { utilization: 50, resets_at: new Date(Date.now() + 3 * 3600e3).toISOString() },
    seven_day: { utilization: 20, resets_at: new Date(Date.now() + 4 * 86400e3).toISOString() },
  },
});

globalThis.fetch = async (url, init) => {
  const href = String(url);

  if (href.includes('oauth/token') || href.includes('oauth/usage')) {
    const call = { url: href, body: init.body ? JSON.parse(init.body) : null, headers: init.headers };
    anthropicCalls.push(call);
    const { status, body, retryAfter } = href.includes('oauth/token')
      ? tokenBehaviour(call) : usageBehaviour(call);
    return new Response(JSON.stringify(body), {
      status,
      headers: retryAfter ? { 'retry-after': retryAfter } : {},
    });
  }

  const call = { url: href, headers: init.headers, payload: JSON.parse(init.body) };
  apnsCalls.push(call);
  const { status, body } = apnsBehaviour(call);
  return new Response(JSON.stringify(body), { status });
};

/**
 * Drive one cron tick and wait for the work it defers to waitUntil.
 *
 * `scheduledTime` drives the staggered discovery cadence, so tests that care
 * about it pass an explicit tick number rather than relying on wall clock.
 */
async function cronTick(scheduledTime) {
  const deferred = [];
  await worker.scheduled(
    { scheduledTime: scheduledTime ?? Date.now() },
    env,
    { waitUntil: (p) => deferred.push(p) },
  );
  await Promise.all(deferred);
}

/** Find the tick index whose stagger lets this device through the gate. */
function tickTimeForDiscovery(deviceId, wanted = true) {
  let offset = 0;
  for (let i = 0; i < deviceId.length; i++) offset = (offset + deviceId.charCodeAt(i)) % 997;
  for (let tick = 0; tick < 64; tick++) {
    if (((tick + offset) % 3 === 0) === wanted) return tick * 5 * 60 * 1000;
  }
  throw new Error('no suitable tick found');
}

const DEVICE_ID = '3F2504E0-4F89-11D3-9A0C-0305E82C3301';
const DEVICE_SECRET = 'a'.repeat(32);
const ACTIVITY_TOKEN = 'ab'.repeat(32);
const START_TOKEN = 'cd'.repeat(32);
const REMOTE_TOKEN = 'ef'.repeat(32);

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`  ok  ${name}`);
  } catch (err) {
    failures++;
    console.error(`FAIL  ${name}\n      ${err.message}`);
  }
}

// ── tests ────────────────────────────────────────────────────────────────

await check('a malformed APNs key reports why, instead of a blank 500', async () => {
  // Found the hard way: a `.p8` pasted with surrounding quotes made atob()
  // throw, and the only signal was `{"error":"internal_error"}`. This is the
  // fiddliest step of deployment, so it has to name its own failure.
  // Driven at the module rather than through a route: reaching the signer via
  // /v1/push needs a paired device, and the key handling is the point here.
  // Must run before any successful push, or the cached JWT short-circuits it.
  const { providerToken } = await import('../src/apns.js');
  const cases = [
    ['empty', '', /not set/i],
    ['not a key at all', 'hello', /BEGIN PRIVATE KEY/],
    ['a SEC1/PKCS#1 key', '-----BEGIN EC PRIVATE KEY-----\nMHc=\n-----END EC PRIVATE KEY-----', /pkcs8/i],
    ['truncated base64', '-----BEGIN PRIVATE KEY-----\n!!!!\n-----END PRIVATE KEY-----', /base64/i],
    ['valid base64, wrong key type', '-----BEGIN PRIVATE KEY-----\nMHcCAQE=\n-----END PRIVATE KEY-----', /P-256/],
  ];
  for (const [label, key, expected] of cases) {
    await assert.rejects(
      () => providerToken({ ...env, APNS_KEY: key }),
      (err) => expected.test(err.message),
      `"${label}" should explain itself, not throw an opaque error`,
    );
  }
});

await check('a quoted or escaped .p8 is accepted rather than rejected', async () => {
  // How the same key arrives from a .dev.vars line, a heredoc, or a CI secret.
  const { providerToken } = await import('../src/apns.js');
  const variants = [
    ['literal newlines', authKey.pem],
    ['escaped newlines', authKey.pem.replace(/\n/g, '\\n')],
    ['double-quoted', `"${authKey.pem}"`],
    ['triple-quoted', `"""${authKey.pem}"""`],
  ];
  for (const [label, key] of variants) {
    const jwt = await providerToken({ ...env, APNS_KEY: key, __bust: label });
    assert.match(jwt, /^[\w-]+\.[\w-]+\.[\w-]+$/, `${label} should sign`);
  }
});

await check('health responds', async () => {
  const res = await worker.fetch(new Request('https://relay.test/v1/health'), env);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).bundleId, 'com.example.battery');
});

await check('device registration stores tokens', async () => {
  const res = await worker.fetch(post('/v1/device', {
    deviceId: DEVICE_ID,
    deviceSecret: DEVICE_SECRET,
    liveActivityToken: ACTIVITY_TOKEN,
    pushToStartToken: START_TOKEN,
    remoteToken: REMOTE_TOKEN,
    env: 'production',
  }), env);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, paired: false, cloudPolling: false });
});

await check('a wrong secret cannot hijack an existing device id', async () => {
  const res = await worker.fetch(post('/v1/device', {
    deviceId: DEVICE_ID,
    deviceSecret: 'b'.repeat(32),
    liveActivityToken: 'ff'.repeat(32),
  }), env);
  assert.equal(res.status, 403);
});

let pushKey;
await check('pairing mints a code the Mac can redeem', async () => {
  const pairRes = await worker.fetch(post('/v1/pair', {
    deviceId: DEVICE_ID, deviceSecret: DEVICE_SECRET,
  }), env);
  assert.equal(pairRes.status, 200);
  const { code } = await pairRes.json();
  assert.match(code, /^\d{6}$/);

  const claimRes = await worker.fetch(post('/v1/pair/claim', { code }), env);
  assert.equal(claimRes.status, 200);
  const claim = await claimRes.json();
  assert.equal(claim.deviceId, DEVICE_ID);
  assert.ok(claim.pushKey.length >= 32);
  pushKey = claim.pushKey;

  // Single use: the same code must not work twice.
  const replay = await worker.fetch(post('/v1/pair/claim', { code }), env);
  assert.equal(replay.status, 404);
});

await check('push reaches APNs with a verifiable ES256 JWT', async () => {
  apnsCalls.length = 0;
  const res = await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID,
    pushKey,
    event: 'update',
    contentState: {
      sessionUtilization: 62.5,
      sessionResetsAt: 1_753_468_800,
      weeklyUtilization: 41,
      burnRatePerHour: 12.4,
      isSessionActive: true,
      didReset: false,
      updatedAt: 1_753_455_000,
    },
    staleAfter: 720,
    relevanceScore: 62.5,
  }), env);
  assert.equal(res.status, 200);
  assert.equal(apnsCalls.length, 1);

  const call = apnsCalls[0];
  assert.equal(call.url, `https://api.push.apple.com/3/device/${ACTIVITY_TOKEN}`);
  assert.equal(call.headers['apns-push-type'], 'liveactivity');
  assert.equal(call.headers['apns-topic'], 'com.example.battery.push-type.liveactivity');
  assert.equal(call.headers['apns-priority'], '10');

  assert.equal(call.payload.aps.event, 'update');
  assert.equal(call.payload.aps['content-state'].sessionUtilization, 62.5);
  assert.ok(call.payload.aps['stale-date'] > call.payload.aps.timestamp);

  // Independently verify the JWT rather than trusting our own signer.
  const jwt = call.headers.authorization.replace(/^bearer /, '');
  const [rawHeader, rawClaims, rawSignature] = jwt.split('.');
  const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString());
  assert.deepEqual(decode(rawHeader), { alg: 'ES256', kid: 'KEY7654321' });
  assert.equal(decode(rawClaims).iss, 'TEAM123456');

  const valid = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    authKey.publicKey,
    Buffer.from(rawSignature, 'base64url'),
    new TextEncoder().encode(`${rawHeader}.${rawClaims}`),
  );
  assert.ok(valid, 'APNs would have rejected this JWT signature');
});

await check('a sandbox-only token falls back after the production host rejects it', async () => {
  // Forget the remembered environment so the probe order starts at production.
  const record = await env.DEVICES.get(`dev:${DEVICE_ID}`, { type: 'json' });
  record.env = null;
  await env.DEVICES.put(`dev:${DEVICE_ID}`, JSON.stringify(record));

  apnsCalls.length = 0;
  apnsBehaviour = (call) => call.url.includes('sandbox')
    ? { status: 200, body: {} }
    : { status: 400, body: { reason: 'BadDeviceToken' } };

  const res = await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey, contentState: { sessionUtilization: 10, weeklyUtilization: 5 },
  }), env);

  assert.equal(res.status, 200);
  assert.equal(apnsCalls.length, 2, 'expected a production attempt then a sandbox retry');
  assert.ok(apnsCalls[1].url.startsWith('https://api.sandbox.push.apple.com'));

  // The discovered environment must be remembered, so the next push is one call.
  apnsCalls.length = 0;
  await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey, contentState: { sessionUtilization: 11, weeklyUtilization: 5 },
  }), env);
  assert.equal(apnsCalls.length, 1);
  apnsBehaviour = () => ({ status: 200, body: {} });
});

await check('reloadWidgets adds a silent background push', async () => {
  apnsCalls.length = 0;
  await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey,
    contentState: { sessionUtilization: 20, weeklyUtilization: 5 },
    reloadWidgets: true,
  }), env);

  assert.equal(apnsCalls.length, 2);
  const silent = apnsCalls[1];
  assert.equal(silent.url, `https://api.sandbox.push.apple.com/3/device/${REMOTE_TOKEN}`);
  assert.equal(silent.headers['apns-push-type'], 'background');
  assert.equal(silent.headers['apns-topic'], 'com.example.battery');
  assert.deepEqual(silent.payload, { aps: { 'content-available': 1 } });
});

await check('push-to-start carries the attributes ActivityKit needs', async () => {
  apnsCalls.length = 0;
  await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey, event: 'start',
    contentState: { sessionUtilization: 44, weeklyUtilization: 9 },
    attributes: { planTier: 'Max 5x', accountName: 'Account 1' },
  }), env);

  const aps = apnsCalls[0].payload.aps;
  assert.equal(apnsCalls[0].url.endsWith(START_TOKEN), true);
  assert.equal(aps.event, 'start');
  assert.equal(aps['attributes-type'], 'UsageActivityAttributes');
  assert.deepEqual(aps.attributes, { planTier: 'Max 5x', accountName: 'Account 1' });
});

await check('end carries a dismissal date', async () => {
  apnsCalls.length = 0;
  await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey, event: 'end',
    contentState: { sessionUtilization: 2, weeklyUtilization: 9, didReset: true },
    dismissAfter: 30,
  }), env);

  const aps = apnsCalls[0].payload.aps;
  assert.equal(aps.event, 'end');
  assert.equal(aps['dismissal-date'] - aps.timestamp, 30);
});

await check('a stale push key is rejected', async () => {
  const res = await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey: 'z'.repeat(32),
    contentState: { sessionUtilization: 1, weeklyUtilization: 1 },
  }), env);
  assert.equal(res.status, 403);
});

await check('withholding the push-to-start token blocks a remote start', async () => {
  await worker.fetch(post('/v1/device', {
    deviceId: DEVICE_ID, deviceSecret: DEVICE_SECRET, pushToStartToken: null,
  }), env);

  const res = await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey, event: 'start',
    contentState: { sessionUtilization: 44, weeklyUtilization: 9 },
    attributes: { planTier: '', accountName: 'A' },
  }), env);
  assert.equal(res.status, 409);
  assert.equal((await res.json()).error, 'no_push_to_start_token');
});

// ── cloud polling (opt-in) ───────────────────────────────────────────────

await check('enabling cloud sync verifies the grant before storing it', async () => {
  anthropicCalls.length = 0;
  const res = await worker.fetch(post('/v1/cloud', {
    deviceId: DEVICE_ID, deviceSecret: DEVICE_SECRET,
    refreshToken: 'refresh-from-the-phone',
    planTier: 'Max 5x', accountName: 'Account 1',
  }), env);

  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, cloudPolling: true });
  assert.equal(anthropicCalls.length, 1, 'should have exercised the token endpoint');
  assert.equal(anthropicCalls[0].body.grant_type, 'refresh_token');
  // The relay must never request inference rights it has no use for.
  assert.equal(anthropicCalls[0].body.scope, 'user:profile');
});

await check('a server that rejects the narrowed scope falls back to omitting it', async () => {
  // The one hop not verifiable ahead of time: an authorization_code exchange
  // with user:profile is proven, a refresh_token grant carrying it is not.
  // Failing here would be indistinguishable from a revoked grant.
  anthropicCalls.length = 0;
  tokenBehaviour = (call) => (call.body.scope
    ? { status: 400, body: { error: 'invalid_scope' } }
    : { status: 200, body: { access_token: 'fallback-ok', refresh_token: 'r2', expires_in: 28800 } });

  const res = await worker.fetch(post('/v1/cloud', {
    deviceId: DEVICE_ID, deviceSecret: DEVICE_SECRET, refreshToken: 'narrow-grant-token',
  }), env);

  assert.equal(res.status, 200, 'should have recovered by dropping the scope param');
  assert.equal(anthropicCalls.length, 2, 'expected a scoped attempt then an unscoped retry');
  assert.equal(anthropicCalls[0].body.scope, 'user:profile');
  assert.equal(anthropicCalls[1].body.scope, undefined);

  tokenBehaviour = () => ({
    status: 200,
    body: { access_token: 'access-1', refresh_token: 'refresh-1', expires_in: 28800 },
  });
});

await check('the stored refresh token is encrypted at rest', async () => {
  const raw = env.DEVICES.store.get(`cloud:${DEVICE_ID}`);
  assert.ok(!raw.includes('refresh-1'), 'refresh token found in plaintext in KV');
  assert.ok(!raw.includes('refresh-from-the-phone'));
  assert.match(JSON.parse(raw).refreshTokenEnc, /^[\w-]+\.[\w-]+$/);
});

await check('a rejected grant is refused rather than stored', async () => {
  tokenBehaviour = () => ({ status: 400, body: { error: 'invalid_grant' } });
  const res = await worker.fetch(post('/v1/cloud', {
    deviceId: DEVICE_ID, deviceSecret: DEVICE_SECRET, refreshToken: 'already-revoked-token',
  }), env);
  assert.equal(res.status, 400);
  assert.equal((await res.json()).error, 'grant_rejected');
  tokenBehaviour = () => ({
    status: 200,
    body: { access_token: 'access-1', refresh_token: 'refresh-1', expires_in: 28800 },
  });
});

await check('an awake Mac stays primary and claims the card', async () => {
  // The Mac polls the user's own tokens from their own machine, every 60s
  // rather than every 5 minutes, and costs the relay no upstream requests. So
  // it keeps pushing, and holds the cron off rather than the other way round.
  apnsCalls.length = 0;
  const res = await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey,
    contentState: { sessionUtilization: 55, weeklyUtilization: 20 },
  }), env);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.cloudEnabled, true, 'should report that cloud sync exists as a backup');
  assert.ok(apnsCalls.length >= 1, 'the Mac push must actually be delivered');

  const cloud = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`));
  assert.ok(cloud.macActiveUntil > Math.floor(Date.now() / 1000), 'claim not recorded');
});

await check('the cron defers while that claim holds', async () => {
  anthropicCalls.length = 0;
  apnsCalls.length = 0;
  await cronTick();
  assert.equal(anthropicCalls.length, 0, 'must not spend an Anthropic request duplicating the Mac');
  assert.equal(apnsCalls.length, 0);
});

await check('claiming the card does not write KV on every push', async () => {
  // /v1/push is the hot path and KV writes are the scarcest free-tier resource,
  // so a fresh claim must be reused rather than rewritten each time.
  const before = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`)).updatedAt;
  for (let i = 0; i < 3; i++) {
    await worker.fetch(post('/v1/push', {
      deviceId: DEVICE_ID, pushKey,
      contentState: { sessionUtilization: 56 + i, weeklyUtilization: 20 },
    }), env);
  }
  const after = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`)).updatedAt;
  assert.equal(after, before, 'claim was rewritten while still fresh');
});

await check('the cron takes over once the Mac goes quiet', async () => {
  const cloud = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`));
  cloud.macActiveUntil = 0; // the claim lapses — Mac asleep or quit
  env.DEVICES.store.set(`cloud:${DEVICE_ID}`, JSON.stringify(cloud));

  apnsCalls.length = 0;
  await cronTick();

  assert.equal(apnsCalls.length, 2, 'expected the activity push plus a widget reload');
  const activity = apnsCalls[0];
  assert.equal(activity.headers['apns-push-type'], 'liveactivity');
  assert.equal(activity.payload.aps.event, 'update');
  assert.equal(activity.payload.aps['content-state'].sessionUtilization, 50);
  assert.equal(activity.payload.aps['content-state'].weeklyUtilization, 20);
  // Dates must cross the wire as Unix epoch seconds to match the Swift decoder.
  assert.equal(typeof activity.payload.aps['content-state'].sessionResetsAt, 'number');
  assert.ok(activity.payload.aps['content-state'].sessionResetsAt > 1_700_000_000);
});

await check('an unchanged reading does not spend the update budget', async () => {
  apnsCalls.length = 0;
  await cronTick();
  assert.equal(apnsCalls.length, 0, 'nothing moved, so nothing should have been pushed');
});

/**
 * Cron ticks are 5 minutes apart in production but instantaneous in this
 * harness, and the burn-rate estimator deliberately ignores samples closer than
 * ~72 seconds as noise. Backdate the stored sample so elapsed time is realistic.
 */
async function backdateLastPush(seconds) {
  const cloud = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`));
  if (cloud.lastPush) {
    cloud.lastPush.pushedAt -= seconds;
    cloud.lastPush.updatedAt -= seconds;
  }
  env.DEVICES.store.set(`cloud:${DEVICE_ID}`, JSON.stringify(cloud));
}

await check('a 1-point move does push, and derives a burn rate', async () => {
  await backdateLastPush(300);
  usageBehaviour = () => ({
    status: 200,
    body: {
      five_hour: { utilization: 58, resets_at: new Date(Date.now() + 3 * 3600e3).toISOString() },
      seven_day: { utilization: 21, resets_at: new Date(Date.now() + 4 * 86400e3).toISOString() },
    },
  });

  apnsCalls.length = 0;
  await cronTick();
  assert.equal(apnsCalls.length, 2);
  const state = apnsCalls[0].payload.aps['content-state'];
  assert.equal(state.sessionUtilization, 58);
  assert.ok(state.burnRatePerHour > 0, 'two points should yield a rate');
  assert.equal(state.isSessionActive, true);
});

await check('crossing into High raises one alert, not one per tick', async () => {
  usageBehaviour = () => ({
    status: 200,
    body: {
      five_hour: { utilization: 78, resets_at: new Date(Date.now() + 2 * 3600e3).toISOString() },
      seven_day: { utilization: 22, resets_at: new Date(Date.now() + 4 * 86400e3).toISOString() },
    },
  });

  apnsCalls.length = 0;
  await cronTick();
  assert.ok(apnsCalls[0].payload.aps.alert, 'expected an escalation alert');
  assert.match(apnsCalls[0].payload.aps.alert.title, /high/i);

  usageBehaviour = () => ({
    status: 200,
    body: {
      five_hour: { utilization: 80, resets_at: new Date(Date.now() + 2 * 3600e3).toISOString() },
      seven_day: { utilization: 22, resets_at: new Date(Date.now() + 4 * 86400e3).toISOString() },
    },
  });
  apnsCalls.length = 0;
  await cronTick();
  assert.ok(!apnsCalls[0].payload.aps.alert, 'still High — must not alert again');
});

await check('a window rollover ends the card with a reset state', async () => {
  usageBehaviour = () => ({
    status: 200,
    body: {
      five_hour: { utilization: 3, resets_at: new Date(Date.now() + 5 * 3600e3).toISOString() },
      seven_day: { utilization: 22, resets_at: new Date(Date.now() + 4 * 86400e3).toISOString() },
    },
  });

  apnsCalls.length = 0;
  await cronTick();
  const aps = apnsCalls[0].payload.aps;
  assert.equal(aps.event, 'end');
  assert.equal(aps['content-state'].didReset, true);
  assert.ok(aps['dismissal-date'] > aps.timestamp);
});

await check('a rotated refresh token is persisted, not dropped', async () => {
  // Force the next tick to refresh by expiring the stored access token.
  const cloud = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`));
  cloud.accessExpiresAt = 0;
  env.DEVICES.store.set(`cloud:${DEVICE_ID}`, JSON.stringify(cloud));

  const before = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`)).refreshTokenEnc;
  tokenBehaviour = () => ({
    status: 200,
    body: { access_token: 'access-2', refresh_token: 'refresh-ROTATED', expires_in: 28800 },
  });
  usageBehaviour = () => ({
    status: 200,
    body: {
      five_hour: { utilization: 44, resets_at: new Date(Date.now() + 4 * 3600e3).toISOString() },
      seven_day: { utilization: 23, resets_at: new Date(Date.now() + 4 * 86400e3).toISOString() },
    },
  });

  await cronTick();
  const after = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`));
  assert.notEqual(after.refreshTokenEnc, before, 'rotated token was not written back');
  assert.equal(after.accessToken, 'access-2');
});

// ── polling gate: Anthropic's request budget, not Cloudflare's ───────────

await check('a device with no card and no start token is never polled', async () => {
  await worker.fetch(post('/v1/device', {
    deviceId: DEVICE_ID, deviceSecret: DEVICE_SECRET,
    liveActivityToken: null, pushToStartToken: null,
  }), env);

  anthropicCalls.length = 0;
  apnsCalls.length = 0;
  // Every tick in a full stagger cycle, so this can't pass by luck.
  for (let tick = 0; tick < 6; tick++) await cronTick(tick * 5 * 60 * 1000);
  assert.equal(anthropicCalls.length, 0, 'no card to update — must not hit Anthropic at all');
});

await check('with only a start token, polling drops to a staggered third', async () => {
  await worker.fetch(post('/v1/device', {
    deviceId: DEVICE_ID, deviceSecret: DEVICE_SECRET, pushToStartToken: START_TOKEN,
  }), env);
  usageBehaviour = () => ({
    status: 200,
    body: {
      five_hour: { utilization: 5, resets_at: new Date(Date.now() + 4 * 3600e3).toISOString() },
      seven_day: { utilization: 9, resets_at: new Date(Date.now() + 4 * 86400e3).toISOString() },
    },
  });

  anthropicCalls.length = 0;
  await cronTick(tickTimeForDiscovery(DEVICE_ID, false));
  assert.equal(anthropicCalls.length, 0, 'off-cadence tick should be skipped');

  await cronTick(tickTimeForDiscovery(DEVICE_ID, true));
  assert.equal(anthropicCalls.length, 1, 'on-cadence tick should poll');
  // 5% and idle isn't worth a card, so nothing is pushed either.
  assert.equal(apnsCalls.length, 0);
});

await check('restoring the activity token restores every-tick polling', async () => {
  await worker.fetch(post('/v1/device', {
    deviceId: DEVICE_ID, deviceSecret: DEVICE_SECRET, liveActivityToken: ACTIVITY_TOKEN,
  }), env);

  anthropicCalls.length = 0;
  await cronTick(tickTimeForDiscovery(DEVICE_ID, false));
  assert.equal(anthropicCalls.length, 1, 'a live card must be polled on every tick');
});

// ── rate limiting ────────────────────────────────────────────────────────

await check('a 429 parks the device and honours Retry-After', async () => {
  usageBehaviour = () => ({ status: 429, body: { error: 'rate_limited' }, retryAfter: '900' });
  anthropicCalls.length = 0;
  await cronTick();
  assert.equal(anthropicCalls.length, 1);

  const parked = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`));
  assert.equal(parked.rateLimitStrikes, 1);
  const backoff = parked.backoffUntil - Math.floor(Date.now() / 1000);
  assert.ok(backoff > 800 && backoff <= 900, `expected ~900s of backoff, got ${backoff}`);

  // The whole point: while parked, no upstream request is made at all.
  anthropicCalls.length = 0;
  await cronTick();
  await cronTick();
  assert.equal(anthropicCalls.length, 0, 'a parked device must make no requests');
});

await check('backoff clears once a poll gets through', async () => {
  const parked = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`));
  parked.backoffUntil = 0; // simulate the window elapsing
  env.DEVICES.store.set(`cloud:${DEVICE_ID}`, JSON.stringify(parked));

  usageBehaviour = () => ({
    status: 200,
    body: {
      five_hour: { utilization: 61, resets_at: new Date(Date.now() + 2 * 3600e3).toISOString() },
      seven_day: { utilization: 24, resets_at: new Date(Date.now() + 4 * 86400e3).toISOString() },
    },
  });
  await cronTick();

  const after = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`));
  assert.equal(after.rateLimitStrikes, 0);
  assert.equal(after.backoffUntil, 0);
});

await check('a revoked grant disables cloud polling instead of retrying forever', async () => {
  const cloud = JSON.parse(env.DEVICES.store.get(`cloud:${DEVICE_ID}`));
  cloud.accessExpiresAt = 0;
  env.DEVICES.store.set(`cloud:${DEVICE_ID}`, JSON.stringify(cloud));

  tokenBehaviour = () => ({ status: 400, body: { error: 'invalid_grant' } });
  await cronTick();
  assert.equal(env.DEVICES.store.get(`cloud:${DEVICE_ID}`), undefined,
               'the cloud record should be gone');

  // The Mac keeps working regardless, and now reports no cloud backup.
  const res = await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey,
    contentState: { sessionUtilization: 30, weeklyUtilization: 10 },
  }), env);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.cloudEnabled, false);
});

// ── teardown ─────────────────────────────────────────────────────────────

await check('unpairing revokes the push key', async () => {
  const res = await worker.fetch(post('/v1/unpair', {
    deviceId: DEVICE_ID, deviceSecret: DEVICE_SECRET,
  }), env);
  assert.equal(res.status, 200);

  const after = await worker.fetch(post('/v1/push', {
    deviceId: DEVICE_ID, pushKey,
    contentState: { sessionUtilization: 1, weeklyUtilization: 1 },
  }), env);
  assert.equal(after.status, 404);
});

console.log(failures ? `\n${failures} failing` : '\nall passing');
process.exit(failures ? 1 : 0);
