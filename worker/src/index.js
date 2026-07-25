/**
 * Battery push relay — keeps the iPhone's Live Activity current while the iOS
 * app is suspended.
 *
 * Two independent paths feed the same Lock Screen card:
 *
 *   1. RELAY (default, zero credential custody)
 *      The Mac app polls Anthropic with the user's own tokens and POSTs the
 *      already-computed numbers to /v1/push. This service never sees a Claude
 *      credential; it only signs an APNs JWT and forwards.
 *
 *   2. CLOUD (opt-in)
 *      For when no Mac of yours is awake — coding from claude.ai, or from a
 *      machine that isn't running Battery. The phone hands over a *separate*
 *      OAuth grant scoped to `user:profile` only, which reads usage but cannot
 *      make inference calls billed to the account, and a cron tick polls and
 *      pushes. The token is encrypted at rest under a Worker secret.
 *
 * When cloud polling is on it is authoritative and the Mac stands down, so the
 * two never contend for Apple's per-activity update budget.
 */

import {
  asHexToken, asId, asSecret, decryptSecret, encryptSecret, json, nowSeconds, randomToken, sha256,
} from './util.js';
import {
  deleteCloud, deleteDevice, getCloud, getDevice, listCloudDeviceIds,
  mintUnusedCode, putCloud, putCode, putDevice, takeCode, PAIR_CODE_TTL_SECONDS,
} from './store.js';
import { activityPayload, ApnsKeyError, deliver, deliverWidgetReload } from './apns.js';
import {
  buildContentState, fetchUsage, GrantRevokedError, isAlarming, RateLimitedError,
  refreshAccessToken, usageLevel,
} from './anthropic.js';

/** Reject oversized bodies before parsing — nothing legitimate is this big. */
const MAX_BODY_BYTES = 16 * 1024;

// Cron cadence is every 5 minutes (see wrangler.toml), so a card is dimmed only
// after three consecutive misses.
const CLOUD_STALE_AFTER = 15 * 60;
/** Push even with nothing new, so the card doesn't cross its stale date. */
const CLOUD_HEARTBEAT = 10 * 60;
/** Don't push for movement smaller than this (percentage points). */
const CLOUD_MIN_DELTA = 1.0;
/** Mirrors LiveActivityController.startThreshold on the phone. */
const START_THRESHOLD = 40;
/** Must match the cron expression in wrangler.toml. */
const CRON_INTERVAL_SECONDS = 5 * 60;
/** Devices with no card on screen are polled on 1 tick in this many. */
const DISCOVERY_TICK_DIVISOR = 3;
/** Rate-limit backoff, doubling per consecutive strike. */
const BACKOFF_BASE_SECONDS = 5 * 60;
const BACKOFF_MAX_SECONDS = 60 * 60;
/**
 * How long one Mac push holds the card against the cron, and how much of that
 * must have elapsed before the claim is renewed. The gap between them is what
 * keeps /v1/push from writing KV on every request: a Mac pushing once a minute
 * writes roughly once every six.
 *
 * CARD_CLAIM_SECONDS also bounds how stale the card can get if the Mac dies
 * mid-session — the cron takes back over that long afterwards.
 */
const CARD_CLAIM_SECONDS = 12 * 60;
const CARD_CLAIM_RENEW_SECONDS = 6 * 60;

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (err) {
      // A bad APNs key is a deployment mistake, not a transient fault, and no
      // amount of retrying fixes it — surface the reason instead of a blank 500.
      if (err instanceof ApnsKeyError) {
        console.error('APNs key rejected:', err.message);
        return json({ error: 'apns_key_invalid', detail: err.message }, 500);
      }
      // Otherwise never leak internals; the stack goes to `wrangler tail`.
      console.error('unhandled', err && err.stack);
      return json({ error: 'internal_error' }, 500);
    }
  },

  async scheduled(event, env, ctx) {
    // scheduledTime drives the staggered discovery cadence below; fall back to
    // wall clock if a caller (or a test) didn't supply one.
    ctx.waitUntil(runCloudPoll(env, event?.scheduledTime ?? Date.now()));
  },
};

