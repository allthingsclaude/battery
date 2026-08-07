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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.live.LiveUpdateNotifier

/**
 * Phase 0 — the Now Bar spike.
 *
 * The only unverified thing in the whole plan is whether One UI 8.5 promotes a
 * third-party Live Update at all, and whether a *usage meter* survives Google's
 * "user-initiated journey" framing. Every other surface in this app is ordinary
 * Android work. So this screen does one thing: post a card built from a
 * synthetic payload and report exactly what the system thinks of it.
 *
 * Deliberately no auth, no network, no storage. One variable — if the card
 * doesn't reach the Now Bar, the cause is inside LiveUpdateNotifier and nowhere
 * else.
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
                Surface(modifier = Modifier.fillMaxSize()) {
                    SpikeScreen()
                }
            }
        }
    }
}

@androidx.compose.runtime.Composable
private fun SpikeScreen() {
    val context = LocalContext.current
    val base = remember { UsagePayload.PLACEHOLDER }
    var utilization by remember { androidx.compose.runtime.mutableDoubleStateOf(base.sessionUtilization) }
    var diagnostics by remember { mutableStateOf("Post the card, then refresh.") }
    var samsungExtras by remember { mutableStateOf(LiveUpdateNotifier.samsungExtrasEnabled) }

    fun payload() = base.copy(sessionUtilization = utilization)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Now Bar spike", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Session ${utilization.toInt()}% — synthetic payload, no network.",
            style = MaterialTheme.typography.bodyMedium,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = {
                utilization = (utilization - 5).coerceAtLeast(0.0)
                LiveUpdateNotifier.post(context, payload())
            }) { Text("−5%") }

            OutlinedButton(onClick = {
                utilization = (utilization + 5).coerceAtMost(100.0)
                LiveUpdateNotifier.post(context, payload())
            }) { Text("+5%") }
        }

        Button(
            onClick = { LiveUpdateNotifier.post(context, payload()) },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Post Live Update") }

        OutlinedButton(onClick = { LiveUpdateNotifier.cancel(context) }) { Text("Cancel") }

        // The A/B for the two-pipeline theory. One UI's Now Bar is driven by
        // Samsung's private ongoing-activity extras, not by the AOSP promoted
        // APIs we already satisfy — so post once with this off, once with it on,
        // and compare. Toggling it here avoids a rebuild between the two.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Switch(
                checked = samsungExtras,
                onCheckedChange = {
                    samsungExtras = it
                    LiveUpdateNotifier.samsungExtrasEnabled = it
                    LiveUpdateNotifier.post(context, payload())
                },
            )
            Text(
                "  Samsung ongoing-activity extras (experiment)",
                style = MaterialTheme.typography.bodySmall,
            )
        }

        OutlinedButton(onClick = {
            diagnostics = LiveUpdateNotifier.diagnose(context, payload())
        }) { Text("Refresh diagnostics") }

        // Which screen this lands on is itself the finding — see the KDoc on
        // LiveUpdateNotifier.promotedNotificationSettingsIntent.
        OutlinedButton(onClick = {
            val intent = LiveUpdateNotifier.promotedNotificationSettingsIntent(context)
            diagnostics = if (intent == null) {
                "ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS resolves to nothing on this\n" +
                    "device — One UI has not wired AOSP's promoted-notification\n" +
                    "settings surface. That corroborates the two-pipeline theory."
            } else {
                context.startActivity(intent)
                "Opened promoted-notification settings. Note WHICH screen appeared:\n" +
                    "a per-app Live-notifications toggle means AOSP's surface is the\n" +
                    "gate; the generic app-notification screen means it isn't."
            }
        }) { Text("Open promoted-notification settings") }

        Card {
            Text(
                diagnostics,
                modifier = Modifier.padding(14.dp),
                style = MaterialTheme.typography.bodySmall,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
            )
        }

        Text(
            "Check: Now Bar (lock screen), AOD, status-bar chip, shade collapsed " +
                "and expanded. FLAG_PROMOTED true = it reached the Now Bar.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
