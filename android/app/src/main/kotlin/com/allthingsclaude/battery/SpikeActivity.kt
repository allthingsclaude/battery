package com.allthingsclaude.battery

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.allthingsclaude.battery.auth.AuthService
import com.allthingsclaude.battery.core.AppConfig
import com.allthingsclaude.battery.core.UsageForecast
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.data.UsageRepository
import com.allthingsclaude.battery.live.LiveUpdateNotifier
import com.allthingsclaude.battery.live.SessionService
import kotlinx.coroutines.launch

/**
 * The Phase 0/2 harness. Not the real UI — the Compose dashboard is Phase 4.
 *
 * It does two jobs. **Synthetic mode** posts a card from
 * [UsagePayload.PLACEHOLDER] so the notification can be exercised without a live
 * session, including at percentages a real account would take hours to reach.
 * **Live mode** signs in for real and polls the usage API, which is what proves
 * the whole chain end to end.
 *
 * Everything here is deliberately one screen of buttons: the value is in being
 * able to reach any state on demand, not in looking like anything.
 */
class SpikeActivity : ComponentActivity() {

    private val requestNotifications =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) {
            requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) { SpikeScreen() }
            }
        }
    }
}

@Composable
private fun SpikeScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val repository = remember { UsageRepository(context) }
    val auth = remember { AuthService(context) }

    val placeholder = remember { UsagePayload.PLACEHOLDER }
    var synthetic by remember { mutableDoubleStateOf(placeholder.sessionUtilization) }
    var live by remember { mutableStateOf(repository.lastKnownPayload) }
    var status by remember {
        mutableStateOf(if (repository.isSignedIn()) "Signed in." else "Not signed in.")
    }
    var diagnostics by remember { mutableStateOf("Post a card, then refresh.") }

    // Live data wins when we have it — the synthetic slider is the fallback.
    fun payload(): UsagePayload =
        live ?: placeholder.copy(sessionUtilization = synthetic)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("Battery — harness", style = MaterialTheme.typography.headlineSmall)
        Text(status, style = MaterialTheme.typography.bodyMedium)

        live?.let { p ->
            val forecast = UsageForecast(p)
            Card {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        "${p.accountName}${if (p.planTier.isNotEmpty()) " · ${p.planTier}" else ""}",
                        style = MaterialTheme.typography.labelSmall,
                    )
                    Text(
                        "Session ${p.sessionUtilization.toInt()}%  ·  Weekly ${p.weeklyUtilization.toInt()}%",
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(forecast.headline, style = MaterialTheme.typography.bodyMedium)
                    forecast.detail?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall)
                    }
                    Text(
                        "${forecast.badgeLabel} · rate ${forecast.rateText} · " +
                            "${forecast.landingStat.label} ${forecast.landingStat.value}",
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
            }
        }

        HorizontalDivider()
        Text("Live", style = MaterialTheme.typography.titleSmall)

        Button(
            onClick = {
                status = "Opening sign-in…"
                // The callback fires on the listener's own thread. Every branch
                // touches Compose state, so all of it is hopped onto the
                // composition's dispatcher (Main) rather than mutating snapshot
                // state off-thread.
                auth.start { result ->
                    scope.launch {
                        when (result) {
                            is AuthService.Result.Success -> {
                                if (repository.addAccount(result.tokens)) {
                                    status = "Signed in. Fetching…"
                                    refresh(context, repository, postCard = true) { p, message ->
                                        live = p; status = message
                                    }
                                } else {
                                    status = "Couldn't store the credential."
                                }
                            }
                            is AuthService.Result.Failure -> status = result.message
                            AuthService.Result.Cancelled -> status = "Sign-in cancelled."
                        }
                    }
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (repository.isSignedIn()) "Add another account" else "Sign in with Claude") }

        OutlinedButton(
            onClick = {
                status = "Fetching…"
                scope.launch {
                    refresh(context, repository, postCard = true) { p, message -> live = p; status = message }
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Poll now (real data)") }

        OutlinedButton(onClick = {
            repository.signOutAll()
            live = null
            status = "Signed out."
            LiveUpdateNotifier.cancel(context)
        }) { Text("Sign out") }

        HorizontalDivider()
        Text("Synthetic", style = MaterialTheme.typography.titleSmall)

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = {
                live = null
                synthetic = (synthetic - 5).coerceAtLeast(0.0)
                LiveUpdateNotifier.post(context, payload())
            }) { Text("−5%") }
            OutlinedButton(onClick = {
                live = null
                synthetic = (synthetic + 5).coerceAtMost(100.0)
                LiveUpdateNotifier.post(context, payload())
            }) { Text("+5%") }
            Text(
                "  ${synthetic.toInt()}%",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 14.dp),
            )
        }

        HorizontalDivider()
        Text("Card", style = MaterialTheme.typography.titleSmall)

        Button(
            onClick = { LiveUpdateNotifier.post(context, payload()) },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Post Live Update") }

        OutlinedButton(onClick = { LiveUpdateNotifier.cancel(context) }) { Text("Cancel card") }

        // The real path: the service's own notification IS the card, so starting
        // it is what a hot session will do on its own in the finished app.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = {
                SessionService.start(context)
                status = "Session service started — polling every " +
                    "${AppConfig.ACTIVE_POLL_SECONDS / 60} min."
            }) { Text("Start service") }
            OutlinedButton(onClick = {
                SessionService.stop(context)
                status = "Session service stopped."
            }) { Text("Stop service") }
        }

        OutlinedButton(onClick = {
            diagnostics = LiveUpdateNotifier.diagnose(context, payload())
        }) { Text("Refresh diagnostics") }

        OutlinedButton(onClick = {
            val intent = LiveUpdateNotifier.promotedNotificationSettingsIntent(context)
            diagnostics = if (intent == null) {
                "ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS resolves to nothing here —\n" +
                    "One UI has not wired AOSP's promoted-notification settings\n" +
                    "surface. Corroborates the two-pipeline theory."
            } else {
                context.startActivity(intent)
                "Opened promoted-notification settings. Note WHICH screen appeared:\n" +
                    "a per-app Live-notifications toggle means AOSP's surface is the\n" +
                    "gate; the generic screen means it isn't."
            }
        }) { Text("Open promoted-notification settings") }

        Card {
            Text(
                diagnostics,
                modifier = Modifier.padding(14.dp),
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

/**
 * One real poll, and — on success — the card it produces.
 *
 * Posting here rather than only from the button is the point of live mode: it
 * exercises the same path the foreground service will take in Phase 3, so what
 * appears on the lock screen is driven by the API rather than by a slider.
 *
 * Every failure keeps its own message. Collapsing them into "poll failed" would
 * hide the one distinction that matters to a user — a dead grant needs a new
 * sign-in, everything else just needs waiting.
 */
/**
 * Poll once and report the outcome as a message.
 *
 * @param postCard post the Live Update directly, bypassing every gate. **Only
 *   the diagnostics screen may pass true.** This function is top-level in the
 *   app package, so living in `SpikeActivity.kt` confines it to the debug
 *   harness by convention and not at all — it is called from four shipping
 *   Settings handlers, and it used to post unconditionally. That put a promoted
 *   card on screen for users who had set the card to Off, and re-posted one the
 *   user had just swiped away, which `CardDismissal` exists to make impossible
 *   because reposting a dismissed card is what costs an app its promotion
 *   permission. The card belongs to [SessionService]; everything else asks the
 *   service to repaint.
 */
internal suspend fun refresh(
    context: android.content.Context,
    repository: UsageRepository,
    postCard: Boolean = false,
    onResult: (UsagePayload?, String) -> Unit,
) {
    when (val result = repository.poll()) {
        is UsageRepository.PollResult.Success -> {
            if (postCard) LiveUpdateNotifier.post(context, result.payload)
            onResult(result.payload, "Updated ${result.payload.sessionUtilization.toInt()}%.")
        }
        UsageRepository.PollResult.SignedOut ->
            onResult(null, "Session expired — sign in again.")
        UsageRepository.PollResult.NoAccount ->
            onResult(null, "No account. Sign in first.")
        UsageRepository.PollResult.Stale ->
            onResult(null, "Account changed mid-poll; discarded.")
        is UsageRepository.PollResult.Failed -> onResult(
            null,
            result.retryAfterSeconds
                ?.let { "${result.message} Retry in ${it}s." }
                ?: result.message,
        )
    }
}
