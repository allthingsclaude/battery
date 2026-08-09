package com.allthingsclaude.battery.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import com.allthingsclaude.battery.core.BatteryPalette
import com.allthingsclaude.battery.core.TimeFormatting
import com.allthingsclaude.battery.core.UsageLevel
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.data.PayloadStore
import com.allthingsclaude.battery.ui.BatteryTheme
import com.allthingsclaude.battery.ui.UsageRingRenderer
import kotlinx.coroutines.launch
import java.time.Instant
import kotlin.math.roundToInt

/**
 * The widget's own settings, reached from the gear on the widget itself.
 *
 * This exists because per-widget appearance belongs *on* the widget, not buried
 * in the app: a gear on this widget should change this widget. Wiring it up is
 * two manifest attributes — `android:configure` names this activity, and
 * `widgetFeatures="reconfigurable"` is what makes the gear appear after
 * placement rather than only at it.
 *
 * `RESULT_CANCELED` is set first and only replaced on Save. If the user backs
 * out during *initial* placement, the launcher takes that as "don't place it" —
 * which is the correct behaviour and the reason the default result matters.
 */
class WidgetConfigActivity : ComponentActivity() {

    private var appWidgetId = WidgetConfig.INVALID_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        appWidgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            WidgetConfig.INVALID_ID,
        ) ?: WidgetConfig.INVALID_ID

        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))

        if (appWidgetId == WidgetConfig.INVALID_ID) {
            finish()
            return
        }

        setContent {
            BatteryTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    // Compose does not inset by default; without this the title
                    // draws over the system clock.
                    Box(Modifier.windowInsetsPadding(WindowInsets.systemBars)) {
                    ConfigScreen(
                        initial = WidgetConfig.load(this@WidgetConfigActivity, appWidgetId),
                        onCancel = { finish() },
                        onSave = { config -> save(config) },
                    )
                    }
                }
            }
        }
    }

    private fun save(config: WidgetConfig) {
        WidgetConfig.save(this, appWidgetId, config)
        lifecycleScope.launch {
            // Repaint immediately. Without this the widget keeps its old
            // appearance until the next poll, which can be minutes away and
            // reads as the setting having done nothing.
            refreshAllWidgets(this@WidgetConfigActivity)
            setResult(
                RESULT_OK,
                Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId),
            )
            finish()
        }
    }
}

@Composable
private fun ConfigScreen(
    initial: WidgetConfig,
    onCancel: () -> Unit,
    onSave: (WidgetConfig) -> Unit,
) {
    val context = LocalContext.current
    var opacity by remember { mutableFloatStateOf(initial.opacity) }
    var colors by remember { mutableStateOf(initial.colors) }

    // Real data where there is some — a preview showing invented numbers would
    // be a worse guide to what the widget will actually look like.
    val payload = remember { PayloadStore(context).load() ?: UsagePayload.PLACEHOLDER }
    val systemDark = isSystemInDarkTheme()
    val config = WidgetConfig(opacity, colors)

    Column(Modifier.fillMaxSize().padding(20.dp)) {
        Text("Widget settings", style = MaterialTheme.typography.headlineSmall)

        Preview(payload, config, systemDark, Modifier.padding(top = 20.dp))

        Column(
            Modifier
                .padding(top = 20.dp)
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text("Opacity", style = MaterialTheme.typography.titleMedium)
            Row(verticalAlignment = Alignment.CenterVertically) {
                // The checkerboard is the conventional "transparent" marker at
                // the zero end of an opacity control.
                Checkerboard(Modifier.size(26.dp))
                Slider(
                    value = opacity,
                    onValueChange = { opacity = it },
                    modifier = Modifier.padding(start = 10.dp),
                )
            }

            Text(
                "Colors",
                Modifier.padding(top = 10.dp),
                style = MaterialTheme.typography.titleMedium,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                WidgetConfig.Colors.entries.forEach { option ->
                    FilterChip(
                        selected = option == colors,
                        onClick = { colors = option },
                        label = { Text(option.title) },
                    )
                }
            }
            if (colors == WidgetConfig.Colors.AUTO) {
                Text(
                    "Auto follows light/dark mode — which isn't your wallpaper. " +
                        "On a transparent widget over a dark wallpaper, pick Dark.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                )
            }
        }

        Box(Modifier.weight(1f))

        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally),
        ) {
            TextButton(onClick = onCancel) { Text("Cancel") }
            Button(onClick = { onSave(config) }) { Text("Save") }
        }
    }
}

