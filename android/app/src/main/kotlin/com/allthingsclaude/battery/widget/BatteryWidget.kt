package com.allthingsclaude.battery.widget

import android.content.Context
import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import androidx.compose.ui.graphics.Color
import com.allthingsclaude.battery.core.BatteryPalette
import com.allthingsclaude.battery.core.TimeFormatting
import com.allthingsclaude.battery.core.UsageForecast
import com.allthingsclaude.battery.core.UsageLevel
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.data.PayloadStore
import com.allthingsclaude.battery.ui.UsageRingRenderer
import java.time.Instant
import kotlin.math.roundToInt

/**
 * The Home Screen widget.
 *
 * Reads the shared payload and nothing else. On iOS the widget extension is a
 * separate process that has to self-fetch from the network with a mirrored
 * access token — a real security trade-off documented in `SharedStore`. Here the
 * widget runs in the app's process and simply reads what the service already
 * wrote, so no credential is ever copied anywhere.
 *
 * Two size buckets rather than iOS's four families: Android widgets resize
 * continuously, so [SizeMode.Responsive] with a small and a wide layout covers
 * the space better than fixed families would.
 */
class BatteryWidget : GlanceAppWidget() {

    override val sizeMode = SizeMode.Responsive(setOf(SMALL, WIDE))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        // Read before provideContent so the first composition already has data;
        // loading inside would flash the placeholder on every update.
        val payload = PayloadStore(context).load()
        provideContent {
            GlanceTheme {
                WidgetBody(payload)
            }
        }
    }

    companion object {
        val SMALL = DpSize(110.dp, 110.dp)
        val WIDE = DpSize(250.dp, 110.dp)
    }
}

@Composable
private fun WidgetBody(payload: UsagePayload?) {
    val context = LocalContext.current
    val dark = context.resources.configuration.uiMode and
        Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    val background = ColorProvider(
        Color(if (dark) BatteryPalette.SURFACE_DARK else BatteryPalette.SURFACE_LIGHT)
    )
    val onBackground = ColorProvider(Color(if (dark) 0xFFF2EFE9.toInt() else 0xFF1C1B18.toInt()))

    if (payload == null) {
        // Honest empty state rather than invented numbers. A widget that has
        // never been given data must not imply a reading.
        Column(
            modifier = GlanceModifier.fillMaxSize().background(background).padding(12.dp),
            verticalAlignment = Alignment.Vertical.CenterVertically,
            horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
        ) {
            Text(
                "Open Battery",
                style = TextStyle(color = onBackground, fontWeight = FontWeight.Medium),
            )
            Text(
                "to sync your usage",
                style = TextStyle(color = onBackground, fontSize = 11.sp()),
            )
        }
        return
    }

    val wide = LocalSize.current.width >= BatteryWidget.WIDE.width
    val density = context.resources.displayMetrics.density
    val ringDp = if (wide) 84 else 76

    // Glance cannot draw an arc, so the ring is rasterised. Sized in pixels from
    // the real display density — passing dp would be correct on one device only.
    val ring = ImageProvider(
        UsageRingRenderer.renderForDp(payload.sessionUtilization, ringDp, density, dark)
    )

    if (wide) {
        Row(
            modifier = GlanceModifier.fillMaxSize().background(background).padding(12.dp),
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            Image(provider = ring, contentDescription = null, modifier = GlanceModifier.size(ringDp.dp))
            Spacer(GlanceModifier.size(12.dp))
            Column {
                Text(
                    "Session",
                    style = TextStyle(color = onBackground, fontSize = 11.sp()),
                )
                Text(
                    UsageForecast(payload).headline,
                    style = TextStyle(color = onBackground, fontWeight = FontWeight.Medium),
                )
                Spacer(GlanceModifier.height(4.dp))
                Text(
                    "Weekly ${payload.weeklyUtilization.roundToInt()}%",
                    style = TextStyle(
                        color = ColorProvider(Color(UsageLevel.from(payload.weeklyUtilization).color)),
                        fontSize = 12.sp(),
                    ),
                )
            }
        }
    } else {
        Column(
            modifier = GlanceModifier.fillMaxSize().background(background).padding(8.dp),
            verticalAlignment = Alignment.Vertical.CenterVertically,
            horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
        ) {
            Image(provider = ring, contentDescription = null, modifier = GlanceModifier.size(ringDp.dp))
            Spacer(GlanceModifier.height(4.dp))
            Text(
                payload.sessionResetsAt
                    ?.let { TimeFormatting.shortDuration((it.epochSecond - Instant.now().epochSecond).toDouble()) }
                    ?: "No window",
                style = TextStyle(color = onBackground, fontSize = 11.sp()),
            )
        }
    }
}

/** Glance text sizes are TextUnit; this keeps the call sites readable. */
private fun Int.sp() = androidx.compose.ui.unit.TextUnit(
    this.toFloat(),
    androidx.compose.ui.unit.TextUnitType.Sp,
)

class BatteryWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BatteryWidget()
}
