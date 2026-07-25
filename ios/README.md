# Battery for iOS — Widgets & Smart Live Activity

A standalone iOS companion to the macOS menu-bar app. It signs in with the **same
Claude OAuth flow**, polls the same `/api/oauth/usage` endpoint, and surfaces your
5-hour session and 7-day weekly limits as:

- **Home Screen widgets** — small (focus ring) and medium (session + weekly + Opus, with burn-rate footer)
- **Lock Screen / StandBy accessories** — circular gauge, rectangular, and inline
- **A Lock Screen Live Activity** that appears *only while a session is worth watching*, escalates as you approach the limit, and dismisses itself when the window resets or goes idle

No server, no Mac dependency — the phone is a self-contained poller, exactly like
the desktop app.

> **Why isn't this in `Package.swift`?** WidgetKit and ActivityKit ship as **app
> extensions**, which need an Xcode project with codesigned `.appex` targets —
> `swift build` can't produce them. The code here is written to drop straight into
> an Xcode project; see [Xcode setup](#xcode-setup). The existing macOS SwiftPM
> build is untouched.

---

## Architecture

The design rule is **the app computes, the surfaces present**. The app process is
the only thing that touches the network, the token refresh, and the burn-rate
regression. It bakes everything into one `UsagePayload` and writes it to a shared
App Group container. Widgets and the Live Activity are pure, cheap presentation.

```
                    ┌───────────────────────── iOS APP PROCESS ─────────────────────────┐
                    │                                                                    │
   Claude OAuth ───▶│  AuthService ──▶ TokenStore (Keychain)                             │
                    │                       │                                            │
   /oauth/usage ◀───┼── UsageAPI ◀──────────┘                                            │
                    │      │                                                             │
                    │      ▼                                                             │
                    │  UsageService                                                      │
                    │   • ring buffer → BurnRateCalculator (projection)                  │
                    │   • infer "session active"                                         │
                    │   • build UsagePayload ─────────────┬──────────────┐              │
                    │                                     │              │              │
                    │              LiveActivityController.sync(payload)  │              │
                    │                     │ (start/update/escalate/end)  │              │
                    └─────────────────────┼──────────────────────────────┼──────────────┘
                                          │                              │
                                          ▼                              ▼
                                   ActivityKit                    SharedStore (App Group)
                                   Live Activity                  UserDefaults(suiteName:)
                                          │                              │
                                          │           WidgetCenter.reloadAllTimelines()
                                          ▼                              ▼
                              ┌───────── WIDGET EXTENSION PROCESS ──────────┐
                              │  UsageProvider reads SharedStore.load()      │
                              │  SessionWidget · LockScreenWidget            │
                              │  UsageLiveActivity (Dynamic Island + card)   │
                              └─────────────────────────────────────────────┘
```

`UsagePayload` (in `BatteryKit/UsagePayload.swift`) is the entire contract between
the two processes. `UsageActivityAttributes` is the contract between the app and
the Live Activity UI.

---

## The "shown smartly when needed" state machine

All of this runs on-device in `LiveActivityController.sync(with:)`, fed one
`UsagePayload` after every poll. Thresholds mirror the macOS `NotificationService`
so the phone and Mac agree on what "worth surfacing" means.

| Transition | Condition | Result |
|---|---|---|
| **Start** | no activity running **and** (`isSessionActive` **or** session ≥ 40%) | request a Live Activity |
| **Update** | activity running, new payload | push ring / % / live countdown |
| **Escalate** | utilization crosses into **High** (75%) or **Critical** (90%) | one *alerting* update (banner + sound), once per level |
| **End: reset** | utilization collapses (was > 30%, now < 10%) | show a brief "Session reset" card, auto-dismiss ~30s |
| **End: idle** | not active **and** < 25% for 10 min straight | end quietly |
| **End: expired** | past the session `resetsAt` time | end quietly |

Two details that make it feel alive even between refreshes:

- **Live countdown** — the card and Dynamic Island render the reset with
  `Text(resetsAt, style: .relative)`, so "resets in 2 hr, 13 min" keeps counting
  down on the Lock Screen with zero pushes. (`.relative` rather than `.timer`:
  the colon format is wider, wraps, and ghosts in the fixed-width digit slots.)
- **Staleness** — each update sets a `staleDate`; if nothing refreshes it in
  time, the system dims the activity instead of lying about the number.

---

## Keeping it current: the push relay

iOS suspends this app within seconds of you leaving it, and `BGAppRefreshTask`
runs at the system's discretion — often many minutes apart. A Live Activity is
only moved by an APNs push, and APNs pushes need a server.

The Mac app is already polling every 60 seconds with the user's own credentials,
so it does the work and a **~400-line Cloudflare Worker** (`worker/`) forwards
the result. The relay **never receives a Claude credential** — that split is what
makes it reasonable to run as a shared service for an open-source app.

```
   Mac app ──POST /v1/push──▶ Worker ──signed ES256 JWT──▶ APNs ──▶ iPhone
   (polls Anthropic,          (APNs key +                        Live Activity
    owns the tokens,           push tokens only)                 + widget reload
    gates on change)
```

| Piece | Where |
|---|---|
| Device identity + token upload | `BatteryApp/PushRelayClient.swift` |
| APNs registration, silent-push handling, push-to-start token | `BatteryApp/AppDelegate.swift` |
| `pushType: .token`, `pushTokenUpdates` observer | `BatteryApp/LiveActivityController.swift` |
| Cloud sync opt-in (narrow separate grant) | `BatteryApp/SettingsView.swift`, `PushRelayClient.enableCloudSync` |
| Polling, change-gating, pairing (Mac) | `../Sources/Services/PushRelayService.swift` |
| The relay itself | `../worker/` |

Design notes worth knowing before changing any of it:

- **Change-gating lives on the Mac**, not the Worker: only push when the number
  a user would see actually moves (≥1 point, a level crossing, or a 5-minute
  heartbeat), never more than once a minute. Live Activities have a system update
  budget even with `NSSupportsLiveActivitiesFrequentUpdates` declared.
- **The phone stays the authority on user preference.** The Mac has no idea what
  the Live Activity mode is set to, so "Off" is enforced by *withholding the
  push-to-start token* — no token, no remote start. Policy can't drift.
- **One owner for escalation banners.** While paired, the Mac sends the
  High/Critical alert and `LiveActivityController` stands down, so a foreground
  phone and an awake Mac can't double-alert.
- **Widgets ride along.** ActivityKit pushes can't touch the Home Screen — those
  read the App Group snapshot only this process can write. So each push also asks
  the relay for a silent `content-available` push, which wakes the app just long
  enough to poll once and reload the timelines.
- **`ContentState` has a hand-written `Codable`.** Its dates are Unix epoch
  seconds because the Worker writes that JSON too; Swift's synthesised version
  encodes `Date` relative to 2001, a silent 31-year offset off-platform.

**You deploy your own Worker.** An APNs auth key is scoped to an Apple Developer
Team and the push topic is the bundle ID, so a key from one team can't reach an
app signed by another — and you build this app under your own team. Setup is in
[`worker/README.md`](../worker/README.md). Both apps hold the relay URL in one
constant each (`AppConfig.defaultPushRelayURL`, `Constants.pushRelayURL`) — blank
it out and every relay call becomes a no-op, leaving the app exactly as it
behaved before.

### When no Mac of yours is awake

The relay above covers the common case, because the 5-hour session is usually
being consumed *by Claude Code on the paired Mac* — asleep means the numbers
aren't moving either. The exception is real though: coding from claude.ai, or
from a machine that isn't running Battery.

**Cloud Updates** (iPhone ▸ Settings, opt-in) closes it. The relay polls
Anthropic on a 5-minute cron and pushes, so the Lock Screen stays live with every
Mac of yours switched off.

The credential this needs is deliberately the narrowest one that works:

- A **separate sign-in** requesting `user:profile` **only**, not the account's
  own tokens. Verified against the live API: that scope reads
  `/api/oauth/usage` in full, and the token server honours the narrowing rather
  than silently widening it.
- It carries **no `user:inference`**, so the stored credential cannot make calls
  billed to the account. That's the property that makes storing it defensible at
  all — see `AppConfig.cloudSyncScopes`.
- Being a separate grant, it's independently revocable (turning it off doesn't
  sign you out), and the relay and the phone never fight over a rotated refresh
  token — which they would if they shared one.
