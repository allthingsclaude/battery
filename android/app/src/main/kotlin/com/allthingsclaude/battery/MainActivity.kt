package com.allthingsclaude.battery

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.allthingsclaude.battery.auth.AuthService
import com.allthingsclaude.battery.core.ReleaseFeed
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.data.Settings
import com.allthingsclaude.battery.data.UsageRepository
import com.allthingsclaude.battery.launcher.AppIcon
import com.allthingsclaude.battery.live.SessionService
import com.allthingsclaude.battery.update.UpdateChecker
import com.allthingsclaude.battery.widget.WidgetRefreshWorker
import com.allthingsclaude.battery.ui.AppearanceMode
import com.allthingsclaude.battery.ui.BatteryTheme
import com.allthingsclaude.battery.core.SessionPolicy
import androidx.activity.compose.BackHandler
import com.allthingsclaude.battery.ui.AppHeader
import com.allthingsclaude.battery.ui.DashboardScreen
import com.allthingsclaude.battery.ui.SettingsSheet
import com.allthingsclaude.battery.ui.UpdateUiState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The app. Signed out shows a sign-in gate; signed in shows the dashboard.
 *
 * Note what isn't here: a poll loop. Foreground polling would duplicate
 * [SessionService], and the two would race on the same shared snapshot buffer.
 * The screen renders the last-known payload and refreshes once on resume; the
 * service owns the cadence, because on Android the cadence and the card are the
 * same decision.
 */
class MainActivity : ComponentActivity() {

    private val requestNotifications =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) {
            requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            BatteryTheme(AppearanceMode.SYSTEM) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    // Without this the header draws under the system clock and
                    // the status pill is hidden behind the status bar entirely.
                    // Compose does not inset by default.
                    Box(Modifier.windowInsetsPadding(WindowInsets.systemBars)) { Root() }
                }
            }
        }
    }
}

