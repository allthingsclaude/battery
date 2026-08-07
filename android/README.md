# Battery for Android — lock-screen card, widgets, and the app

The third surface, after the macOS menu bar and the iPhone. Same OAuth client,
same `/api/oauth/usage` endpoint, same terracotta.

The headline difference from iOS is one line:

```
card exists  ⟺  service running  ⟺  fast polling
```

On iOS the poll loop and the Live Activity are separate concerns reconciled by
`LiveActivityController.sync()`. Here the foreground service's notification *is*
the card, so those collapse into a single decision — which is less code, and
makes the foreground service self-justifying in exactly the way Google's Live
Update guidelines want. It isn't a background poller wearing a notification as a
disguise; the notification is the product.

---

## Layout

```
android/
  core/    pure Kotlin/JVM — no Android dependency at all
           UsagePayload · UsageLevel · BurnRateCalculator · UsageForecast
           SessionHistory · SessionPolicy · UsageApi · ReleaseFeed
  app/     everything Android: Compose UI, auth, storage, the service, widgets
```

`core/` staying Android-free is a rule worth defending, not an accident. It is
what lets the regression, the forecast wording and the card's state machine run
as ordinary JVM tests in milliseconds against the fixtures in `../fixtures/` —
and it is the reason `SessionPolicy` has thirteen tests where the iOS original
has none.

Glance widgets need no separate module. Unlike iOS, where the widget extension
is a codesigned `.appex` in its own process, they are a `BroadcastReceiver` in
this same APK.

---

## The Now Bar

Read [`NOW_BAR.md`](NOW_BAR.md) before spending time on it. Short version:

- The promoted **lock-screen card works** — verified on a Galaxy S24 Ultra,
  One UI 8.5: `flags=ONGOING_EVENT|PROMOTED_ONGOING`, no developer flag needed.
- The **status-bar chip does not render**, and it is not our bug —
  `setShortCriticalText` reaches the system, and Samsung's SystemUI simply
  doesn't draw the AOSP chip.
- Samsung's **bottom Now Bar pill is a second, private pipeline** that Samsung's
  own apps use and which is probably package-whitelisted.
- The **Settings ▸ Live notifications list is an OS-curated allowlist.** No code
  gets an app into it. But list membership is *not* required for the Now Bar, so
  it isn't the thing to chase.

---

## Build and run

```bash
cd android
./gradlew :core:test          # the fixtures — fast, and the first thing to break
./gradlew :app:assembleDebug
./gradlew :app:installDebug
```

Requires **JDK 17+** and **compileSdk 37**
(`android sdk install platforms/android-37.1`). The build targets 17 bytecode
without pinning a toolchain, so any modern JDK works locally; CI pins 17
explicitly rather than inheriting whatever the runner image ships.

- `minSdk 31` — the app installs from Android 12.
- `targetSdk 36` — matches the device.
- **The lock-screen card needs API 36.** Below that everything else still works;
  the card is gated at runtime, not in the manifest.

### Diagnostics

The dashboard's *Diagnostics* button opens the Phase 0 harness: post a card at
any percentage, toggle the Samsung private extras, read
`canPostPromotedNotifications` / `hasPromotableCharacteristics` /
`FLAG_PROMOTED_ONGOING` / `feature.nowbar`, and jump to the system's
promoted-notification settings. It's kept because the Now Bar questions are open
and answering them needs a card at 91% on demand.

---

## Releasing

```bash
git tag android-v0.1.0 && git push origin android-v0.1.0
```

`.github/workflows/android-release.yml` builds, signs, and publishes the APK to
GitHub Releases. `android-v*` is a third tag namespace beside `v*` (Mac) and
`ios-v*` (iOS), for the same reason `ios-v*` exists — the three ship on their own
cadences.

`versionName` comes from the tag and `versionCode` from the commit count, so
there is no second place to remember to bump. Local builds fall back to the
literals in `app/build.gradle.kts`.

### Secrets

Four, all repository-level. **None are shared with the Mac or iOS releases** —
those use Apple certificates, which cannot sign an APK.

| Secret | What it is |
|---|---|
| `ANDROID_KEYSTORE` | base64 of the release `.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | store password |
| `ANDROID_KEY_ALIAS` | key alias inside the store |
| `ANDROID_KEY_PASSWORD` | key password |

```bash
keytool -genkeypair -v -keystore release.jks -alias battery \
  -keyalg RSA -keysize 4096 -validity 10000
base64 -i release.jks | gh secret set ANDROID_KEYSTORE
```

> **The keystore is permanent.** Android has no key rotation for sideloaded
> APKs: a build signed with key A can never be updated by one signed with key B —
> users have to uninstall, losing their data and their sign-in. Whoever generates
> this key owns the app's identity for as long as the app exists. Decide who that
> is *before* the first release, not after.

The workflow shreds the decoded keystore in an `if: always()` step, so a failed
build doesn't leave a signing key in the runner's temp directory.

`assembleRelease` works locally without any of this — the signing config falls
back to the debug key when `BATTERY_KEYSTORE` is unset, so you can build and
install a release APK on your own device without holding the real key.

### Updates

A sideloaded APK has neither Sparkle nor TestFlight, so `UpdateChecker` polls the
GitHub releases feed. It is deliberately **check-and-hand-off**: it opens the
release page rather than downloading and installing, because installing would
mean holding `REQUEST_INSTALL_PACKAGES` — a permission that lets an app install
arbitrary software. Two extra taps, one fewer permission that has no business
being here.

---

## Notes for anyone changing this

- **`core/` must not gain an Android dependency.** The moment it does, the shared
  fixture story is over and `SessionPolicy` stops being testable.
- **Every string about a projection comes from `UsageForecast`.** This branch
  already made the opposite mistake once: the Live Update kept a "temporary"
  local headline helper after the port landed, and the lock-screen card and the
  in-app card promptly disagreed about the same payload.
- **Never repost a dismissed card.** `CardDismissal` enforces it. Reposting is
  what drives users to revoke promotion, and that revocation is effectively
  permanent.
- **The foreground service is `specialUse`, not `dataSync`.** `dataSync` is capped
  at 6h per 24h on Android 15+ and the system *throws* at the limit rather than
  degrading.
- **Fixtures are the specification.** If `../fixtures/` disagrees with
  `Tests/BatteryTests/`, the fixture is wrong — fix it there first, then fix
  whichever implementation drifted.
