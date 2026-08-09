# Cross-platform golden fixtures

The same numbers and the same words, asserted on every platform that ships them.

`Sources/` (macOS), `ios/BatteryKit/` and `android/core/` each carry their own
implementation of the burn-rate regression, the forecast, and the time
formatting. Three implementations of one specification is a drift machine: a
threshold nudged on one platform is invisible on the others until a user notices
their Mac and their phone disagree about when a session runs out.

These files are the specification. Each case names the Swift test it was
transcribed from, so the provenance of every expected value is checkable.

## The rule that makes this worth anything

**Expected values are derived from the Swift suite, never from running the
Kotlin.** A fixture whose expectations were produced by the implementation it
checks tests that implementation against itself and passes forever. If a case
here disagrees with `Tests/BatteryTests/`, the fixture is wrong — fix it here,
then fix whichever implementation drifted.

## Runners

| Platform | Runner | Status |
|---|---|---|
| Android / Kotlin | `android/core/src/test/kotlin/.../GoldenFixtureTest.kt` | ✅ |
| macOS + iOS / Swift | `Tests/BatteryTests/` | ⏳ still asserting inline; porting it to read these files is the remaining half of the guarantee |

Until the Swift side reads these files, this catches Kotlin drifting away from a
snapshot of Swift — not Swift drifting away from Kotlin. That's the weaker half
of the property, and worth closing.

## Files

| File | Specifies | Transcribed from |
|---|---|---|
| `usage-level.json` | 50 / 75 / 90 severity thresholds | `ColorThresholdsTests.swift` |
| `time-formatting.json` | `shortDuration`, `relativeTime` | `TimeFormattingTests.swift` |
| `burn-rate.json` | the linear regression and its guards | `BurnRateCalculatorTests.swift` |

## Schema notes

Times are **relative**, expressed as offsets in minutes or seconds from the
moment the test runs, because the Swift originals build their snapshots that way
(`Date().addingTimeInterval(-minutesAgo * 60)`). Fixing absolute timestamps
would change what the cases actually exercise — several of them turn on the
window still being open *now*.

Expectations are objects so a case can assert exactly (`equals`), with tolerance
(`equals` + `accuracy`, mirroring XCTest's `accuracy:`), or as a range
(`greaterThan` / `lessThan`). Ranges are used where the Swift test used them:
the regression's output depends on sub-second timing, so pinning an exact slope
would make the suite flaky on both platforms.