@Composable
private fun Root() {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val repository = remember { UsageRepository(context) }
    val auth = remember { AuthService(context) }

    val settings = remember { Settings(context) }
    val updates = remember { UpdateChecker(context) }

    var payload by remember { mutableStateOf(repository.lastKnownPayload) }
    var signedIn by remember { mutableStateOf(repository.isSignedIn()) }
    var message by remember { mutableStateOf<String?>(null) }
    var showSettings by remember { mutableStateOf(false) }
    var cardMode by remember { mutableStateOf(settings.cardMode) }

    // The launcher icon, chosen now and applied on the way out.
    //
    // Applying it immediately kills the app, and DONT_KILL_APP cannot prevent
    // that: the flag spares the *process*, but disabling the alias this task was
    // launched from leaves the task rooted at a disabled component, and
    // ActivityManager clears it. Measured on One UI 8.5 — tap a tile, the app
    // closes. So the swap waits for ON_STOP, by which point the user is on their
    // way to the home screen where the new icon is what they wanted to see.
    //
    // Held here rather than in the sheet because it has to outlive it: close
    // Settings and then background the app, and a value owned by the sheet would
    // already have been disposed with nothing applied.
    val installedIcon = remember { AppIcon.current(context) }
    var pendingIcon by remember { mutableStateOf<AppIcon?>(null) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        // Never cleared once applied: `pendingIcon` then *is* the installed icon,
        // and clearing it would fall back to a stale `installedIcon` read at
        // composition. Re-applying the same choice is a no-op.
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                pendingIcon?.let { AppIcon.select(context, it) }
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    // The second writer of the status line, kept apart from `message` on purpose.
    // One slot shared with the error channel would not survive contact with the
    // poll: every successful poll sets `message = null`, and a poll runs on every
    // resume, so an update notice sharing that variable would blink out moments
    // after appearing — intermittently, and only on machines where the poll
    // happened to succeed.
    // Seeded from disk, not from the check: the check runs at most once a day, so
    // a notice that only existed in memory would appear on one launch in however
    // many and vanish for the rest. See Settings.pendingUpdate.
    //
    // Filtered against the installed version on the way in — see Settings.liveUpdate.
    var update by remember { mutableStateOf(settings.liveUpdate(updates.currentVersion)) }

    // Whether the *line* is still owed. Separate from `update`, which stays put
    // once found so that opening Settings shows the release rather than an empty
    // "Check for updates" — dismissing the announcement is not forgetting it.
    var announceUpdate by remember {
        mutableStateOf(update?.let { ReleaseFeed.shouldAnnounce(it, settings.skippedVersion) } == true)
    }

    // The manual check's state lives here rather than in the Settings sheet.
    // Owned by the sheet it was cancelled by closing the sheet — `rememberCoroutineScope`
    // dies with the composition — and its result reached neither the status line
    // nor the next opening of Settings. Both are things the check exists to feed.
    var updateCheck by remember { mutableStateOf<ReleaseFeed.Check?>(null) }
    var checkingUpdate by remember { mutableStateOf(false) }

    // Both entry points agree on what an outcome *means* and differ only in who
    // gets told — which is the distinction the four-case Check type exists for, so
    // the conclusion is shared and the reporting is not.
    fun applyCheck(result: ReleaseFeed.Check, userAsked: Boolean) {
        // The About row reports the check the user ran. A silent resume check
        // writing here would surface its failures later, out of context: open
        // Settings on wifi to change the card mode and read "couldn't reach
        // GitHub" about a plane journey that ended hours ago.
        if (userAsked) updateCheck = result
        // A silent check that reached a conclusion disproves an older manual
        // report, and must be allowed to retract it — otherwise "couldn't reach
        // GitHub" outlives the successful check that answered it, and the row
        // keeps saying it until the user thinks to tap again. Clearing is not
        // reporting, so a silent *failure* still says nothing.
        else if (result !is ReleaseFeed.Check.Failed) updateCheck = null

        when (result) {
            is ReleaseFeed.Check.Available -> {
                update = result.release
                // Suppressed only for someone still looking at the sheet as the
                // answer lands, who is reading it in the About row — for them,
                // closing the sheet must not immediately re-tell them.
                //
                // Not suppressed merely because they *asked*. The walk is up to
                // five sequential requests, which is why it runs on Root's scope
                // at all; tap Check and back out and the answer arrives to an
                // empty room. `userAsked` cannot tell those apart, and the
                // difference matters because nothing recovers the notice
                // afterwards: the resume re-seed is gated on `update == null`,
                // the manual stamp holds the throttle for a day, and this
                // variable's initializer is a `remember` that a singleTask warm
                // resume never re-runs. The line would be owed and never paid
                // until a cold launch.
                if (!userAsked || !showSettings) {
                    announceUpdate =
                        ReleaseFeed.shouldAnnounce(result.release, settings.skippedVersion)
                }
            }
            ReleaseFeed.Check.UpToDate -> {
                update = null
                announceUpdate = false
            }
            else -> Unit
        }
    }

    // One refresh per resume.
    //
    // `repeatOnLifecycle`, not a bare LaunchedEffect keyed on the lifecycle
    // owner. That was the original, and it did not do what its own comment
    // claimed: neither key changes when the activity is resumed, and the owner
    // was captured rather than observed, so the body ran once per *composition*
    // — a cold start. The activity is singleTask, so returning from the home
    // screen or tapping a widget resumes the existing instance without
    // recomposing, and nothing refreshed at all. That is the missing trigger
    // behind a card left sitting on a stale number: the surface that was
    // supposed to notice had stopped looking.
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner, signedIn) {
        if (!signedIn) return@LaunchedEffect
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            val result = repository.poll()
            when (result) {
                is UsageRepository.PollResult.Success -> {
                    payload = result.payload
                    message = null
                }
                UsageRepository.PollResult.SignedOut -> {
                    signedIn = false
                    message = "Session expired — sign in again."
                }
                is UsageRepository.PollResult.Failed -> message = result.message
                else -> Unit
            }
            // Start the service on anything short of a dead grant, NOT only on a
            // successful poll. The first version started it inside the Success
            // branch, so a single failed poll on launch — a rate limit, a dropped
            // connection — meant no card at all, even with a perfectly good
            // last-known payload to show. The service handles failures itself: it
            // holds the last value and backs off.
            //
            // Starting an already-running service is the deliberate path, not a
            // wasted call: it repaints the card from the payload this poll just
            // stored and wakes the poll loop out of its delay.
            if (result !is UsageRepository.PollResult.SignedOut && cardMode != SessionPolicy.Mode.OFF) {
                SessionService.start(context)
            }
            // Self-heals in both directions — see syncSchedule. Cheap: KEEP
            // leaves an existing schedule untouched rather than restarting it.
            WidgetRefreshWorker.syncSchedule(context)

            // The update check goes last and in its own coroutine: last so it
            // never competes with the poll for the radio, and launched so that up
            // to five sequential requests to GitHub cannot hold this block open
            // behind them. Cancelled with the block when the app leaves RESUMED.
            //
            // Silent by design. Every outcome except "there is a newer release"
            // produces nothing at all: an unreachable GitHub is not the user's
            // problem, and a red line under their usage ring about a service they
            // did not ask this app to contact would be noise reporting noise. The
            // Settings row is the loud version, for when they do ask.
            launch {
                // Recover first. A previous resume's check can be cancelled after
                // persisting what it found but before it could report it — the
                // write survives on the IO thread, the coroutine does not, and the
                // only other reader of the pref is a `remember` initializer that
                // will not run again until the Activity is recreated. Without this
                // the release sits on disk, invisible, while the throttle it also
                // stamped keeps any further check away for a day.
                if (update == null) {
                    settings.liveUpdate(updates.currentVersion)?.let { stored ->
                        update = stored
                        announceUpdate =
                            ReleaseFeed.shouldAnnounce(stored, settings.skippedVersion)
                    }
                }

                if (!settings.isUpdateCheckDue()) return@launch
                // Stamped BEFORE the walk on this path only. This coroutine is a
                // child of the RESUMED block and dies the instant the app is
                // backgrounded — a second or two after launch, for an app built
                // around a glance — so a stamp written afterwards is a stamp that
                // never happens, while the abandoned walk still went out on the
                // wire: Dispatchers.IO does not interrupt a blocking
                // HttpURLConnection. The throttle would then protect nothing.
                settings.lastUpdateCheckAt = System.currentTimeMillis()
                applyCheck(runUpdateCheck(settings, updates), userAsked = false)
            }
        }
    }

    if (!signedIn) {
        SignInGate(message) {
            auth.start { result ->
                scope.launch {
                    when (result) {
                        is AuthService.Result.Success ->
                            if (repository.addAccount(result.tokens)) {
                                signedIn = true
                                message = null
                            } else {
                                message = "Couldn't store the credential."
                            }
                        is AuthService.Result.Failure -> message = result.message
                        AuthService.Result.Cancelled -> message = null
                    }
                }
            }
        }
        return
    }

    val accounts = remember(signedIn, showSettings) { repository.listAccounts() }

    Column(Modifier.fillMaxSize()) {
        // Back closes settings rather than leaving the app. Without this the
        // system back gesture exits from a modal-feeling screen, which is the
        // one place users reliably expect it to go up a level instead.
        BackHandler(enabled = showSettings) { showSettings = false }

        // One header for both screens — see AppHeader. The status pill and the
        // account line only belong to the dashboard, so settings passes null.
        AppHeader(
            title = if (showSettings) "Settings" else "Battery",
            payload = if (showSettings) null else payload,
        ) {
            IconButton(onClick = { showSettings = !showSettings }) {
                Icon(
                    if (showSettings) Icons.Filled.Close else Icons.Filled.Settings,
                    contentDescription = if (showSettings) "Close settings" else "Settings",
                )
            }
        }

        Box(Modifier.weight(1f)) {
            when {
                showSettings -> SettingsSheet(
                    accounts = accounts,
                    selectedAccountId = repository.selectedAccountId,
                    onCardModeChanged = {
                        cardMode = it
                        // Restart so the new mode takes effect now rather than on
                        // the next poll — the point of choosing "Whole session"
                        // is seeing the card immediately.
                        SessionService.stop(context)
                        if (it != SessionPolicy.Mode.OFF) SessionService.start(context)
                    },
                    // Each of these three refreshes and then asks the *service*
                    // to repaint. They used to post the Live Update themselves,
                    // which bypassed all three gates that decide whether a card
                    // may exist — the card mode, SessionPolicy, and the record
                    // of a card the user swiped away.
                    onSelectAccount = {
                        repository.selectAccount(it)
                        scope.launch {
                            refresh(context, repository) { p, m -> payload = p; message = m }
                            repaintCard(context, cardMode)
                        }
                    },
                    onRenameAccount = { id, name ->
                        repository.renameAccount(id, name)
                        scope.launch {
                            refresh(context, repository) { p, m -> payload = p; message = m }
                            repaintCard(context, cardMode)
                        }
                    },
                    onRemoveAccount = {
                        repository.removeAccount(it)
                        scope.launch {
                            refresh(context, repository) { p, m -> payload = p; message = m }
                            // No repaint: the account this card described is
                            // gone. If any remain the next poll brings it back.
                            SessionService.stop(context)
                        }
                    },
                    onAddAccount = {
                        auth.start { result ->
                            scope.launch {
                                when (result) {
                                    is AuthService.Result.Success ->
                                        if (repository.addAccount(result.tokens)) {
                                            showSettings = false
                                            refresh(context, repository) { p, m ->
                                                payload = p; message = m
                                            }
                                            signedIn = true
                                            repaintCard(context, cardMode)
                                        } else {
                                            message = "Couldn't store the credential."
                                        }
                                    is AuthService.Result.Failure -> message = result.message
                                    AuthService.Result.Cancelled -> Unit
                                }
                            }
                        }
                    },
                    onSignOut = {
                        repository.signOutAll()
                        signedIn = false
                        payload = null
                        showSettings = false
                        SessionService.stop(context)
                    },
                    onOpenDiagnostics = {
                        context.startActivity(Intent(context, SpikeActivity::class.java))
                    },
                    updateState = UpdateUiState(
                        currentVersion = updates.currentVersion,
                        known = update,
                        check = updateCheck,
                        checking = checkingUpdate,
                        onCheck = {
                            checkingUpdate = true
                            // Root's scope, not the sheet's: this must survive the
                            // user closing Settings while it is still running.
                            scope.launch {
                                try {
                                    val result = runUpdateCheck(settings, updates)
                                    // Stamped after, and only on an answer. This
                                    // path has no cancellation to defend against —
                                    // and a manual check that failed learned
                                    // nothing, so counting it as the day's check
                                    // would silence the automatic one for 24h over
                                    // a moment of no signal.
                                    if (result !is ReleaseFeed.Check.Failed) {
                                        settings.lastUpdateCheckAt = System.currentTimeMillis()
                                    }
                                    applyCheck(result, userAsked = true)
                                } finally {
                                    checkingUpdate = false
                                }
                            }
                        },
                        onOpen = updates::openRelease,
                    ),
                    appIcon = pendingIcon ?: installedIcon,
                    onAppIconChange = { pendingIcon = it },
                )
                payload != null -> DashboardScreen(payload!!, cardMode)
                else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Fetching your usage…", style = MaterialTheme.typography.bodyLarge)
                }
            }
        }

        // One line, two writers. The error wins when both have something to say:
        // a failed poll means the number above this line is stale, which matters
        // more than a release that will still be there on the next launch.
        val error = message
        // Not while Settings is open — the About row is showing the same release
        // with a better affordance, and "open Settings" is poor advice to someone
        // already there.
        val available = update?.takeIf { announceUpdate && !showSettings }
        when {
            error != null -> StatusLine(error, MaterialTheme.colorScheme.error)
            available != null -> StatusLine(
                "Version ${available.version} available — open Settings to update",
                MaterialTheme.colorScheme.primary,
            ) {
                // Tapping through IS the dismissal. Settings opens showing this
                // release and the link to it, so the line has done its job;
                // announcing it again tomorrow would be nagging someone who
                // already knows. A newer release still gets through — see
                // ReleaseFeed.shouldAnnounce.
                settings.skippedVersion = available.version
                announceUpdate = false
                showSettings = true
            }
        }
    }
}

