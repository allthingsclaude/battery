/**
 * The cloud-polling half: talk to Anthropic on a user's behalf.
 *
 * Only reached for devices that explicitly opted in. The grant used here is a
 * **separate** OAuth grant scoped to `user:profile` alone — verified to read
 * /api/oauth/usage while carrying no `user:inference`, so this credential
 * cannot make calls billed to the account. It is also independent of the
 * phone's own grant, which means revoking cloud sync doesn't sign anyone out,
 * and the two holders never fight over a rotated refresh token.
 */

const TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const SCOPES = 'user:profile';
const BETA_HEADER = 'oauth-2025-04-20';
const USER_AGENT = 'Battery-Relay/0.1.0';

/** Thrown when the grant is gone for good and polling should stop. */
export class GrantRevokedError extends Error {}

/** Thrown on a 429 so the caller can park this device instead of retrying. */
export class RateLimitedError extends Error {
  constructor(retryAfter) {
    super('rate limited');
    /** Seconds Anthropic asked us to wait, or null if it didn't say. */
    this.retryAfter = retryAfter;
  }
}

function rateLimitedFrom(res) {
  const header = res.headers.get('retry-after');
  const seconds = header ? Number(header) : NaN;
  return new RateLimitedError(Number.isFinite(seconds) && seconds > 0 ? seconds : null);
}

export async function refreshAccessToken(refreshToken) {
  // RFC 6749 §6 makes `scope` optional on a refresh, meaning "whatever was
  // originally granted". Sending it explicitly is what the macOS app does and
  // is the proven path, but a server that's fussy about the narrowed scope
  // would reject it — so fall back to omitting it before concluding the grant
  // is dead. Getting this wrong looks identical to a revoked token.
  let res = await postTokenRequest(refreshToken, SCOPES);
  if (res.status === 400) {
    const retry = await postTokenRequest(refreshToken, null);
    if (retry.ok) res = retry;
  }

  if (res.status === 429) throw rateLimitedFrom(res);
  if (res.status === 400 || res.status === 401) {
    // The user revoked the grant (or it expired). Anything else — 5xx, a
    // network blip — is transient and should be retried on the next tick.
    throw new GrantRevokedError(`token refresh rejected with ${res.status}`);
  }
  if (!res.ok) throw new Error(`token refresh failed with ${res.status}`);

  const body = await res.json();
  return {
    accessToken: body.access_token,
    // The endpoint may rotate the refresh token; persist the new one or the
    // next refresh fails.
    refreshToken: body.refresh_token || refreshToken,
    expiresAt: Math.floor(Date.now() / 1000) + (body.expires_in || 3600),
  };
}

function postTokenRequest(refreshToken, scope) {
  const body = { grant_type: 'refresh_token', refresh_token: refreshToken, client_id: CLIENT_ID };
  if (scope) body.scope = scope;
  return fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'user-agent': USER_AGENT },
    body: JSON.stringify(body),
  });
}

export async function fetchUsage(accessToken) {
  const res = await fetch(USAGE_URL, {
    headers: {
      authorization: `Bearer ${accessToken}`,
      'anthropic-beta': BETA_HEADER,
      'user-agent': USER_AGENT,
    },
  });
  if (res.status === 429) throw rateLimitedFrom(res);
  if (res.status === 401) throw new GrantRevokedError('usage rejected the access token');
  if (!res.ok) throw new Error(`usage fetch failed with ${res.status}`);
  return res.json();
}

const epoch = (iso) => {
  if (!iso) return null;
  const parsed = Date.parse(iso);
  return Number.isNaN(parsed) ? null : Math.floor(parsed / 1000);
};

/**
 * The five-hour window from a usage response: `five_hour`, or the `limits`
 * array's `session` entry. Null when the account has no session limit at all —
 * verified Ultra accounts are metered weekly only, and the API answers for
 * them with `"five_hour": null`.
 */
function sessionWindow(usage) {
  if (usage.five_hour) return usage.five_hour;
  const entry = Array.isArray(usage.limits) ? usage.limits.find((l) => l && l.kind === 'session') : null;
  return entry ? { utilization: entry.percent, resets_at: entry.resets_at } : null;
}

