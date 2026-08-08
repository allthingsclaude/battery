package com.allthingsclaude.battery.widget

import android.content.Context
import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.TextUnitType
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import android.content.ComponentName
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.allthingsclaude.battery.core.BatteryPalette
import com.allthingsclaude.battery.core.TimeFormatting
import com.allthingsclaude.battery.core.UsageForecast
import com.allthingsclaude.battery.core.UsageLevel
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.ui.UsageRingRenderer
import java.time.Instant
import kotlin.math.roundToInt

/**
 * The pieces every widget is assembled from, sized against the iOS originals in
 * `ios/BatteryWidgets/SessionWidget.swift` rather than guessed at.
 *
 * The density lesson from that file: iOS's medium widget is **not** three rings
 * side by side. It is one hero ring plus labelled progress-bar rows, which fits
 * far more per square inch and gives each window a percentage, a bar and a
 * reset. The first Android cut used three rings and looked mostly empty.
 */

/** Colours for one widget, from the system theme and that widget's own config. */
class WidgetPalette(systemIsDark: Boolean, val config: WidgetConfig) {

    val lightInk: Boolean = config.lightInk(systemIsDark)

    /**
     * The surface at the configured opacity. At 0 this is fully transparent, and
     * the ink still has to be legible against whatever wallpaper is behind it —
     * which is why the ink is a user choice rather than derived from this.
     */
    val surface: ColorProvider = ColorProvider(
        Color(if (lightInk) BatteryPalette.SURFACE_DARK else BatteryPalette.SURFACE_LIGHT)
            .copy(alpha = config.opacity)
    )

    val onSurface = ColorProvider(Color(if (lightInk) 0xFFF2EFE9.toInt() else 0xFF1C1B18.toInt()))
    val muted = ColorProvider(Color(if (lightInk) 0xFFB9B4AB.toInt() else 0xFF6E6A62.toInt()))
    val track = ColorProvider(if (lightInk) Color(0x33FFFFFF) else Color(0x1F000000))
}

/**
 * The palette for the widget currently being composed.
 *
 * `LocalGlanceId` identifies it, but the numeric `appWidgetId` the config is
 * keyed by is only reachable through `GlanceAppWidgetManager`, which is a
 * suspend call — so the id is resolved in `provideGlance` and handed down.
 */
@Composable
fun paletteFor(config: WidgetConfig): WidgetPalette {
    val night = LocalContext.current.resources.configuration.uiMode and
        Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    return WidgetPalette(night, config)
}

fun Int.sp(): TextUnit = TextUnit(this.toFloat(), TextUnitType.Sp)

@Composable
private fun ringImage(utilization: Double, sizeDp: Int, palette: WidgetPalette, showLabel: Boolean = true) =
    ImageProvider(
        UsageRingRenderer.renderForDp(
            utilization,
            sizeDp,
            LocalContext.current.resources.displayMetrics.density,
            palette.lightInk,
            showLabel,
        )
    )

/**
 * Every widget's outer frame: fills the cell, paints (or doesn't), pads once,
 * and opens the app when tapped.
 *
 * The click lives here rather than on each layout so no widget can ship without
 * it — a widget that does nothing when tapped reads as broken, and the first cut
 * of all four did exactly that.
 */
@Composable
private fun Frame(palette: WidgetPalette, padding: Int = 8, content: @Composable () -> Unit) {
    Box(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(palette.surface)
            .clickable(actionStartActivity(ComponentName(
                LocalContext.current.packageName,
                "com.allthingsclaude.battery.MainActivity",
            )))
            .padding(padding.dp),
        contentAlignment = Alignment.Center,
    ) { content() }
}

@Composable
fun EmptyState(palette: WidgetPalette, compact: Boolean) {
    Frame(palette) {
        Column(horizontalAlignment = Alignment.Horizontal.CenterHorizontally) {
            Text("Open Battery", style = TextStyle(color = palette.onSurface, fontWeight = FontWeight.Medium))
            if (!compact) {
                Text("to sync your usage", style = TextStyle(color = palette.muted, fontSize = 11.sp()))
            }
        }
    }
}

fun resetText(resetsAt: Instant?): String? = resetsAt?.let {
    TimeFormatting.untilReset((it.epochSecond - Instant.now().epochSecond).toDouble())
}