/**
 * One update check, shared by the launch check and the Settings row.
 *
 * The throttle is stamped *before* the walk and the result persisted from *inside*
 * the IO block, both deliberately. The automatic caller is a child of
 * `repeatOnLifecycle(RESUMED)` and dies the instant the app is backgrounded —
 * which, for an app whose whole job is a glance at a number, is a second or two
 * after launch and long before five sequential requests to GitHub can finish.
 * Written after the walk, neither ever happened on the resumes that matter: the
 * throttle would almost never apply, and a release the walk really did find would
 * be forgotten. Meanwhile the abandoned walk still went out on the wire, because
 * `Dispatchers.IO` does not interrupt a blocking `HttpURLConnection` — so the
 * requests were spent either way, against a quota of sixty an hour.
 *
 * SharedPreferences writes here use `apply()`, so calling them from the IO
 * dispatcher is safe.
 */
private suspend fun runUpdateCheck(
    settings: Settings,
    updates: UpdateChecker,
): ReleaseFeed.Check =
    withContext(Dispatchers.IO) {
        updates.check().also { result ->
            // Logged unconditionally, like the worker's run and the service's poll.
            // The automatic check reports nothing to the user by design, so without
            // this there is no way — on a device, in the field — to tell a check
            // that ran and found nothing from one that was throttled, cancelled, or
            // failed. All three look identical: an app that says nothing.
            //
            // The feed is in the line because the answer alone does not identify
            // it. A build polling the wrong repository reports "up to date" in the
            // same words as one polling the right one, and without this the only
            // way to tell was to pull the APK and read the slug out of its dex.
            Log.i(
                TAG,
                "update check: $result (installed ${updates.currentVersion}, feed ${updates.repo})",
            )
            when (result) {
                is ReleaseFeed.Check.Available -> settings.pendingUpdate = result.release
                // The one outcome that proves a remembered release is spent.
                // NoRelease and every failure say nothing about it, and dropping a
                // known update because GitHub was down would be this updater going
                // quiet again, by a new route.
                ReleaseFeed.Check.UpToDate -> settings.pendingUpdate = null
                else -> Unit
            }
        }
    }