// ─────────────────────────────────────────────────────────── routing ──

async function route(request, env) {
  const { pathname } = new URL(request.url);

  if (request.method === 'GET' && pathname === '/v1/health') {
    return json({ ok: true, bundleId: env.BUNDLE_ID });
  }
  if (request.method !== 'POST') return json({ error: 'not_found' }, 404);

  const body = await readJSON(request);
  if (body === null) return json({ error: 'invalid_body' }, 400);

  switch (pathname) {
    case '/v1/device':     return registerDevice(body, env);
    case '/v1/pair':       return startPairing(body, env);
    case '/v1/pair/claim': return claimPairing(body, env);
    case '/v1/push':       return relayPush(body, env);
    case '/v1/cloud':      return configureCloud(body, env);
    case '/v1/unpair':     return unpair(body, env);
    default:               return json({ error: 'not_found' }, 404);
  }
}

// ────────────────────────────────────────────────────────── handlers ──

/**
 * The phone calls this on first launch and again whenever iOS rotates a push
 * token (which it does freely — tokens are not stable identifiers).
 *
 * The device id and secret are generated *on the phone*; only a hash of the
 * secret is stored, so a KV dump can't be replayed against us.
 */
async function registerDevice(body, env) {
  const deviceId = asId(body.deviceId);
  const deviceSecret = asSecret(body.deviceSecret);
  if (!deviceId || !deviceSecret) return json({ error: 'invalid_credentials' }, 400);

  const secretHash = await sha256(deviceSecret);
  const existing = await getDevice(env, deviceId);

  // Claiming an id someone else registered must fail, or anyone could hijack a
  // device record by guessing its id.
  if (existing && existing.secretHash !== secretHash) return json({ error: 'forbidden' }, 403);

  const record = existing || {
    secretHash,
    pushKeyHash: null,
    liveActivityToken: null,
    pushToStartToken: null,
    remoteToken: null,
    env: null,
    createdAt: nowSeconds(),
  };

  // Each token is optional and updated independently — the phone learns them at
  // different moments (remote token at launch, activity token only once an
  // activity actually starts). An explicit null clears one.
  for (const field of ['liveActivityToken', 'pushToStartToken', 'remoteToken']) {
    if (!(field in body)) continue;
    if (body[field] === null) { record[field] = null; continue; }
    const hex = asHexToken(body[field]);
    if (!hex) return json({ error: `invalid_${field}` }, 400);
    record[field] = hex;
  }

  // A debug build from Xcode gets a sandbox token; TestFlight/App Store gets a
  // production one. The phone reports which, so we skip the discovery probe.
  if (body.env === 'sandbox' || body.env === 'production') record.env = body.env;

  await putDevice(env, deviceId, record);
  return json({
    ok: true,
    paired: record.pushKeyHash !== null,
    cloudPolling: (await getCloud(env, deviceId)) !== null,
  });
}

/** Phone asks for a code to display; the Mac types it in. */
async function startPairing(body, env) {
  const auth = await authenticateDevice(body, env);
  if (auth.error) return auth.error;

  const code = await mintUnusedCode(env);
  if (!code) return json({ error: 'code_unavailable' }, 503);

  await putCode(env, code, auth.deviceId);
  return json({ code, expiresIn: PAIR_CODE_TTL_SECONDS });
}

/**
 * Redeeming a code mints a *separate* push key for the Mac. The phone's own
 * secret is never handed over, so a compromised Mac can push to the activity
 * but can't re-register tokens, enable cloud sync, or unpair the device.
 */
async function claimPairing(body, env) {
  const code = typeof body.code === 'string' ? body.code.replace(/\D/g, '') : '';
  if (code.length !== 6) return json({ error: 'invalid_code' }, 400);

  // Single use: taking it burns it, so a shoulder-surfer can't reuse it.
  const deviceId = await takeCode(env, code);
  if (!deviceId) return json({ error: 'code_expired' }, 404);

  const record = await getDevice(env, deviceId);
  if (!record) return json({ error: 'unknown_device' }, 404);

  const pushKey = randomToken(32);
  record.pushKeyHash = await sha256(pushKey);
  await putDevice(env, deviceId, record);

  return json({ deviceId, pushKey });
}