/** Whether this usage response meters the account by a five-hour window. */
export function usageHasSessionLimit(usage) {
  return Boolean(sessionWindow(usage));
}

/**
 * The utilization the card tracks: the session's, or the weekly window's for
 * an account with no session limit. A state without `hasSessionLimit` predates
 * weekly-only plans and had a session window.
 */
export function primaryUtilization(state) {
  return state.hasSessionLimit === false ? state.weeklyUtilization : state.sessionUtilization;
}

/** Whether two states track the same window and so can be compared. */
export function sameMetering(a, b) {
  return (a.hasSessionLimit !== false) === (b.hasSessionLimit !== false);
}

/**
 * Map a usage response into `UsageActivityAttributes.ContentState`.
 *
 * Field names and Unix-epoch dates must match the Swift type in
 * ios/BatteryKit/UsageActivityAttributes.swift.
 *
 * `previous` is the last state we pushed, used for a two-point burn rate. The
 * Mac computes this from a proper regression over a snapshot buffer; up here
 * there's no history to regress over, so this is deliberately the cruder
 * estimate — enough for "hits limit in ~2h", not a forecast.
 *
 * For an account with no session limit the burn rate and projection describe
 * the weekly window instead, the session fields are 0 / absent, and
 * `hasSessionLimit` says so.
 */
export function buildContentState(usage, previous) {
  const session = sessionWindow(usage);
  const hasSessionLimit = Boolean(session);
  const sessionUtilization = session ? Number(session.utilization) || 0 : 0;
  const sessionResetsAt = session ? epoch(session.resets_at) : null;
  const weeklyUtilization = Number(usage.seven_day?.utilization) || 0;
  const weeklyResetsAt = epoch(usage.seven_day?.resets_at);
  const utilization = hasSessionLimit ? sessionUtilization : weeklyUtilization;
  const resetsAt = hasSessionLimit ? sessionResetsAt : weeklyResetsAt;
  const nowSec = Math.floor(Date.now() / 1000);

  let burnRatePerHour = 0;
  let projectedLimitAt = null;
  // A sample from the other window (Ultra verification landed or lapsed in
  // between) says nothing about this one's rate.
  const comparable = previous && sameMetering(previous, { hasSessionLimit });
  if (comparable && previous.updatedAt && primaryUtilization(previous) != null) {
    const elapsedHours = (nowSec - previous.updatedAt) / 3600;
    // Ignore samples too close together (noise) or too far apart (the window
    // probably rolled over in between).
    if (elapsedHours > 0.02 && elapsedHours < 2) {
      const delta = utilization - primaryUtilization(previous);
      if (delta > 0) {
        burnRatePerHour = delta / elapsedHours;
        const remaining = 100 - utilization;
        if (burnRatePerHour > 0.05 && remaining > 0) {
          projectedLimitAt = nowSec + Math.round((remaining / burnRatePerHour) * 3600);
        }
      }
    }
  }

  // Don't project past the reset — the window empties before the limit lands.
  if (projectedLimitAt && resetsAt && projectedLimitAt > resetsAt) {
    projectedLimitAt = null;
    burnRatePerHour = burnRatePerHour > 0 ? burnRatePerHour : 0;
  }

  const state = {
    sessionUtilization,
    weeklyUtilization,
    burnRatePerHour,
    // The API exposes no "is a session running" flag, so infer it the same way
    // the phone does when it has no hook data: usage is moving.
    isSessionActive: burnRatePerHour > 0.05,
    hasSessionLimit,
    didReset: false,
    updatedAt: nowSec,
  };
  if (sessionResetsAt) state.sessionResetsAt = sessionResetsAt;
  if (weeklyResetsAt) state.weeklyResetsAt = weeklyResetsAt;
  if (projectedLimitAt) state.projectedLimitAt = projectedLimitAt;
  return state;
}

/** 0–100 → the same four bands both apps use. */
export function usageLevel(utilization) {
  if (utilization >= 90) return 'critical';
  if (utilization >= 75) return 'high';
  if (utilization >= 50) return 'moderate';
  return 'low';
}

export const isAlarming = (level) => level === 'high' || level === 'critical';
