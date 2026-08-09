package com.allthingsclaude.battery.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.allthingsclaude.battery.live.NowBarGate
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.allthingsclaude.battery.core.SessionPolicy
import com.allthingsclaude.battery.core.TimeFormatting
import com.allthingsclaude.battery.core.UsageForecast
import com.allthingsclaude.battery.core.UsageLevel
import com.allthingsclaude.battery.core.UsagePayload
import java.time.Instant
import kotlin.math.roundToInt

/**
 * A port of `ios/BatteryApp/DashboardView.swift`'s information architecture:
 * header, session hero card, forecast card, weekly/Opus card.
 *
 * Three things the first Android cut got wrong, all of which read as "empty":
 *  - the ring floated on the background instead of sitting in a card with a
 *    section label and a level badge, so the top third was mostly nothing;
 *  - it was 200dp. iOS uses 148, and the smaller ring leaves room for content
 *    rather than for whitespace;
 *  - weekly came before the forecast. iOS puts the forecast second because
 *    "am I going to run out" is the question the screen exists to answer.
 *
 * Every word about the projection comes from [UsageForecast]. That is the whole
 * reason the type exists, and the Live Update already drifted away from it once.
 */
@Composable
fun DashboardScreen(
    payload: UsagePayload,
    cardMode: SessionPolicy.Mode,
    now: Instant = Instant.now(),
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
            .padding(top = 8.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        NowBarBanner()
        SessionCard(payload, now)
        ForecastCard(UsageForecast(payload, now = now))
        WeeklyCard(payload, now)
        ExtraUsageCard(payload)
        CardNote(cardMode)
    }
}

/** The shared card chrome — ports `batteryCard()` from `BatteryDesign.swift`. */
@Composable
private fun BatteryCard(
    padding: Int = 16,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f))
            .border(
                1.dp,
                MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f),
                RoundedCornerShape(22.dp),
            )
            .padding(padding.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        letterSpacing = 0.8.sp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f),
    )
}

/**
 * The one top bar, shared by the dashboard and settings.
 *
 * Owned by the host rather than drawn by each screen. When the dashboard drew
 * its own header there were two stacked rows — a bare gear above, the title
 * below — so the two screens could only be aligned by keeping two sets of
 * paddings in step. One bar makes them aligned by construction.
 *
 * [trailing] is the screen's own action (gear, or close).
 */
@Composable
fun AppHeader(
    title: String,
    payload: UsagePayload?,
    modifier: Modifier = Modifier,
    trailing: @Composable () -> Unit,
) {
    Row(
        modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.headlineMedium)
            payload?.let {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    if (it.planTier.isNotEmpty()) {
                        Text(
                            it.planTier,
                            Modifier
                                .clip(RoundedCornerShape(50))
                                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.16f))
                                .padding(horizontal = 8.dp, vertical = 2.dp),
                            style = MaterialTheme.typography.labelSmall,
                            color = BatteryColors.brandDark,
                        )
                    }
                    Text(
                        it.accountName,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                        maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    )
                }
            }
        }
        payload?.let { StatusPill(it) }
        trailing()
    }
}

@Composable
private fun StatusPill(payload: UsagePayload) {
    Column(
        horizontalAlignment = Alignment.End,
        modifier = Modifier.padding(end = 4.dp),
    ) {
        Row(
            Modifier
                .clip(RoundedCornerShape(50))
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f))
                .padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (payload.isSessionActive) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(BatteryColors.brand))
                Text("Active", style = MaterialTheme.typography.labelSmall, color = BatteryColors.brandDark)
            } else {
                Text(
                    "Idle",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                )
            }
        }
        Text(
            // "updated 4m ago", not a timestamp — a stale screen should look
            // stale rather than plausible.
            TimeFormatting.relativeTime(payload.updatedAt),
            Modifier.padding(top = 4.dp),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
        )
    }
}

@Composable
private fun SessionCard(payload: UsagePayload, now: Instant) {
    BatteryCard(padding = 18) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            SectionLabel("Session · 5-hour")
            LevelBadge(UsageLevel.from(payload.sessionUtilization))
        }
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            UsageRing(payload.sessionUtilization, size = 148.dp, caption = "used")
        }
        Text(
            payload.sessionResetsAt
                ?.let { TimeFormatting.untilReset((it.epochSecond - now.epochSecond).toDouble()) }
                ?.let { "Resets in $it" }
                ?: "No active session",
            Modifier.fillMaxWidth(),
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.65f),
        )
    }
}

@Composable
private fun LevelBadge(level: UsageLevel) {
    Text(
        level.label,
        Modifier
            .clip(RoundedCornerShape(50))
            .background(Color(level.color).copy(alpha = 0.16f))
            .padding(horizontal = 8.dp, vertical = 2.dp),
        style = MaterialTheme.typography.labelSmall,
        color = Color(level.color),
    )
}

@Composable
private fun ForecastCard(forecast: UsageForecast) {
    BatteryCard {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            SectionLabel("Forecast")
            Text(
                forecast.badgeLabel,
                style = MaterialTheme.typography.labelMedium,
                color = Color(forecast.tintColor),
            )
        }
        Text(forecast.headline, style = MaterialTheme.typography.titleMedium)
        forecast.detail?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.65f),
            )
        }
        // The projection as a translucent extension of what's already spent —
        // the same idea the Live Update expresses with a ProgressStyle Point.
        ProgressBar(forecast.utilization, forecast.projectedAtReset)
        Row(horizontalArrangement = Arrangement.spacedBy(28.dp)) {
            Stat("PACE", forecast.rateText)
            Stat(forecast.landingStat.label.uppercase(), forecast.landingStat.value)
            forecast.sustainableRatePerHour?.let {
                Stat("ROOM", TimeFormatting.rate(it))
            }
        }
    }
}