- Encrypted at rest under a Worker secret, so KV access alone can't read it.

The Mac stays primary whenever it's awake — it's both faster (60s vs 5 min) and
free, since it polls on the user's own tokens from their own machine. Each Mac
push claims the card for 12 minutes and the cron skips that device entirely;
cloud polling fills the gaps rather than duplicating the work.

It also polls as little as it can get away with, because the budget that matters
here is Anthropic's rate limit, not Cloudflare's bill. A device with no Live
Activity running has nothing to update, so it's polled at a third of the cadence
(staggered by device id, no stored state); a device with no push tokens at all —
which is how "Live Activities: Off" reaches the relay — is never polled. A 429
parks it with exponential backoff honouring `Retry-After`. Net effect: roughly a
tenth of the requests the Mac app already makes polling every 60 seconds.

Color escalates through `UsageLevel` **within the terracotta family** — brand
(`#D97757`) → dark (`#B85A3A`) → deep (`#9A4A2C`) — so a hot session reads at a
glance without leaving the brand. See "Design system" below.

---

## Design system — one product, two platforms

The iOS surfaces are built to read as the **same product** as the menu-bar app,
not a lookalike. The shared look lives in three `BatteryKit` files so the app,
widgets, and Live Activity can never drift:

- **`BatteryColors.swift`** — the terracotta palette copied verbatim from the
  desktop (`#D97757` → `brandDark #B85A3A` → `brandDeep #9A4A2C`), plus adaptive
  `surface` / `elevated` / `hairline` colors matching the desktop's `#FAF8F4` /
  `#191814` backgrounds in light **and** dark.