/**
 * The Mac's hot path. Takes a fully-formed `content-state` and forwards it.
 *
 * Deliberately does no interpretation of the numbers: that keeps the card's
 * shape a client-side concern, so changing its fields never means redeploying.
 */
async function relayPush(body, env) {
  const deviceId = asId(body.deviceId);
  const pushKey = asSecret(body.pushKey);
  if (!deviceId || !pushKey) return json({ error: 'invalid_credentials' }, 400);

  const record = await getDevice(env, deviceId);
  if (!record || !record.pushKeyHash) return json({ error: 'not_paired' }, 404);
  if (record.pushKeyHash !== (await sha256(pushKey))) return json({ error: 'forbidden' }, 403);

  const event = body.event === 'start' || body.event === 'end' ? body.event : 'update';
  const state = body.contentState;
  if (!state || typeof state !== 'object') return json({ error: 'missing_content_state' }, 400);
  if (event === 'start' && (!body.attributes || typeof body.attributes !== 'object')) {
    return json({ error: 'missing_attributes' }, 400);
  }

  const token = event === 'start' ? record.pushToStartToken : record.liveActivityToken;
  if (!token) {
    return json({ error: event === 'start' ? 'no_push_to_start_token' : 'no_activity_token' }, 409);
  }

  const result = await deliver(env, {
    record, deviceId, token,
    payload: activityPayload(env, {
      event,
      contentState: state,
      staleAfter: body.staleAfter,
      relevanceScore: body.relevanceScore,
      dismissAfter: body.dismissAfter,
      attributes: body.attributes,
      alert: body.alert,
    }),
    pushType: 'liveactivity',
    topic: `${env.BUNDLE_ID}.push-type.liveactivity`,
    // Live Activity updates are user-visible and time-sensitive; 10 is the
    // "deliver immediately" priority Apple expects for them.
    priority: 10,
  });

  // ActivityKit pushes can't touch the Home Screen widgets — those read an App
  // Group container only the app process can write. A silent push wakes it.
  const widgets = body.reloadWidgets ? await deliverWidgetReload(env, deviceId, record) : null;

  // An awake Mac is the better source: it polls on the user's own tokens from
  // their own machine, every 60s instead of every 5 minutes, and costs this
  // service no upstream requests at all. So it claims the card, and the cron
  // steps aside while the claim holds.
  const cloudEnabled = result.ok ? await claimCardForMac(env, deviceId) : false;

  const status = result.ok ? 200 : result.status === 410 ? 410 : 502;
  return json({ ok: result.ok, activity: result, widgets, cloudEnabled }, status);
}

/**
 * Mark the card as Mac-driven, and report whether cloud sync is even enabled.
 *
 * The claim is renewed lazily rather than on every push, because /v1/push is
 * the hot path and KV writes are the scarcest thing on the free tier. One write
 * buys CARD_CLAIM_SECONDS of cron silence, so a continuously-pushing Mac costs
 * roughly one write per CARD_CLAIM_RENEW_SECONDS rather than one per push.
 */
async function claimCardForMac(env, deviceId) {
  const cloud = await getCloud(env, deviceId);
  if (!cloud) return false; // nothing to hold off — cloud sync isn't on

  const now = nowSeconds();
  const remaining = (cloud.macActiveUntil || 0) - now;
  if (remaining < CARD_CLAIM_RENEW_SECONDS) {
    await putCloud(env, deviceId, { ...cloud, macActiveUntil: now + CARD_CLAIM_SECONDS });
  }
  return true;
}

/**
 * Opt in or out of cloud polling.
 *
 * Requires the *device* secret rather than the Mac's push key: handing over a
 * Claude grant is the phone owner's decision alone.
 */
