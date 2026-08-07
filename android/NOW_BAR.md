# The Now Bar: solved

**It works, on plain AOSP APIs, with no Samsung-specific code at all.** The
blocker was never a missing capability — it was a switch that ships off.

Verified on a Galaxy S24 Ultra, SM-S928B, One UI 8.5 / Android 16 / API 36.

## The answer

**Developer options ▸ "Live notifications for all apps" is OFF by default in One
UI 8.5 stable.** Turn it on and a standard `Notification.ProgressStyle` Live
Update reaches every surface at once:

| Surface | With the toggle off | With it on |
|---|---|---|
| Samsung Now Bar pill (lock screen) | ✗ | ✅ `Claude · 8%` |
| Status-bar chip | ✗ (icon only) | ✅ |
| Lock-screen card | ✅ | ✅ |
| Top of the notification shade | ✅ | ✅ |

Nothing in the app changed between those two columns.

## Why this took so long to find

The failure was **partial**, which is the worst kind. With the toggle off the
notification still earns `FLAG_PROMOTED_ONGOING`, still gets the prominent
lock-screen card, still outranks everything in the shade. Every diagnostic said
"promoted". Only two of four surfaces were missing, which reads as a
capability Samsung withholds rather than a switch nobody flipped.

That led to a wrong conclusion being written down as settled: *"One UI does not
render the AOSP status-bar chip; `setShortCriticalText` reaches the system and
Samsung simply doesn't draw it; there is no alternative API and this is not
fixable from the app."* All of it was gated, none of it was true.

`setShortCriticalText` is used, incidentally — One UI renders it as the pill's
second line, not in the status bar. On our card that's the `8%` under
`Claude · 8%`.

## The two-pipeline theory: half right, and irrelevant

Samsung's own apps genuinely do not use AOSP promotion. The Clock's stopwatch,
dumped while sitting in the Now Bar:

```
flags=ONGOING_EVENT|NO_CLEAR|FOREGROUND_SERVICE     ← no PROMOTED_ONGOING
mIsPromotion=false
android.ongoingActivityNoti.nowbarPrimaryInfo = "Stopwatch"
android.ongoingActivityNoti.secondaryInfo     = "No laps completed"
android.ongoingActivityNoti.chipIcon          = Icon(...)
android.ongoingActivityNoti.chronometerRemoteViewTag = "stopwatch_ongoing_activity_chronometer"
```

So the private pipeline is real. It is simply **not the only way in**, which is
the part the research got wrong. Proven by posting with those extras provably
absent — `ongoingActivityNoti keys: 0` — and watching the pill appear anyway.

The decompiled extras and the
`com.samsung.android.support.ongoing_activity` manifest entry have therefore
been **deleted**, not kept as a fallback. Shipping reverse-engineered keys that
demonstrably do nothing is worse than not shipping them.

## Also settled

- **The Settings ▸ Live notifications allowlist is irrelevant.** Battery is not
  in it and reaches the Now Bar regardless. It is an OS-curated list (an inert
  Uber toggle appeared there before Uber had implemented anything), and
  membership is neither necessary nor sufficient.
- **Only one status-bar chip renders at a time.** With the stopwatch running it
  held the chip and ours did not appear. The Now Bar pill is not similarly
  limited — both were present.

## The remaining problem: it needs a developer-options toggle

This is now a distribution problem rather than an engineering one, and it is not
solved.

- **It cannot be detected at runtime.** With the toggle off, promotion still
  succeeds — `canPostPromotedNotifications()` is true and `FLAG_PROMOTED_ONGOING`
  is set. There is no signal that separates "promoted and rendering everywhere"
  from "promoted and rendering in half the places", so the app cannot
  helpfully prompt for it.
- **It cannot be enabled programmatically.** Developer options are not
  app-writable.
- So the only honest handling is documentation: first-run guidance saying the
  Now Bar and status-bar chip need Developer options ▸ *Live notifications for
  all apps*, and that the lock-screen card works without it.

Open question worth checking on a second device: whether this toggle is
One UI 8.5-specific, and whether One UI 9 / Android 17 defaults it on. If it
does, this whole section becomes a footnote.

## What the app actually does

Plain AOSP, and that is the whole point:

- `POST_PROMOTED_NOTIFICATIONS` + `setRequestPromotedOngoing(true)` + `setOngoing(true)`
- `Notification.ProgressStyle` with the terracotta ramp as segments and the
  projection as a `Point`
- `setShortCriticalText` — the pill's second line
- `setWhen` + `setChronometerCountDown` — the countdown, ticking with zero updates
- `setCategory(CATEGORY_PROGRESS)` — not required, but honest semantics
- a `specialUse` foreground service whose notification *is* the card

## Dead ends — do not re-litigate

- No public Samsung Now Bar SDK exists.
- `setColorized(true)` and custom `RemoteViews` are **disqualifying** under AOSP.
- `MediaSession` only earns the dedicated "Media player" row.
- The AOSP feature flags (`ui_rich_ongoing` et al.) were never the gate; they
  were enabled throughout.
- The `ongoingActivityNoti.*` extras are not needed. Tried, measured, removed.