/**
 * The stored release, if it is still ahead of what is installed — clearing it if
 * it is not.
 *
 * Installing is exactly what a remembered release does not survive, and it happens
 * well inside the 24h throttle, so no check would run to clear it. Without this,
 * updating buys a day of being told to update to the version you just installed,
 * from a row whose only action is to open it again.
 */
private fun Settings.liveUpdate(installedVersion: String): ReleaseFeed.Release? {
    val stored = pendingUpdate ?: return null
    if (ReleaseFeed.compareVersions(stored.version, installedVersion) > 0) return stored
    pendingUpdate = null
    return null
}

private const val TAG = "UpdateCheck"

/**
 * The status line under everything, and the app's only ambient channel.
 *
 * Not always an error, which it was until an update notice needed somewhere to
 * live: the colour was hardcoded to `colorScheme.error`, so good news rendered
 * here would have arrived in the same red as an expired session.
 */
@Composable
private fun StatusLine(text: String, color: Color, onClick: (() -> Unit)? = null) {
    Text(
        text,
        Modifier
            .fillMaxWidth()
            // Before the padding, so the padding is part of the touch target
            // rather than a dead border around a one-line tap target.
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 20.dp, vertical = 8.dp),
        style = MaterialTheme.typography.bodySmall,
        color = color,
    )
}