async function configureCloud(body, env) {
  const auth = await authenticateDevice(body, env);
  if (auth.error) return auth.error;

  if (body.enabled === false) {
    await deleteCloud(env, auth.deviceId);
    return json({ ok: true, cloudPolling: false });
  }

  const refreshToken = body.refreshToken;
  if (typeof refreshToken !== 'string' || refreshToken.length < 16 || refreshToken.length > 4096) {
    return json({ error: 'invalid_refresh_token' }, 400);
  }

  // Verify before storing: a token we can't actually use would fail silently on
  // a cron tick hours later, with nothing on screen to explain it.
  let refreshed;
  try {
    refreshed = await refreshAccessToken(refreshToken);
  } catch (err) {
    return json({ error: err instanceof GrantRevokedError ? 'grant_rejected' : 'upstream_error' },
                err instanceof GrantRevokedError ? 400 : 502);
  }

  await putCloud(env, auth.deviceId, {
    refreshTokenEnc: await encryptSecret(env, refreshed.refreshToken),
    accessToken: refreshed.accessToken,
    accessExpiresAt: refreshed.expiresAt,
    planTier: typeof body.planTier === 'string' ? body.planTier.slice(0, 32) : '',
    accountName: typeof body.accountName === 'string' ? body.accountName.slice(0, 64) : 'Account',
    lastPush: null,
    alertedLevel: null,
    createdAt: nowSeconds(),
  });

  return json({ ok: true, cloudPolling: true });
}

/** Either side can revoke: the phone with its secret, the Mac with its key. */
async function unpair(body, env) {
  const deviceId = asId(body.deviceId);
  if (!deviceId) return json({ error: 'invalid_credentials' }, 400);

  const record = await getDevice(env, deviceId);
  if (!record) return json({ ok: true });

  const secret = asSecret(body.deviceSecret);
  const pushKey = asSecret(body.pushKey);
  const bySecret = secret && record.secretHash === (await sha256(secret));
  const byPushKey = pushKey && record.pushKeyHash && record.pushKeyHash === (await sha256(pushKey));
  if (!bySecret && !byPushKey) return json({ error: 'forbidden' }, 403);

  if (bySecret && body.forget) {
    await deleteDevice(env, deviceId);
    return json({ ok: true, forgotten: true });
  }

  record.pushKeyHash = null;
  await putDevice(env, deviceId, record);
  return json({ ok: true });
}

async function authenticateDevice(body, env) {
  const deviceId = asId(body.deviceId);
  const deviceSecret = asSecret(body.deviceSecret);
  if (!deviceId || !deviceSecret) return { error: json({ error: 'invalid_credentials' }, 400) };

  const record = await getDevice(env, deviceId);
  if (!record) return { error: json({ error: 'unknown_device' }, 404) };
  if (record.secretHash !== (await sha256(deviceSecret))) {
    return { error: json({ error: 'forbidden' }, 403) };
  }
  return { deviceId, record };
}

// ───────────────────────────────────────────────────── cloud polling ──

/** Cron entry point: poll every opted-in device and push what changed. */
async function runCloudPoll(env, scheduledTime) {
  const deviceIds = await listCloudDeviceIds(env);
  const results = await Promise.allSettled(
    deviceIds.map((id) => pollDevice(env, id, scheduledTime)),
  );

  const failed = results.filter((r) => r.status === 'rejected');
  const tally = (value) => results.filter((r) => r.status === 'fulfilled' && r.value === value).length;
  for (const failure of failed) console.error('cloud poll failed', failure.reason);
  console.log(
    `cloud poll: ${deviceIds.length} enrolled, ${tally('polled')} polled, `
    + `${tally('mac-active')} deferred to Mac, ${failed.length} failed`,
  );
}