/**
 * A live preview of the row layout at the chosen settings, over a checkerboard
 * so partial opacity is actually visible — against a solid background, 40% and
 * 100% look nearly identical.
 */
@Composable
private fun Preview(
    payload: UsagePayload,
    config: WidgetConfig,
    systemDark: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lightInk = config.lightInk(systemDark)
    val base = if (lightInk) BatteryPalette.SURFACE_DARK else BatteryPalette.SURFACE_LIGHT
    val ink = if (lightInk) Color(0xFFF2EFE9) else Color(0xFF1C1B18)
    val muted = ink.copy(alpha = 0.6f)
    val level = UsageLevel.from(payload.sessionUtilization)

    Box(
        modifier
            .fillMaxWidth()
            .aspectRatio(2.6f)
            .clip(RoundedCornerShape(24.dp))
            // An outline so the preview reads as a widget at 100% opacity, where
            // its surface is exactly the colour of the page behind it and it
            // would otherwise look like loose text on the screen.
            .border(
                1.dp,
                MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f),
                RoundedCornerShape(24.dp),
            ),
    ) {
        Checkerboard(Modifier.fillMaxSize())
        Row(
            Modifier
                .fillMaxSize()
                .background(Color(base).copy(alpha = config.opacity))
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val bitmap = remember(payload.sessionUtilization, lightInk) {
                UsageRingRenderer.render(
                    payload.sessionUtilization,
                    sizePx = 140,
                    dark = lightInk,
                    showLabel = false,
                )
            }
            Image(bitmap.asImageBitmap(), null, Modifier.size(46.dp))
            Column(Modifier.padding(start = 12.dp).weight(1f)) {
                Text(
                    "${payload.sessionUtilization.roundToInt()}%",
                    color = Color(level.color),
                    fontWeight = FontWeight.Bold,
                    fontSize = 22.sp,
                    fontFamily = FontFamily.Monospace,
                )
                Text(
                    payload.sessionResetsAt?.let {
                        "resets in ${TimeFormatting.shortDuration((it.epochSecond - Instant.now().epochSecond).toDouble())}"
                    } ?: "no window",
                    color = muted,
                    fontSize = 12.sp,
                )
            }
            Column(horizontalAlignment = Alignment.End) {
                Text("WEEK", color = muted, fontSize = 10.sp)
                Text(
                    "${payload.weeklyUtilization.roundToInt()}%",
                    color = Color(UsageLevel.from(payload.weeklyUtilization).color),
                    fontWeight = FontWeight.Bold,
                    fontSize = 16.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
    }
}

/** The standard transparency checkerboard. */
@Composable
private fun Checkerboard(modifier: Modifier = Modifier) {
    androidx.compose.foundation.Canvas(modifier) {
        val square = 10.dp.toPx()
        val cols = (size.width / square).toInt() + 1
        val rows = (size.height / square).toInt() + 1
        for (row in 0 until rows) {
            for (col in 0 until cols) {
                val shade = if ((row + col) % 2 == 0) 0xFFE8E8E8 else 0xFFC9C9C9
                drawRect(
                    color = Color(shade),
                    topLeft = androidx.compose.ui.geometry.Offset(col * square, row * square),
                    size = androidx.compose.ui.geometry.Size(square, square),
                )
            }
        }
    }
}