@Composable
private fun SignInGate(message: String?, onSignIn: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // The placeholder is what a ring looks like with data, which is a more
        // honest promise than an icon — and it's the same constant the widget
        // preview uses, so the gate and the gallery can't disagree.
        com.allthingsclaude.battery.ui.UsageRing(
            utilization = UsagePayload.PLACEHOLDER.sessionUtilization,
            size = 148.dp,
        )
        Text(
            "Battery",
            Modifier.padding(top = 24.dp),
            style = MaterialTheme.typography.headlineMedium,
        )
        Text(
            "Watch your Claude Code session and weekly limits from the lock screen.",
            Modifier.padding(top = 8.dp, bottom = 28.dp),
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
        )
        Button(onClick = onSignIn, modifier = Modifier.fillMaxWidth()) {
            Text("Sign in with Claude")
        }
        message?.let {
            Text(
                it,
                Modifier.padding(top = 16.dp),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/**
 * Ask [SessionService] to repaint, honouring the user's card mode.
 *
 * The one place Settings actions are allowed to touch the card. Starting the
 * service is the whole mechanism: `onStartCommand` promotes from the payload the
 * poll just stored and wakes the loop, and the loop is where `SessionPolicy` and
 * the dismissal record get consulted. Posting the notification directly — which
 * these handlers used to do — skips all of that.
 */
private fun repaintCard(context: android.content.Context, mode: SessionPolicy.Mode) {
    if (mode != SessionPolicy.Mode.OFF) SessionService.start(context)
}
