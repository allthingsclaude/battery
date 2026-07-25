/**
 * KV access. Two key spaces:
 *
 *   dev:<deviceId>    push tokens + secret hashes (written on registration and
 *                     pairing only — never on a push)
 *   cloud:<deviceId>  opt-in cloud-sync state: the encrypted refresh token and
 *                     just enough last-pushed state to change-gate the cron
 *   code:<code>       short-lived pairing codes
 *
 * The write budget shapes this: Cloudflare's free tier allows ~100× more KV
 * reads than writes, so anything on a hot path must be read-only.
 */

import { nowSeconds } from './util.js';

/** Drop device records untouched for this long, to keep the namespace tidy. */
const DEVICE_TTL_SECONDS = 60 * 60 * 24 * 60; // 60 days

export const PAIR_CODE_TTL_SECONDS = 60 * 10;

export async function getDevice(env, deviceId) {
  return env.DEVICES.get(`dev:${deviceId}`, { type: 'json' });
}

export async function putDevice(env, deviceId, record) {
  record.updatedAt = nowSeconds();
  await env.DEVICES.put(`dev:${deviceId}`, JSON.stringify(record), {
    expirationTtl: DEVICE_TTL_SECONDS,
  });
}

export async function deleteDevice(env, deviceId) {
  await env.DEVICES.delete(`dev:${deviceId}`);
  await env.DEVICES.delete(`cloud:${deviceId}`);
}

export async function getCloud(env, deviceId) {
  return env.DEVICES.get(`cloud:${deviceId}`, { type: 'json' });
}

export async function putCloud(env, deviceId, record) {
  record.updatedAt = nowSeconds();
  await env.DEVICES.put(`cloud:${deviceId}`, JSON.stringify(record), {
    expirationTtl: DEVICE_TTL_SECONDS,
  });
}

export async function deleteCloud(env, deviceId) {
  await env.DEVICES.delete(`cloud:${deviceId}`);
}

/** Every device that opted into cloud polling, for the cron to walk. */
export async function listCloudDeviceIds(env) {
  const ids = [];
  let cursor;
  do {
    const page = await env.DEVICES.list({ prefix: 'cloud:', cursor });
    for (const key of page.keys) ids.push(key.name.slice('cloud:'.length));
    cursor = page.list_complete ? null : page.cursor;
  } while (cursor);
  return ids;
}

/** Pairing codes are short enough to collide; retry a few times before failing. */
export async function mintUnusedCode(env) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const buf = new Uint32Array(1);
    crypto.getRandomValues(buf);
    const code = String(buf[0] % 1_000_000).padStart(6, '0');
    if (!(await env.DEVICES.get(`code:${code}`))) return code;
  }
  return null;
}

export async function putCode(env, code, deviceId) {
  await env.DEVICES.put(`code:${code}`, deviceId, { expirationTtl: PAIR_CODE_TTL_SECONDS });
}

export async function takeCode(env, code) {
  const deviceId = await env.DEVICES.get(`code:${code}`);
  if (deviceId) await env.DEVICES.delete(`code:${code}`);
  return deviceId;
}
