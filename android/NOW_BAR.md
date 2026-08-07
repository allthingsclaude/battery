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

## The toggle: detected, handled

An earlier revision of this file claimed the gate "cannot be detected at
runtime, so the only honest handling is documentation". That was wrong, and
wrong for an avoidable reason — test 2 of this file's own checklist (grep the
settings namespaces) had never been run. It writes a readable key:

```
secure:  enable_notification_nowbar_test = 1
system:  settings_change_history = ...|notification_nowbar_test|com.android.settings
```

The change history even timestamps the moment it was flipped, which corroborates
the key rather than leaving it inferred from a plausible name.

`NowBarGate` reads it and reports four states, because "off" alone would send
some people to a screen that does not exist for them yet:

| State | Handling |
|---|---|
| `ENABLED` | say nothing |
| `DISABLED` | dismissible card + deep link to `ACTION_APPLICATION_DEVELOPMENT_SETTINGS` |
| `DEVELOPER_OPTIONS_OFF` | "tap Build number seven times", deep link to About phone |
| `NOT_APPLICABLE` | key absent — non-Samsung, or renamed. Say nothing rather than send a Pixel owner hunting a Samsung setting |

The `-1` sentinel on `getInt` matters: it is the only way to distinguish "absent"
from "present and 0", and those mean opposite things.

**Writing it is still impossible** — that needs `WRITE_SECURE_SETTINGS`, which no
ordinary app can hold. Detection plus a deep link is the whole of what is
achievable, but it is far better than a paragraph in a README: it appears only
when true, disappears when fixed, and works for someone who enables the toggle
months later.

Open question worth checking on a second device: whether the key is
One UI 8.5-specific, and whether One UI 9 / Android 17 defaults it on. If it
does, `NOT_APPLICABLE` quietly becomes the normal state and this all goes away.

## Field map — where each notification field renders

Verified on device by setting distinct markers, not read from documentation.
One UI's rendering does not match what the field names imply, so guessing here
is unusually expensive.

| Field | Renders |
|---|---|
| `setContentTitle` | Now Bar pill **line 1**, and the shade title |
| `setShortCriticalText` | Now Bar pill **line 2** *and* the status-bar chip — **one string, two surfaces** |
| `setColor` | tints the pill and the chip. Samsung's Clock uses `0xff5f57d9` and its chip is that purple, which is how this was identified |
| `setContentText` | shade only — **not** seen on the collapsed pill |
| `setSubText` | shade header |
| `setWhen` + `setChronometerCountDown` | the live countdown, ticking with zero updates |
| `ProgressStyle` bar/segments/points | shade only, as far as observed |

`setColorized(true)` and custom `RemoteViews` are **disqualifying** — either one
costs promotion entirely, so neither can be used to style these surfaces.

### The one string, two surfaces problem

`setShortCriticalText` feeding both the chip and the pill's second line is the
awkward constraint. The chip is a tiny always-on glance wanting the most urgent
number; the pill's second line sits under a title that already states the
session percentage, so repeating it there wastes the only spare line.

Currently resolved with `UsagePayload.focusWindow` — lead with whichever window
is closer to its ceiling. **This is not settled.** For an account whose weekly
runs far ahead of any single session (the common case: rarely past 20% in a
session, past that in the weekly within a day) it means the line reads `wk 28%`
almost always, and the session number only ever appears in the title.

### Unfinished: the layout experiment

Re-run when the API rate limit clears. Open questions:

- Does the pill render `setLargeIcon`? If it does, a rasterised ring from
  `UsageRingRenderer` could go on the lock screen — that was the "can we draw
  the circle" question and it was never answered.
- Does the pill show action buttons? Samsung's stopwatch has a pause control in
  its pill, so something reaches it.
- Does an expanded pill show more than two lines?
- Can the title carry both windows (`9% · wk 28%`) without truncating?

The probe build is easy to recreate: set every field to a distinct marker
(`1-TITLE`, `2-TEXT`, `3-SUB`, `4-CHIP`), add a `setLargeIcon` bitmap and an
action, install, and screenshot the lock screen and the expanded shade. It was
aborted last time by the rate limit, not by any difficulty.

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
