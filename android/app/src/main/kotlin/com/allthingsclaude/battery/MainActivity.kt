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
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.allthingsclaude.battery.auth.AuthService
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.data.Settings
import com.allthingsclaude.battery.data.UsageRepository
import com.allthingsclaude.battery.live.SessionService
import com.allthingsclaude.battery.ui.AppearanceMode
import com.allthingsclaude.battery.ui.BatteryTheme
import com.allthingsclaude.battery.core.SessionPolicy
import com.allthingsclaude.battery.ui.DashboardScreen
import com.allthingsclaude.battery.ui.SettingsSheet
import com.allthingsclaude.battery.widget.refreshAllWidgets
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

    // One refresh per resume. Enough to make reopening the app feel current
    // without competing with the service for the poll budget.
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner, signedIn) {
        if (!signedIn) return@LaunchedEffect
        when (val result = repository.poll()) {
            is UsageRepository.PollResult.Success -> {
                payload = result.payload
                message = null
                SessionService.start(context)
            }
            UsageRepository.PollResult.SignedOut -> {
                signedIn = false
                message = "Session expired — sign in again."
            }
            is UsageRepository.PollResult.Failed -> message = result.message
            else -> Unit
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

    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f)) {
            when {
                showSettings -> SettingsSheet(
                    onCardModeChanged = {
                        cardMode = it
                        // Restart so the new mode takes effect now rather than
                        // on the next poll — the whole point of choosing
                        // "Whole session" is seeing the card immediately.
                        SessionService.stop(context)
                        if (it != SessionPolicy.Mode.OFF) SessionService.start(context)
                    },
                    onWidgetBackgroundChanged = {
                        scope.launch { refreshAllWidgets(context) }
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
                Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        }

        Row(
            Modifier.fillMaxWidth().padding(20.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedButton(onClick = {
                repository.signOutAll()
                signedIn = false
                payload = null
                SessionService.stop(context)
            }) { Text("Sign out") }

            TextButton(onClick = { showSettings = !showSettings }) {
                Text(if (showSettings) "Done" else "Settings")
            }

            TextButton(onClick = {
                context.startActivity(Intent(context, SpikeActivity::class.java))
            }) { Text("Diagnostics") }
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
