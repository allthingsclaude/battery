# Battery push relay

A small Cloudflare Worker that keeps the iPhone's Live Activity current while
the iOS app is suspended. **You deploy your own** — see [Why one Worker per
person](#why-one-worker-per-person) below; it isn't a shared service, and can't
be.

## Why this exists

iOS suspends the Battery iPhone app within seconds of you leaving it. A Live
Activity started there freezes at whatever number it last saw, and
`BGAppRefreshTask` is granted at the OS's discretion — often many minutes apart.
The only way to move a Live Activity on a suspended app is an APNs push, and
APNs pushes need a server.

## Two paths to the same Lock Screen card

**Relay (default).** The Mac app already polls the usage API every 60 seconds
with your credentials, so it does the work and the Worker just forwards it.

```
Mac app  ──POST /v1/push──▶  Worker  ──signed JWT──▶  APNs  ──▶  iPhone
(polls Anthropic,            (APNs key +
 owns the tokens)             push tokens only)
```

**Cloud (opt-in).** For when no Mac of yours is awake — coding from claude.ai,
or from a machine that isn't running Battery. A cron tick polls and pushes:

```
cron ──▶ Worker ──▶ Anthropic  ──▶  APNs  ──▶  iPhone
         (holds a narrow, separate
          OAuth grant, encrypted)
```

**The Mac wins when it's awake.** It polls the user's own tokens from their own
machine, every 60 seconds rather than every 5 minutes, and costs this service no
upstream requests at all — so each Mac push claims the card for 12 minutes and
the cron stands aside. Cloud polling covers the gaps, not the whole time.

## Why one Worker per person

An **APNs auth key is scoped to an Apple Developer Team**, and the push topic is
the app's bundle ID — which is namespaced per team in the developer portal. A
key belonging to one team cannot push to an app signed by another, even with an
identical bundle ID.

The iOS app isn't on the App Store; you build it in Xcode under your own team.
So your build can only be reached by a Worker holding *your* APNs key, which
means your own deployment. That's not a limitation to work around — it's the
better arrangement:

- Your `user:profile` token sits in **your** Cloudflare account, not someone
  else's.
- Your usage requests reach Anthropic from your own Worker on your own token,
  the same shape of traffic the Mac app already produces.
- Every free-tier limit below is yours alone, with orders of magnitude of
  headroom for one person.

## What it holds

**Always:** an APNs auth key (a Cloudflare secret), per-device push tokens, and
SHA-256 hashes of the two shared secrets. Secrets are stored hashed so a dump of
the KV namespace can't be replayed, and push tokens on their own are inert —
only meaningful to APNs alongside the auth key.

**Only with cloud sync enabled:** one Claude refresh token, AES-GCM-encrypted
under a separate Worker secret so KV access alone isn't enough to read it.

That token is deliberately narrow. The apps normally request
`user:profile user:inference`; cloud sync runs a **separate** sign-in asking for
`user:profile` **only** — verified against the live API to read
`/api/oauth/usage` in full while carrying no inference rights, so it **cannot
make calls billed to the account**. Being a separate grant also means you can
revoke it from your Claude settings without signing out of the app, and the two
holders never fight over a rotated refresh token.

**Never:** the account's own tokens. Those stay in the phone's Keychain.

## Cost

Free, comfortably, for a single person — and the budget that actually needs
watching is **Anthropic's**, not Cloudflare's.

Both paths are change-gated: a push only goes out when the number a user would
see actually moves (≥1 percentage point, a level crossing, or a heartbeat).
Cloud polling adds two more gates, because polling an account whose card isn't
on screen is pure waste:

| Device state | Polled |
|---|---|
| No push tokens at all (Live Activities off) | never |
| A paired Mac pushed in the last 12 min | never — it already did the work |
| No card on screen | 1 tick in 3 (~15 min), staggered by device id |
| Live Activity running, no Mac | every tick (5 min) |

The Mac's claim is renewed lazily (once per ~6 minutes of continuous pushing,
not once per push), so keeping the cron quiet costs far fewer KV writes than the
cloud pushes it replaces.

In practice a card is up a few hours a day, so that's ~50 usage requests/day —
about **a tenth** of what the Mac app already generates polling every 60 seconds.
A 429 parks the device with exponential backoff (honouring `Retry-After`) and it
makes no upstream requests at all until the window expires.

Cloudflare-side, per person: a handful of KV writes and a few hundred requests a
day against free-tier ceilings of 1,000 and 100,000.

<details>
<summary>If this ever became a shared, multi-user deployment</summary>

It would need real work — this design is single-tenant on purpose:

- **KV writes (1,000/day free)** bind first. Cloud polling writes once per push,
  ~60–100/user/day, so the ceiling is ~10 concurrent cloud users. Moving the
  `cloud:` records to D1 raises that to 100,000/day.
- **External subrequests are capped at 50 per invocation** on the free plan
  (1,000 on paid), so one cron tick can service ~25 users no matter the storage.
  Getting past that needs fan-out via service bindings, which count against the
  separate 1,000 Cloudflare-services budget.
- **Concentration at Anthropic** is the part money doesn't fix: every user's
  polling would arrive from one origin instead of from their own machine.

