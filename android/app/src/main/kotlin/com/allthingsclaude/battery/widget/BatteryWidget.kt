package com.allthingsclaude.battery.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.glance.GlanceId
import androidx.glance.GlanceTheme
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import androidx.glance.LocalSize
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.updateAll
import com.allthingsclaude.battery.core.UsagePayload
import com.allthingsclaude.battery.data.PayloadStore

/**
 * Four widgets, mirroring the iOS set.
 *
 * All of them read the shared payload and nothing else. On iOS the widget
 * extension is a separate process that has to self-fetch from the network with a
 * mirrored access token — a real security trade-off its own comments
 * acknowledge. Glance widgets run in the app's process and read what the service
 * already wrote, so no credential is ever copied anywhere. That whole class of
 * exposure has no Android equivalent.
 */
abstract class BasePayloadWidget : GlanceAppWidget() {

    @Composable
    protected abstract fun Content(payload: UsagePayload?)

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        // Read before provideContent so the first composition already has data.
        // Loading inside would flash the empty state on every update.
        val payload = PayloadStore(context).load()
        provideContent { GlanceTheme { Content(payload) } }
    }
}

/** 4x1 — the default, the same short-and-wide shape as the media player. */
class SessionRowWidget : BasePayloadWidget() {
    @Composable
    override fun Content(payload: UsagePayload?) {
        val palette = rememberPalette()
        if (payload == null) return EmptyState(palette, compact = true)
        RowLayout(payload, palette)
    }
}

/** 2x2 — the session ring, a port of iOS's SmallGaugeView. */
class SessionRingWidget : BasePayloadWidget() {
    @Composable
    override fun Content(payload: UsagePayload?) {
        val palette = rememberPalette()
        if (payload == null) return EmptyState(palette, compact = false)
        RingLayout(
            palette = palette,
            title = "Session",
            utilization = payload.sessionUtilization,
            caption = resetText(payload.sessionResetsAt),
            active = payload.isSessionActive,
        )
    }
}

/**
 * Session, weekly and Opus. Responsive by height: 4x2 gets the hero ring plus
 * bar rows (iOS's MediumOverviewView), 4x1 gets bars only — which is the
 * "smaller overview" shape, without inventing a fifth widget for it.
 */
class OverviewWidget : BasePayloadWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SHORT, TALL))

    @Composable
    override fun Content(payload: UsagePayload?) {
        val palette = rememberPalette()
        if (payload == null) return EmptyState(palette, compact = true)
        OverviewLayout(payload, palette, short = LocalSize.current.height < TALL.height)
    }

    companion object {
        val SHORT = DpSize(250.dp, 50.dp)
        val TALL = DpSize(250.dp, 110.dp)
    }
}

/** 4x2 — where the window is heading, in UsageForecast's own words. */
class ForecastWidget : BasePayloadWidget() {
    @Composable
    override fun Content(payload: UsagePayload?) {
        val palette = rememberPalette()
        if (payload == null) return EmptyState(palette, compact = false)
        ForecastLayout(payload, palette)
    }
}

class SessionRowWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SessionRowWidget()
}

class SessionRingWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SessionRingWidget()
}

class OverviewWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = OverviewWidget()
}

class ForecastWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ForecastWidget()
}

/**
 * Repaint every widget type.
 *
 * Called from the one place a new payload lands. `updateAll` throws for a widget
 * type that isn't on any home screen, which is the common case rather than an
 * error — so each is attempted independently and a failure on one can't stop the
 * rest from updating.
 */
suspend fun refreshAllWidgets(context: Context) {
    listOf(SessionRowWidget(), SessionRingWidget(), OverviewWidget(), ForecastWidget())
        .forEach { runCatching { it.updateAll(context) } }
}