@Composable
private fun WeeklyCard(payload: UsagePayload, now: Instant) {
    BatteryCard {
        BarRow(
            "Weekly · 7-day",
            payload.weeklyUtilization,
            payload.weeklyResetsAt?.let {
                TimeFormatting.untilReset((it.epochSecond - now.epochSecond).toDouble())
            },
        )
        // Most accounts have no model-scoped bucket; an empty row would imply a
        // limit they don't have. The heading comes from the API, not from here —
        // it was hardcoded "Opus" and the live answer is now "Fable".
        payload.opusUtilization?.let {
            HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
            BarRow("${payload.scopedTitle} · 7-day", it, null)
        }
    }
}

/**
 * Pay-as-you-go credits, when the account has them.
 *
 * Absent for most accounts, and drawn only when the API says it is enabled and
 * has a limit — an "Extra usage" heading over an empty bar would imply a billing
 * arrangement the reader does not have.
 *
 * Android was the only client not showing this. macOS has parsed and rendered it
 * since `ExtraUsageView`, so the money spent past the plan was visible on a Mac
 * and invisible on the phone that shows everything else about the same account.
 */
@Composable
private fun ExtraUsageCard(payload: UsagePayload) {
    val extra = payload.extraUsage ?: return
    if (!extra.isPresentable) return

    val used = extra.format(extra.used) ?: return
    val limit = extra.format(extra.limit) ?: return
    val utilization = extra.utilization ?: 0.0

    BatteryCard {
        BarRow("Extra usage · monthly", utilization, null)
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                "$used of $limit",
                style = MaterialTheme.typography.labelMedium,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
            )
            extra.format(extra.remaining)?.let {
                Text(
                    "$it left",
                    style = MaterialTheme.typography.labelMedium,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
                )
            }
        }
    }
}

@Composable
private fun BarRow(title: String, utilization: Double, reset: String?) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Bottom,
        ) {
            SectionLabel(title)
            Text(
                "${utilization.roundToInt()}%",
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                style = MaterialTheme.typography.titleMedium,
                color = Color(UsageLevel.from(utilization).color),
            )
        }
        ProgressBar(utilization)
        reset?.let {
            Text(
                "Resets in $it",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
            )
        }
    }
}

/** Ports the desktop `ProgressBarView`. */
@Composable
private fun ProgressBar(utilization: Double, projected: Double? = null) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(RoundedCornerShape(4.dp))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.10f)),
    ) {
        // Projection first, so the solid "spent" fill draws over it: the
        // translucent extension must read as "not yet spent", not as a second
        // metric competing with the first.
        projected?.let {
            Box(
                Modifier
                    .fillMaxWidth((it / 100.0).coerceIn(0.0, 1.0).toFloat())
                    .height(8.dp)
                    .background(Color(UsageLevel.from(it).color).copy(alpha = 0.30f)),
            )
        }
        Box(
            Modifier
                .fillMaxWidth((utilization / 100.0).coerceIn(0.0, 1.0).toFloat())
                .height(8.dp)
                .clip(RoundedCornerShape(4.dp))
                .background(Color(UsageLevel.from(utilization).color)),
        )
    }
}

@Composable
private fun Stat(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        )
        Text(
            value,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

/**
 * A quiet line explaining when the lock-screen card appears — the same job as
 * iOS's `liveActivityNote`.
 *
 * It is here because the behaviour is genuinely non-obvious: in SMART the card
 * can be absent while the app shows 7%, and without a word of explanation that
 * reads as the feature being broken rather than as it working as configured.
 */
@Composable
private fun CardNote(mode: SessionPolicy.Mode) {
    Text(
        when (mode) {
            SessionPolicy.Mode.OFF ->
                "The lock-screen card is off. Turn it on in Settings."
            SessionPolicy.Mode.SMART ->
                "The lock-screen card appears once you've used an open session, and goes after a long idle."
            SessionPolicy.Mode.WHENEVER_OPEN ->
                "The lock-screen card stays up for the whole 5-hour window."
        },
        Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
        style = MaterialTheme.typography.labelMedium,
        textAlign = TextAlign.Center,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
    )
}

/**
 * Shown only when Samsung's gate is closed.
 *
 * Dismissible and remembered, because it is advice rather than an error: the app
 * works without it — the lock-screen card, the shade ranking and every widget
 * are unaffected — and a permanent banner for an optional surface would be
 * nagging. It reappears if the gate is still closed on a later install, which is
 * the only case where it's worth saying again.
 */
@Composable
private fun NowBarBanner() {
    val context = LocalContext.current
    val state = remember { NowBarGate.state(context) }
    val advice = NowBarGate.advice(state) ?: return

    var dismissed by remember {
        mutableStateOf(
            context.getSharedPreferences("banners", android.content.Context.MODE_PRIVATE)
                .getBoolean("nowbar_dismissed", false)
        )
    }
    if (dismissed) return

    BatteryCard(padding = 14) {
        Text(advice.title, style = MaterialTheme.typography.titleSmall)
        Text(
            advice.body,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = {
                NowBarGate.settingsIntent(state)?.let(context::startActivity)
            }) { Text(advice.action) }
            TextButton(onClick = {
                dismissed = true
                context.getSharedPreferences("banners", android.content.Context.MODE_PRIVATE)
                    .edit().putBoolean("nowbar_dismissed", true).apply()
            }) {
                Text("Not now", color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
            }
        }
    }
}
