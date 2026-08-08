package com.allthingsclaude.battery

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.allthingsclaude.battery.auth.AuthService
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.data.Settings
import com.allthingsclaude.battery.data.UsageRepository
import com.allthingsclaude.battery.live.SessionService
import com.allthingsclaude.battery.ui.AppearanceMode
import com.allthingsclaude.battery.ui.BatteryTheme
import com.allthingsclaude.battery.core.SessionPolicy
import androidx.activity.compose.BackHandler
import com.allthingsclaude.battery.ui.AppHeader
import com.allthingsclaude.battery.ui.DashboardScreen
import com.allthingsclaude.battery.ui.SettingsSheet
import kotlinx.coroutines.launch

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

    var payload by remember { mutableStateOf(repository.lastKnownPayload) }
    var signedIn by remember { mutableStateOf(repository.isSignedIn()) }
    var message by remember { mutableStateOf<String?>(null) }
    var showSettings by remember { mutableStateOf(false) }
    var cardMode by remember { mutableStateOf(Settings(context).cardMode) }

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
                )
                payload != null -> DashboardScreen(payload!!, cardMode)
                else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Fetching your usage…", style = MaterialTheme.typography.bodyLarge)
                }
            }
        }

        message?.let {
            Text(
                it,
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        }
    }
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