/**
 * Should this device be polled on this tick?
 *
 * The point of cloud polling is to keep a Lock Screen card moving, so a device
 * with no card on screen is mostly wasted work — and the request budget that
 * actually matters here is Anthropic's, not Cloudflare's. Two gates:
 *
 *   • no push tokens at all → never poll (the phone withholds its
 *     push-to-start token when the user has Live Activities off, so this is
 *     also how "off" is honoured)
 *   • a card is running → poll every tick
 *   • no card, but we could start one → poll at a third of the cadence
 *
 * The reduced cadence is derived from the tick number rather than stored, so it
 * costs no writes, and it's offset by a hash of the device id so enrolled
 * devices spread across ticks instead of stampeding on every third one.
 */
function shouldPollNow(deviceId, record, scheduledTime) {
  if (record.liveActivityToken) return true;
  if (!record.pushToStartToken) return false;

  const tick = Math.floor(scheduledTime / (CRON_INTERVAL_SECONDS * 1000));
  let offset = 0;
  for (let i = 0; i < deviceId.length; i++) offset = (offset + deviceId.charCodeAt(i)) % 997;
  return (tick + offset) % DISCOVERY_TICK_DIVISOR === 0;
}

async function pollDevice(env, deviceId, scheduledTime) {
  let cloud = await getCloud(env, deviceId);
  if (!cloud) return 'skipped';
  const record = await getDevice(env, deviceId);
  if (!record) {
    // Device record expired out from under us; nothing left to push to.
    await deleteCloud(env, deviceId);
    return 'skipped';
  }

  // Parked by a previous 429. Costs one KV read and no upstream request.
  if ((cloud.backoffUntil || 0) > nowSeconds()) return 'skipped';

  // An awake Mac is already keeping this card current, from the user's own
  // machine at a faster cadence than we could manage. Polling anyway would
  // spend Anthropic requests and KV writes to duplicate work that's already
  // done — so stand aside until its claim lapses.
  if ((cloud.macActiveUntil || 0) > nowSeconds()) return 'mac-active';

  if (!shouldPollNow(deviceId, record, scheduledTime)) return 'skipped';

  let usage;
  let refreshedTokens = null;
  try {
    let accessToken = cloud.accessToken;
    // Refresh a little early so a token doesn't expire mid-request.
    if (!accessToken || (cloud.accessExpiresAt || 0) - nowSeconds() < 300) {
      refreshedTokens = await refreshAccessToken(await decryptSecret(env, cloud.refreshTokenEnc));
      accessToken = refreshedTokens.accessToken;
    }
    usage = await fetchUsage(accessToken);
  } catch (err) {
    if (err instanceof GrantRevokedError) {
      // The user revoked the grant from their Anthropic account. Stop polling
      // rather than hammering a dead credential every five minutes.
      console.log(`cloud grant revoked for ${deviceId}; disabling`);
      await deleteCloud(env, deviceId);
      return 'skipped';
    }
    if (err instanceof RateLimitedError) {
      await parkForBackoff(env, deviceId, cloud, err.retryAfter);
      return 'skipped';
    }
    throw err;
  }

  // A poll got through, so any earlier rate limiting has cleared. Only write if
  // there's actually something to clear.
  if (cloud.rateLimitStrikes) {
    cloud = { ...cloud, rateLimitStrikes: 0, backoffUntil: 0 };
    await putCloud(env, deviceId, cloud);
  }

  const previous = cloud.lastPush;
  const state = buildContentState(usage, previous);
  const level = usageLevel(state.sessionUtilization);

  // A sharp collapse means the 5-hour window rolled over.
  const didReset = previous && previous.sessionUtilization > 30 && state.sessionUtilization < 10;
  // Whether an activity is running is a fact about the device, not about our
  // own push history — the phone may have started one locally.
  const hasActivity = Boolean(record.liveActivityToken);
  const decision = didReset ? 'end' : pushDecision(state, previous, hasActivity);
  if (!decision) return 'polled';

  let alert = null;
  if (!didReset && isAlarming(level) && level !== cloud.alertedLevel) {
    alert = {
      title: `Session usage ${level}`,
      body: `You're at ${Math.round(state.sessionUtilization)}% of your 5-hour limit.`,
    };
  }

  const token = decision === 'start' ? record.pushToStartToken : record.liveActivityToken;
  // No token means either iOS < 17.2, or the phone deliberately withheld its
  // push-to-start token because the user has Live Activities off. Both are a
  // "stay quiet", not an error.
  if (!token) return 'polled';

  const result = await deliver(env, {
    record, deviceId, token,
    payload: activityPayload(env, {
      event: decision,
      contentState: didReset ? { ...state, didReset: true } : state,
      staleAfter: didReset ? 0 : CLOUD_STALE_AFTER,
      relevanceScore: state.sessionUtilization,
      dismissAfter: 30,
      attributes: { planTier: cloud.planTier || '', accountName: cloud.accountName || 'Account' },
      alert,
    }),
    pushType: 'liveactivity',
    topic: `${env.BUNDLE_ID}.push-type.liveactivity`,
    priority: 10,
  });

  // Wake the app so the Home Screen widgets follow the Lock Screen.
  await deliverWidgetReload(env, deviceId, record);

  // One KV write per push, not per tick — the write budget is the tight one.
  await putCloud(env, deviceId, {
    ...cloud,
    ...(refreshedTokens ? {
      refreshTokenEnc: await encryptSecret(env, refreshedTokens.refreshToken),
      accessToken: refreshedTokens.accessToken,
      accessExpiresAt: refreshedTokens.expiresAt,
    } : {}),
    lastPush: didReset ? null : { ...state, pushedAt: nowSeconds() },
    alertedLevel: alert ? level : (isAlarming(level) ? cloud.alertedLevel : null),
    lastResult: result.ok ? 'ok' : `${result.status}:${result.reason}`,
  });

  return 'polled';
}