With the polling gate above, D1, and service-binding fan-out, ~1,000 cloud users
fits in the free tier with the tightest margin on D1 writes and the 10 ms CPU
limit. That refactor is contained to `store.js` and `runCloudPoll`, and is not
worth doing before an App Store build makes a shared deployment possible.
</details>

## Deploy

You need an Apple Developer account for the APNs key, and any Cloudflare account.

**1. Create an APNs auth key.** In the [Apple Developer portal](https://developer.apple.com/account/resources/authkeys/list),
Keys ▸ ➕, enable **Apple Push Notifications service (APNs)**, and download the
`.p8`. Apple lets you download it exactly once. Note the **Key ID** shown next
to it, and your **Team ID** from the Membership page.

**2. Create the KV namespace.**

```bash
cd worker
npm install -g wrangler        # once
wrangler kv namespace create DEVICES
```

Paste the returned `id` into `wrangler.toml`.

**3. Fill in `wrangler.toml`** — `APNS_KEY_ID`, `APNS_TEAM_ID`, and `BUNDLE_ID`
(must match `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml`).

**4. Upload the two secrets** — never commit these:

```bash
wrangler secret put APNS_KEY < AuthKey_XXXXXXXXXX.p8
openssl rand -base64 48 | wrangler secret put CLOUD_KEY   # encrypts cloud-sync tokens
```

Rotating `CLOUD_KEY` invalidates every stored cloud-sync token — each phone just
has to turn Cloud Updates on again.

**5. Deploy.**

```bash
wrangler deploy
curl https://battery-push.<your-subdomain>.workers.dev/v1/health
```

**6. Point both apps at your Worker.**

- iOS: `AppConfig.defaultPushRelayURL` in `ios/BatteryApp/AppConfig.swift`
- macOS: `Constants.pushRelayURL` in `Sources/Utilities/Constants.swift`

Set either to an empty string to build without the relay — every call becomes a
no-op and both apps behave exactly as they did before it existed.

## Pair a phone

1. iPhone ▸ Settings ▸ **Live Updates** ▸ *Pair with Mac* — shows a 6-digit code.
2. Mac ▸ Settings ▸ **iPhone** — type the code, hit *Pair*.

The code is single-use and expires in 10 minutes. Redeeming it mints a push key
for the Mac; the phone's own secret is never handed over, so a compromised Mac
can push to the activity but can't re-register tokens, enable cloud sync, or
impersonate the device.

## Turn on cloud updates (optional)

iPhone ▸ Settings ▸ **Cloud Updates** ▸ *Set Up Cloud Updates*. This opens a
second Claude sign-in requesting `user:profile` only. The resulting refresh
token goes to the relay; nothing else changes.

To undo it: turn it off in the app (deletes the stored token), then revoke the
grant in your Claude account settings. The app's own sign-in is untouched.

## Test

```bash
npm test
```

Runs the real handler against an in-memory KV and stubbed APNs/Anthropic,
covering the pairing handshake, the environment fallback, push-to-start, cloud
enable/disable, the polling gate, rate-limit backoff, refresh-token rotation,
and — the one worth having — an independent WebCrypto verification of the ES256
provider JWT. A malformed JWT is otherwise invisible until Apple rejects it in
production with an opaque 403.

## API

All routes are `POST` with JSON except health. Errors return `{"error": "..."}`.

| Route | Caller | Purpose |
|---|---|---|
| `GET /v1/health` | anyone | liveness + configured bundle id |
| `/v1/device` | iPhone | register/update push tokens (`null` clears one) |
| `/v1/pair` | iPhone | mint a 6-digit pairing code |
| `/v1/pair/claim` | Mac | redeem a code for a push key |
| `/v1/push` | Mac | forward a `content-state` to APNs |
| `/v1/cloud` | iPhone | enable/disable cloud polling (needs the device secret, not the Mac's push key — handing over a Claude grant is the phone owner's decision) |
| `/v1/unpair` | either | revoke the Mac's push key |

Plus a cron-triggered `scheduled()` handler that walks every `cloud:` record.

### Notes for anyone modifying this

- **`content-state` field names must match `UsageActivityAttributes.ContentState`**
  in `ios/BatteryKit/UsageActivityAttributes.swift`, and dates are **Unix epoch
  seconds**. That type has a hand-written `Codable` for exactly this reason —
  Swift's synthesised one encodes `Date` relative to 2001, a silent 31-year
  offset for JSON written anywhere but Swift.
- **`ATTRIBUTES_TYPE` must equal the Swift type name.** ActivityKit silently
  discards a push-to-start payload whose `attributes-type` doesn't match.
- **`CRON_INTERVAL_SECONDS` must match the cron expression** in `wrangler.toml`;
  the staggered discovery cadence derives tick numbers from it.
- **Don't add per-push KV writes on the relay path.** The free tier allows 100×
  more reads than writes; change-gating belongs on the Mac, which knows the
  previous value.
- **Live Activity updates have a system budget** even with
  `NSSupportsLiveActivitiesFrequentUpdates` declared. Pushing on every poll
  regardless of change is the fastest way to get throttled by iOS.
