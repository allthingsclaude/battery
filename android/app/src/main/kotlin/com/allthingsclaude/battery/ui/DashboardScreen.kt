package com.allthingsclaude.battery.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.allthingsclaude.battery.core.TimeFormatting
import com.allthingsclaude.battery.core.UsageForecast
import com.allthingsclaude.battery.core.UsageLevel
import com.allthingsclaude.battery.core.UsagePayload
import java.time.Instant
import kotlin.math.roundToInt

/**
 * The main screen. A port of the iOS dashboard's information architecture:
 * session ring first, weekly and Opus beside it, then the forecast.
 *
 * Every word about the projection comes from [UsageForecast], never from local
 * formatting — that is the whole reason the type exists, and the Live Update
 * once drifted away from it precisely because a "temporary" local helper was
 * left in place.
 */
@Composable
fun DashboardScreen(
    payload: UsagePayload,
    now: Instant = Instant.now(),
    modifier: Modifier = Modifier,
) {
    val forecast = UsageForecast(payload, now = now)

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Header(payload)

        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            UsageRing(
                utilization = payload.sessionUtilization,
                size = 168.dp,
                caption = "5-hour session",
            )
        }

        ResetLine(payload.sessionResetsAt, now)

        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            SecondaryWindow(
                label = "Weekly",
                utilization = payload.weeklyUtilization,
                resetsAt = payload.weeklyResetsAt,
                now = now,
                modifier = Modifier.weight(1f),
            )
            // Most accounts have no Opus bucket. Showing an empty gauge would
            // imply a limit that doesn't exist for them, so it's simply absent.
            payload.opusUtilization?.let {
                SecondaryWindow(
                    label = "Opus",
                    utilization = it,
                    resetsAt = payload.weeklyResetsAt,
                    now = now,
                    modifier = Modifier.weight(1f),
                )
            }
        }

        ForecastCard(forecast)
    }
}

@Composable
private fun Header(payload: UsagePayload) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column {
            Text(payload.accountName, style = MaterialTheme.typography.titleMedium)
            if (payload.planTier.isNotEmpty()) {
                Text(
                    payload.planTier,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                )
            }
        }
        Text(
            // A live "updated Xm ago" rather than a timestamp, so a stale screen
            // is honest about being stale instead of showing a plausible time.
            TimeFormatting.relativeTime(payload.updatedAt),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        )
    }
}

@Composable
private fun ResetLine(resetsAt: Instant?, now: Instant) {
    val text = resetsAt
        ?.let { "Resets in ${TimeFormatting.shortDuration((it.epochSecond - now.epochSecond).toDouble())}" }
        ?: "No session window open"
    Text(
        text,
        modifier = Modifier.fillMaxWidth(),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
    )
}

@Composable
private fun SecondaryWindow(
    label: String,
    utilization: Double,
    resetsAt: Instant?,
    now: Instant,
    modifier: Modifier = Modifier,
) {
    val level = UsageLevel.from(utilization)
    Card(modifier = modifier, colors = CardDefaults.cardColors()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                label.uppercase(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
            )
            Text(
                "${utilization.roundToInt()}%",
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                style = MaterialTheme.typography.headlineSmall,
                color = Color(level.color),
            )
            ProgressBar(utilization)
            resetsAt?.let {
                Text(
                    TimeFormatting.shortDuration((it.epochSecond - now.epochSecond).toDouble()),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                )
            }
        }
    }
}

/** Ports the desktop `ProgressBarView`. */
@Composable
private fun ProgressBar(utilization: Double, projected: Double? = null) {
    val level = UsageLevel.from(utilization)
    Box(
        Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(RoundedCornerShape(4.dp))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)),
    ) {
        // The projection first, so the solid "spent" fill draws over it — the
        // translucent extension has to read as "not yet spent", not as a second
        // metric competing with the first.
        projected?.let {
            Box(
                Modifier
                    .fillMaxWidth((it / 100.0).coerceIn(0.0, 1.0).toFloat())
                    .height(8.dp)
                    .background(Color(UsageLevel.from(it).color).copy(alpha = 0.28f)),
            )
        }
        Box(
            Modifier
                .fillMaxWidth((utilization / 100.0).coerceIn(0.0, 1.0).toFloat())
                .height(8.dp)
                .background(Color(level.color)),
        )
    }
}

@Composable
private fun ForecastCard(forecast: UsageForecast) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("FORECAST", style = MaterialTheme.typography.labelSmall)
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
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                )
            }

            // The bar carries the projection as a translucent extension of what's
            // already spent — the same idea the Live Update expresses with a
            // ProgressStyle Point.
            ProgressBar(forecast.utilization, forecast.projectedAtReset)

            Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                Stat("PACE", forecast.rateText)
                Stat(forecast.landingStat.label.uppercase(), forecast.landingStat.value)
            }
        }
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
