package com.allthingsclaude.battery.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.glance.GlanceId
import androidx.glance.GlanceTheme
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
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
    protected abstract fun Content(payload: UsagePayload?, config: WidgetConfig)

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        // Both resolved before provideContent: the payload so the first
        // composition already has data rather than flashing the empty state, and
        // the config because mapping a GlanceId to the numeric appWidgetId the
        // settings are keyed by is a suspend call that cannot happen inside
        // composition.
        val payload = PayloadStore(context).load()
        val appWidgetId = runCatching {
            GlanceAppWidgetManager(context).getAppWidgetId(id)
        }.getOrDefault(WidgetConfig.INVALID_ID)
        val config = WidgetConfig.load(context, appWidgetId)
        provideContent { GlanceTheme { Content(payload, config) } }
    }
}

/** 4x1 — the default, the same short-and-wide shape as the media player. */
class SessionRowWidget : BasePayloadWidget() {
    @Composable
    override fun Content(payload: UsagePayload?, config: WidgetConfig) {
        val palette = paletteFor(config)
        if (payload == null) return EmptyState(palette, compact = true)
        RowLayout(payload, palette)
    }
}

/** 2x2 — the session ring, a port of iOS's SmallGaugeView. */
class SessionRingWidget : BasePayloadWidget() {
    @Composable
    override fun Content(payload: UsagePayload?, config: WidgetConfig) {
        val palette = paletteFor(config)
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
    override fun Content(payload: UsagePayload?, config: WidgetConfig) {
        val palette = paletteFor(config)
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
    override fun Content(payload: UsagePayload?, config: WidgetConfig) {
        val palette = paletteFor(config)
        if (payload == null) return EmptyState(palette, compact = false)
        ForecastLayout(payload, palette)
    }
}

/**
 * Forgets a removed widget's settings, and owns the refresh schedule.
 *
 * Android reuses appWidgetIds, so without the cleanup a newly placed widget
 * would silently inherit the opacity and colours of a deleted one.
 *
 * Placing the first widget also syncs the refresh schedule, which is idempotent
 * (`KEEP`), so four providers doing it is the same as one. Removing the last one
 * does *not* cancel it — see [WidgetRefreshWorker.syncSchedule].
 */
abstract class ConfigCleaningReceiver : GlanceAppWidgetReceiver() {

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        appWidgetIds.forEach { WidgetConfig.delete(context, it) }
        super.onDeleted(context, appWidgetIds)
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        WidgetRefreshWorker.syncSchedule(context)
    }

    // Deliberately does not cancel. The worker is also how the lock-screen card
    // comes back after the service stands down, and that has nothing to do with
    // whether a widget is on a home screen. Signing out is what cancels it.
    override fun onDisabled(context: Context) {
        super.onDisabled(context)
    }
}

class SessionRowWidgetReceiver : ConfigCleaningReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SessionRowWidget()
}

class SessionRingWidgetReceiver : ConfigCleaningReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SessionRingWidget()
}

class OverviewWidgetReceiver : ConfigCleaningReceiver() {
    override val glanceAppWidget: GlanceAppWidget = OverviewWidget()
}

class ForecastWidgetReceiver : ConfigCleaningReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ForecastWidget()
}

/**
 * Repaint every widget type.
 *
 * `updateAll` throws for a widget type that isn't on any home screen, which is
 * the common case rather than an error — so each is attempted independently and
 * a failure on one can't stop the rest from updating.
 *
 * **Call this at most once per event.** Glance composes each widget in its own
 * WorkManager session, and a second call while the first is still composing
 * cancels it; the cancelled workers are later restarted, find no session, and
 * quietly do nothing, so *both* repaints are lost and the widgets keep their old
 * `RemoteViews`. Nothing throws, so `runCatching` above will not tell you. See
 * `WidgetRefreshWorker.doWork`, where that race was found and fixed.
 */
suspend fun refreshAllWidgets(context: Context) {
    listOf(SessionRowWidget(), SessionRingWidget(), OverviewWidget(), ForecastWidget())
        .forEach { runCatching { it.updateAll(context) } }
}