- **`UsageRing.swift`** — one canonical ring, a faithful port of the desktop
  `GaugeRingView`: `.quaternary` track, round-capped arc rotated to 12 o'clock,
  `easeInOut(0.5)` fill, SF Rounded **monospaced** center numeral tinted by level.
  A `gradientStroke` variant adds a two-stop brand gradient + soft glow for hero
  surfaces; a `tinted` variant handles the monochrome Lock Screen slots.
- **`BatteryDesign.swift`** — the shared chrome: elevated `batteryCard()` surface
  (continuous 22pt corners, hairline border, soft shadow), `BatteryProgressBar`
  (ports `ProgressBarView`), `LiveCountdown` (ports the desktop's 1-second
  `CountdownLabel`), a pulsing `ActiveDot`, and `SectionLabel`.

Deliberate on-brand choices:

- **Monochrome terracotta ramp.** Like the desktop *default* theme, severity
  escalates by **darkening within the brand**, never by turning red. (Multi-color
  is the opt-in "classic" theme on desktop; we ship the branded default.)
- **SF Rounded + `monospacedDigit()`** for every number, so figures don't jitter
  as they tick — same as the menu bar.
- **Glass & materials** — `.ultraThinMaterial` pills and elevated cards echo the
  desktop panel's vibrancy; the Live Activity uses a dark brand-tinted background.
- **Live, not polled-looking** — countdowns tick every second (app) or via
  WidgetKit self-updating text (widgets / Live Activity), never a stale timestamp.

---

## File map & target membership

| File | App | Widget ext |
|---|:---:|:---:|
| `BatteryKit/BatteryColors.swift` | ✓ | ✓ |
| `BatteryKit/UsageLevel.swift` | ✓ | ✓ |
| `BatteryKit/BatteryColors.swift` (palette + adaptive surfaces) | ✓ | ✓ |
| `BatteryKit/BatteryDesign.swift` (cards, bars, countdown, tokens) | ✓ | ✓ |
| `BatteryKit/UsageRing.swift` (the one shared ring) | ✓ | ✓ |
| `BatteryKit/TimeFormatting.swift` | ✓ | ✓ |
| `BatteryKit/UsageSnapshot.swift` | ✓ | – |
| `BatteryKit/BurnRateCalculator.swift` | ✓ | – |
| `BatteryKit/UsagePayload.swift` | ✓ | ✓ |
| `BatteryKit/SharedStore.swift` | ✓ | ✓ |
| `BatteryKit/UsageActivityAttributes.swift` (iOS-only, `#if os(iOS)`) | ✓ | ✓ |
| `BatteryApp/*` (app UI + services) | ✓ | – |
| `BatteryWidgets/*` (widgets + Live Activity UI) | – | ✓ |