/** Ports the desktop `ProgressBarView` — the row form iOS's medium widget uses. */
@Composable
private fun WindowRow(
    palette: WidgetPalette,
    title: String,
    utilization: Double,
    reset: String?,
) {
    Column(modifier = GlanceModifier.fillMaxWidth()) {
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            Text(
                title.uppercase(),
                style = TextStyle(color = palette.muted, fontSize = 10.sp()),
                modifier = GlanceModifier.defaultWeight(),
            )
            Text(
                "${utilization.roundToInt()}%",
                style = TextStyle(
                    color = ColorProvider(Color(UsageLevel.from(utilization).color)),
                    fontWeight = FontWeight.Bold,
                    fontSize = 14.sp(),
                ),
            )
        }
        Spacer(GlanceModifier.height(4.dp))
        Bar(palette, utilization)
        reset?.let {
            Spacer(GlanceModifier.height(3.dp))
            Text(it, style = TextStyle(color = palette.muted, fontSize = 10.sp()), maxLines = 1)
        }
    }
}

/**
 * The bar.
 *
 * An earlier version built this from two `defaultWeight()` boxes, which splits
 * the row 50/50 no matter what the value is — every bar rendered as exactly
 * half full. Glance has a real primitive for this; weights cannot express a
 * fraction.
 */
@Composable
private fun Bar(palette: WidgetPalette, utilization: Double) {
    LinearProgressIndicator(
        progress = (utilization / 100.0).coerceIn(0.0, 1.0).toFloat(),
        modifier = GlanceModifier.fillMaxWidth().height(6.dp),
        color = ColorProvider(Color(UsageLevel.from(utilization).color)),
        backgroundColor = palette.track,
    )
}

// ── Layouts ─────────────────────────────────────────────────────────────────

/**
 * 4x1. Ring, big percentage, one line of context, weekly on the right.
 *
 * The ring drops its centre numeral: one cell of height leaves ~38dp, and digits
 * inside a 38dp ring are a smudge. The percentage moves out beside it at 20sp,
 * where it actually reads — which is also why this shape has *less* whitespace
 * than the first attempt, not more.
 */
@Composable
fun RowLayout(payload: UsagePayload, palette: WidgetPalette) {
    val level = UsageLevel.from(payload.sessionUtilization)
    Frame(palette, padding = 6) {
        Row(
            modifier = GlanceModifier.fillMaxSize(),
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            Image(
                provider = ringImage(payload.sessionUtilization, 40, palette, showLabel = false),
                contentDescription = null,
                modifier = GlanceModifier.size(40.dp),
            )
            Spacer(GlanceModifier.width(10.dp))
            Column(modifier = GlanceModifier.defaultWeight()) {
                Text(
                    "${payload.sessionUtilization.roundToInt()}%",
                    style = TextStyle(
                        color = ColorProvider(Color(level.color)),
                        fontWeight = FontWeight.Bold,
                        fontSize = 20.sp(),
                    ),
                )
                Text(
                    resetText(payload.sessionResetsAt)?.let { "resets in $it" } ?: "no window",
                    style = TextStyle(color = palette.muted, fontSize = 11.sp()),
                    maxLines = 1,
                )
            }
            Column(horizontalAlignment = Alignment.Horizontal.End) {
                Text("WEEK", style = TextStyle(color = palette.muted, fontSize = 9.sp()))
                Text(
                    "${payload.weeklyUtilization.roundToInt()}%",
                    style = TextStyle(
                        color = ColorProvider(Color(UsageLevel.from(payload.weeklyUtilization).color)),
                        fontWeight = FontWeight.Bold,
                        fontSize = 15.sp(),
                    ),
                )
            }
        }
    }
}

/**
 * 2x2 — a direct port of iOS's `SmallGaugeView`: label on top, hero ring, reset
 * underneath. The ring is 92dp, matching the 92pt iOS uses, which is what makes
 * it fill the tile instead of floating in it.
 */
