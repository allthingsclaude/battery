/** Small shared primitives: encoding, hashing, and secret-at-rest encryption. */

export const utf8 = (str) => new TextEncoder().encode(str);

export const nowSeconds = () => Math.floor(Date.now() / 1000);

export function b64url(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromB64url(text) {
  const padded = text.replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

export async function sha256(value) {
  return b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', utf8(value))));
}

export function randomToken(bytes) {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return b64url(buf);
}

// ─────────────────────────────────────────────── secrets at rest ──
//
// Cloud-sync refresh tokens are the only real credential this service ever
// holds, so they're encrypted with a key that lives in a Worker secret rather
// than in KV. Reading the KV namespace is then not enough on its own — an
// attacker needs the secret too.

async function encryptionKey(env) {
  if (!env.CLOUD_KEY) throw new Error('CLOUD_KEY secret is not set');
  // Stretch whatever string was provided into exactly 32 bytes.
  const material = await crypto.subtle.digest('SHA-256', utf8(env.CLOUD_KEY));
  return crypto.subtle.importKey('raw', material, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

export async function encryptSecret(env, plaintext) {
  const key = await encryptionKey(env);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, utf8(plaintext));
  return `${b64url(iv)}.${b64url(new Uint8Array(ciphertext))}`;
}

export async function decryptSecret(env, blob) {
  const [rawIv, rawCiphertext] = String(blob).split('.');
  if (!rawIv || !rawCiphertext) throw new Error('malformed encrypted secret');
  const key = await encryptionKey(env);
  const plaintext = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: fromB64url(rawIv) }, key, fromB64url(rawCiphertext),
  );
  return new TextDecoder().decode(plaintext);
}

// ─────────────────────────────────────────────────── validation ──

/** Device ids are client-generated UUIDs. */
export function asId(value) {
  return typeof value === 'string' && /^[0-9A-Fa-f-]{36}$/.test(value) ? value.toUpperCase() : null;
}

export function asSecret(value) {
  return typeof value === 'string' && value.length >= 16 && value.length <= 128 ? value : null;
}

export function asHexToken(value) {
  return typeof value === 'string' && /^[0-9a-fA-F]{32,256}$/.test(value) ? value.toLowerCase() : null;
}

export function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}