/**
 * Park a rate-limited device so it stops making upstream requests.
 *
 * Worth one KV write: it buys back many requests, which is the budget under
 * pressure when a 429 shows up. Anthropic's `Retry-After` wins if present;
 * otherwise back off exponentially like the Mac's `UsagePollingService` does.
 */
async function parkForBackoff(env, deviceId, cloud, retryAfter) {
  const strikes = (cloud.rateLimitStrikes || 0) + 1;
  const backoff = retryAfter
    ?? Math.min(BACKOFF_BASE_SECONDS * 2 ** (strikes - 1), BACKOFF_MAX_SECONDS);
  console.log(`rate limited for ${deviceId}; backing off ${backoff}s (strike ${strikes})`);
  await putCloud(env, deviceId, {
    ...cloud,
    rateLimitStrikes: strikes,
    backoffUntil: nowSeconds() + backoff,
  });
}

/**
 * Returns the event to send, or null to stay quiet.
 *
 * Live Activities have a system update budget even with
 * NSSupportsLiveActivitiesFrequentUpdates declared, so the rule is: push when
 * the number a user is looking at would actually change, and otherwise only
 * often enough to stay un-dimmed.
 */
function pushDecision(state, previous, hasActivity) {
  if (!hasActivity) {
    // Nothing on the Lock Screen. Only raise a card for a session worth
    // watching — the same threshold the phone applies locally.
    return state.isSessionActive || state.sessionUtilization >= START_THRESHOLD ? 'start' : null;
  }
  // An activity exists but we've never pushed to it (the phone started it, or
  // cloud sync was just enabled) — take it over now rather than waiting for the
  // first 1% move.
  if (!previous) return 'update';

  const elapsed = nowSeconds() - (previous.pushedAt || 0);
  if (elapsed >= CLOUD_HEARTBEAT) return 'update';
  if (Math.abs(state.sessionUtilization - previous.sessionUtilization) >= CLOUD_MIN_DELTA) return 'update';
  if (usageLevel(state.sessionUtilization) !== usageLevel(previous.sessionUtilization)) return 'update';
  return null;
}

// ───────────────────────────────────────────────────────────── utils ──

async function readJSON(request) {
  const declared = Number(request.headers.get('content-length') || 0);
  if (declared > MAX_BODY_BYTES) return null;
  try {
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return null;
    const parsed = JSON.parse(text);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch {
    return null;
  }
}