@Composable
fun RingLayout(palette: WidgetPalette, title: String, utilization: Double, caption: String?, active: Boolean) {
    Frame(palette, padding = 6) {
        Column(horizontalAlignment = Alignment.Horizontal.CenterHorizontally) {
            Row(verticalAlignment = Alignment.Vertical.CenterVertically) {
                Text(title.uppercase(), style = TextStyle(color = palette.muted, fontSize = 10.sp()))
                if (active) {
                    Spacer(GlanceModifier.width(4.dp))
                    Text("●", style = TextStyle(
                        color = ColorProvider(Color(BatteryPalette.BRAND)),
                        fontSize = 8.sp(),
                    ))
                }
            }
            Spacer(GlanceModifier.height(6.dp))
            Image(
                provider = ringImage(utilization, 92, palette),
                contentDescription = null,
                modifier = GlanceModifier.size(92.dp),
            )
            caption?.let {
                Spacer(GlanceModifier.height(6.dp))
                Text(it, style = TextStyle(color = palette.muted, fontSize = 11.sp()), maxLines = 1)
            }
        }
    }
}

/**
 * 4x2 — a port of iOS's `MediumOverviewView`: the session ring as the hero on
 * the left, weekly and Opus as labelled bar rows on the right.
 *
 * At one cell of height it degrades to bars only. Three rings side by side was
 * the first attempt and it wasted most of the tile.
 */
@Composable
fun OverviewLayout(payload: UsagePayload, palette: WidgetPalette, short: Boolean) {
    Frame(palette, padding = if (short) 8 else 12) {
        if (short) {
            Row(
                modifier = GlanceModifier.fillMaxSize(),
                verticalAlignment = Alignment.Vertical.CenterVertically,
            ) {
                Column(modifier = GlanceModifier.defaultWeight()) {
                    WindowRow(palette, "Session", payload.sessionUtilization, null)
                }
                Spacer(GlanceModifier.width(12.dp))
                Column(modifier = GlanceModifier.defaultWeight()) {
                    WindowRow(palette, "Weekly", payload.weeklyUtilization, null)
                }
            }
            return@Frame
        }

        Row(
            modifier = GlanceModifier.fillMaxSize(),
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            Column(horizontalAlignment = Alignment.Horizontal.CenterHorizontally) {
                Text("SESSION", style = TextStyle(color = palette.muted, fontSize = 10.sp()))
                Spacer(GlanceModifier.height(5.dp))
                Image(
                    provider = ringImage(payload.sessionUtilization, 88, palette),
                    contentDescription = null,
                    modifier = GlanceModifier.size(88.dp),
                )
                resetText(payload.sessionResetsAt)?.let {
                    Spacer(GlanceModifier.height(5.dp))
                    Text(it, style = TextStyle(color = palette.muted, fontSize = 10.sp()), maxLines = 1)
                }
            }
            Spacer(GlanceModifier.width(16.dp))
            Column(modifier = GlanceModifier.defaultWeight()) {
                WindowRow(palette, "Weekly", payload.weeklyUtilization, resetText(payload.weeklyResetsAt))
                payload.opusUtilization?.let {
                    Spacer(GlanceModifier.height(12.dp))
                    WindowRow(palette, payload.scopedTitle, it, null)
                }
            }
        }
    }
}

/** 4x2 — where the window is heading, in `UsageForecast`'s own words. */
@Composable
fun ForecastLayout(payload: UsagePayload, palette: WidgetPalette) {
    val forecast = UsageForecast(payload)
    Frame(palette, padding = 12) {
        Row(
            modifier = GlanceModifier.fillMaxSize(),
            verticalAlignment = Alignment.Vertical.CenterVertically,
        ) {
            Image(
                provider = ringImage(payload.sessionUtilization, 84, palette),
                contentDescription = null,
                modifier = GlanceModifier.size(84.dp),
            )
            Spacer(GlanceModifier.width(14.dp))
            Column(modifier = GlanceModifier.defaultWeight()) {
                Text(
                    forecast.badgeLabel.uppercase(),
                    style = TextStyle(
                        color = ColorProvider(Color(forecast.tintColor)),
                        fontSize = 10.sp(),
                        fontWeight = FontWeight.Bold,
                    ),
                )
                Spacer(GlanceModifier.height(3.dp))
                Text(
                    forecast.headline,
                    style = TextStyle(color = palette.onSurface, fontWeight = FontWeight.Medium, fontSize = 15.sp()),
                    maxLines = 2,
                )
                Spacer(GlanceModifier.height(6.dp))
                Bar(palette, payload.sessionUtilization)
                Spacer(GlanceModifier.height(6.dp))
                Text(
                    "${forecast.landingStat.label} ${forecast.landingStat.value}   ·   pace ${forecast.rateText}",
                    style = TextStyle(color = palette.muted, fontSize = 11.sp()),
                    maxLines = 1,
                )
            }
        }
    }
}