> `BatteryKit` files are added to **both** targets via Xcode "Target Membership"
> (or, cleaner, compiled once into a shared framework/Swift package both targets
> link). The rows marked ✓✓ above are the shared contract.

---

## Run it — quick start

The repo ships an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec (`project.yml`)
so you don't hand-build the project:

```bash
brew install xcodegen           # once
cd ios
xcodegen generate               # creates Battery.xcodeproj (app + widget targets)
open Battery.xcodeproj
```

Then in Xcode:

1. Select the **Battery** scheme.
2. **Signing** — for each target (Battery + BatteryWidgets), open *Signing &
   Capabilities* and pick your Team. Leave "Automatically manage signing" on.
3. Pick a destination and **Run (⌘R)**.

### Fastest look: the Simulator (no Apple account, everything works)

The Simulator runs the app, widgets **and** the Live Activity with no signing and
no paid account — App Groups just work there. If you have no iOS runtime yet:
`xcodebuild -downloadPlatform iOS` (or Xcode ▸ Settings ▸ Components).

- Run to an **iPhone 15 Pro** (or newer) simulator to get the Dynamic Island.
- To populate every surface instantly, tap **"Preview with demo data"** on the
  sign-in screen (DEBUG builds only). It drives synthetic usage that climbs 38 % →
  96 % → resets on a loop, so you can watch the widgets refresh and the Live
  Activity **start → escalate to High/Critical → show the reset card → dismiss** —
  no real coding session required. Add the widgets from the widget gallery; the
  Live Activity appears on the Lock Screen and Dynamic Island automatically.

### On your iPhone

- **Plug in the phone**, select it as the destination, Run. First launch: trust the
  developer cert under *Settings ▸ General ▸ VPN & Device Management*.
- **Paid vs free Apple account — the one real gotcha:** the widgets read shared data
  through an **App Group**, which requires a **paid** Apple Developer membership
  ($99/yr). With a **free** personal team the app and the **Live Activity** still
  run on device (the activity gets its data from ActivityKit, not the App Group) —
  only the Home/Lock-Screen **widgets** need the paid account to read shared data.
  The Simulator sidesteps this entirely.
- Deployment target is **iOS 16.2+** (your iPhone on 26.5 is fine).

> `config/*.entitlements`, `config/BatteryApp-Info.plist`, and the file-membership
> table above describe what `project.yml` wires up — useful if you'd rather build
> the project by hand (File ▸ New ▸ Target ▸ Widget Extension, *Include Live
> Activity*, then add the folders with the membership shown).

---

## Auth caveats

The iOS login reuses the desktop app's mechanism: a **loopback HTTP listener** on
`http://localhost:<port>/callback` plus PKCE, presented in `SFSafariViewController`
(which keeps the app foreground so the socket stays alive to catch the redirect).

This assumes the OAuth client permits a **loopback redirect**, exactly as the
macOS app relies on. If Anthropic's client only allows the desktop's localhost
redirect and rejects it here, the fallbacks are:

- register a custom scheme (`battery://callback`) and switch `AuthService` to
  `ASWebAuthenticationSession`, or
- do the OAuth on the Mac and hand the phone a short-lived token via a QR pairing
  step (a small change to `TokenStore` seeding).

Everything downstream of "we have tokens" is unaffected.

---

## Going further (optional)

- **Complications / StandBy** — the accessory widgets already cover `.accessory*`
  families; watchOS complications would reuse the same `UsagePayload`.

> **Already implemented** (both were on this list):
> - **Multi-account** — add / switch / rename / remove, with per-account tokens in
>   the Keychain (`TokenStore` keyed by account id) and the selected account's
>   name carried into the payload.
> - **Instant Lock Screen updates** — ActivityKit push updates relayed from the
>   Mac app through a Cloudflare Worker. See "Keeping it current" above.
