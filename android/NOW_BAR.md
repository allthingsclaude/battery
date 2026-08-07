# The Now Bar: what we know, and what to test next

Status as of Phase 0 + research. Read this before spending another hour on the
Now Bar — most of the obvious theories are already dead.

## What works today

On a Galaxy S24 Ultra (SM-S928B), One UI 8.5 / Android 16 / API 36, the app's
`ProgressStyle` notification is promoted by the system:

```
flags=ONGOING_EVENT|PROMOTED_ONGOING
```

That buys the **prominent lock-screen card** and **top-of-shade ranking** — it
outranks a freshly-arrived IM. No developer flag was needed; the
`Live notifications for all apps` toggle was a One UI 8 *beta* gate.

## What doesn't, and why it probably isn't our fault

| Surface | Result |
|---|---|
| Status-bar chip (`setShortCriticalText`) | **Not rendered.** One UI draws the app's small icon instead |
| Samsung's bottom Now Bar pill | **Not reached** |
| AOD | Icon only (but see test 8 — this may be normal One UI behaviour) |

`setShortCriticalText` is not missing or wrong: the value reaches the system,
sitting in the posted notification's extras as
`android.shortCriticalText=String (87%)`. AOSP's feature flags are all on
(`android.app.ui_rich_ongoing`, `status_bar_chips_modernization`). Samsung simply
doesn't draw it — and the neighbouring `status_bar_call_chip_use_is_hidden=true`
shows they deliberately hide AOSP's chip in favour of their own.

## The two-pipeline theory

Decompilation of Samsung Clock, Health, Voice Recorder, SmartThings and Notes
finds `android.ongoingActivityNoti.*` extras, a
`com.samsung.android.support.ongoing_activity` manifest entry, and feature
detection on `com.samsung.feature.nowbar` — and **no** `setRequestPromotedOngoing`,
`POST_PROMOTED_NOTIFICATIONS` or `Notification.ProgressStyle` anywhere. Samsung's
own apps do not use the API we're using.

So One UI likely runs AOSP promoted notifications (→ lock-screen card) and a
private Samsung ongoing-activity path (→ Now Bar + chip) side by side.

## Two things that are settled

**The Settings ▸ Live notifications list is a Samsung-curated allowlist.** The
decisive evidence: an **Uber** toggle appeared in that list on an internal
One UI 8 build and was completely inert — enabling it changed nothing, because
Uber hadn't implemented anything. Samsung shipped the toggle from the OS side,
keyed on package name. No amount of correct code adds us to that list. Perplexity
is almost certainly there via its Galaxy partnership (preloaded on S26, "first
non-Google company to receive OS-level access").

**But list membership is not required for the Now Bar.** Zomato (v19.2.4.1, Oct
2025) shipped Now Bar *and* status-bar pill support using Android 16 Live
Updates, and users report no toggle for it in that settings list. A third-party
non-partner app got there on the public API.

**Therefore: stop chasing the list. Chase the chip.** Zomato is the existence
proof that it's reachable.

## Device tests, in order

Run top to bottom; stop when one succeeds. Each says what its result *means*.

1. **Developer options → "Live notifications for all apps".**
   Present and OFF → enable, repost. Chip appears ⇒ **done, that's the gate.**
   Present and ON already ⇒ refutes the hypothesis, go to 4.
   Absent ⇒ removed or renamed in 8.5; note it.

2. `adb shell settings list global | grep -iE 'live|nowbar|ongoing|promoted'`
   (repeat for `secure`, `system`). A Samsung-namespaced key can be flipped
   directly with `settings put` — fastest possible win.

3. **Spike app → "Refresh diagnostics".** Read `canPostPromoted` and
   `feature.nowbar`. `canPostPromoted=false` ⇒ a settings toggle is blocking us,
   not code. `feature.nowbar=false` ⇒ the device doesn't advertise the Now Bar
   at all, which would reframe everything.

4. **Spike app → "Open promoted-notification settings".** *Which screen appears
   is the finding.* A dedicated per-app Live-notifications toggle ⇒ AOSP's
   surface is wired and that's the gate. The generic app-notification screen, or
   nothing ⇒ Samsung didn't wire it, corroborating the two-pipeline theory.
   (Note: the Android docs name this intent `ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS`,
   which does not exist. The real constant is `ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS`.)

5. **Spike app → toggle "Samsung ongoing-activity extras", which reposts.**
   Chip or Now Bar appears ⇒ the private extras are the path and are not
   whitelisted. Nothing ⇒ expected; the path is package-gated.

6. **Install Zomato, trigger an order, or build Google's `platform-samples`
   live-updates sample.** *This is the highest-value test in the list.* If
   Zomato/the sample gets a chip and we don't, the difference is in **our
   payload** — diff the two `dumpsys notification` records. If neither does, it's
   a device-wide gate and no code change will help.

7. `adb shell dumpsys notification --noredact`, then start a Samsung Clock timer
   or a Voice Recorder recording and diff their record against ours. Look for
   `android.ongoingActivityNoti.*` keys in theirs. Present in theirs and absent
   in ours ⇒ confirms the two pipelines and names the exact keys that matter.

8. **AOD.** Set *Settings ▸ Lock screen and AOD ▸ Always On Display ▸ When to
   show* = **Always** (it was off entirely during Phase 0, so that result was
   void). Then **double-tap the notification icon on the AOD**. If the card
   expands, our AOD observation is normal One UI behaviour and not a bug — don't
   spend engineering time on it.

## Already applied in code

- `com.samsung.android.support.ongoing_activity` manifest meta-data
- `setCategory(CATEGORY_PROGRESS)`
- `LiveUpdateNotifier.samsungExtrasEnabled` — the private-extras experiment,
  default off, toggleable in the spike UI
- `feature.nowbar` and `canPostPromotedNotifications()` in `diagnose()`

## Dead ends — do not re-litigate

- **There is no public Samsung Now Bar SDK.** A developer asked on the Samsung
  Developer Forums in Feb 2025; the thread is unanswered, and a site-restricted
  search of developer.samsung.com turns up nothing else.
- **`setColorized(true)`** and **custom `RemoteViews`** are *disqualifying* under
  AOSP — they'd lose us the card we already have.
- **Our AOSP implementation is not the problem.** `FLAG_PROMOTED_ONGOING` proves
  every documented clause is satisfied. Don't re-audit it.
- **`MediaSession`** only earns the dedicated "Media player" row. It is not a
  general Now Bar entry point, and a usage meter can't use it.
- **AOSP feature flags** are all enabled; they aren't the gate.

## The honest fallback

If every test above fails, the lock-screen card is what Android gives a
non-partner app — and per PLAN_01 that was accepted as the product. It is a live,
always-current usage meter on the lock screen with a countdown that ticks for
free, ranked above everything else in the shade. The Now Bar pill would be nice.
It was never the thing that makes this useful.
