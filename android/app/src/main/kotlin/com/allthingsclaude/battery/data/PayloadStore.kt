package com.allthingsclaude.battery.data

import android.content.Context
import com.allthingsclaude.battery.core.SnapshotStore
import com.allthingsclaude.battery.core.ExtraUsage
import com.allthingsclaude.battery.core.UsagePayload
import org.json.JSONObject
import java.time.Instant

/**
 * The last-known payload and the burn-rate sample buffer.
 *
 * The iOS counterpart (`SharedStore`) exists to bridge an App Group between two
 * processes and carries a real security trade-off for it — a mirrored access
 * token sitting in a container so the widget extension can self-fetch. None of
 * that applies here: Glance widgets run in this process, so this is just a cache
 * that survives a cold start, and no credential is ever copied out of
 * [TokenStore].
 */
class PayloadStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("payload", Context.MODE_PRIVATE)

    /**
     * The burn-rate sample buffer, exposed separately rather than implemented on
     * this class: both concerns want `load`/`save`/`clear`, and collapsing them
     * onto one type produced three overload collisions and no clarity.
     */
    val snapshots: SnapshotStore = SnapshotPrefs(prefs)

    // ── Payload ─────────────────────────────────────────────────────────────

    fun save(payload: UsagePayload) {
        prefs.edit().putString(KEY_PAYLOAD, encode(payload).toString()).apply()
    }

    fun load(): UsagePayload? {
        val raw = prefs.getString(KEY_PAYLOAD, null) ?: return null
        return runCatching { decode(JSONObject(raw)) }.getOrNull()
    }

    fun clear() {
        prefs.edit().clear().apply()
    }

    // ── Codec ───────────────────────────────────────────────────────────────
    //
    // Epoch millis throughout. Hand-written rather than reflective so the shape
    // is legible from both sides if a future FCM relay ever writes this JSON —
    // the iOS ContentState carries a hand-written Codable for exactly that
    // reason, after Swift's synthesised one silently encoded dates relative to
    // 2001.

    private fun encode(p: UsagePayload) = JSONObject().apply {
        put("sessionUtilization", p.sessionUtilization)
        put("sessionResetsAt", p.sessionResetsAt?.toEpochMilli() ?: JSONObject.NULL)
        put("weeklyUtilization", p.weeklyUtilization)
        put("weeklyResetsAt", p.weeklyResetsAt?.toEpochMilli() ?: JSONObject.NULL)
        put("opusUtilization", p.opusUtilization ?: JSONObject.NULL)
        put("scopedLabel", p.scopedLabel)
        put("extraUsage", p.extraUsage?.let {
            JSONObject()
                .put("isEnabled", it.isEnabled)
                .put("usedMinor", it.usedMinor ?: JSONObject.NULL)
                .put("limitMinor", it.limitMinor ?: JSONObject.NULL)
                .put("utilization", it.utilization ?: JSONObject.NULL)
                .put("currency", it.currency)
                .put("decimalPlaces", it.decimalPlaces)
        } ?: JSONObject.NULL)
        put("burnRatePerHour", p.burnRatePerHour)
        put("projectedLimitAt", p.projectedLimitAt?.toEpochMilli() ?: JSONObject.NULL)
        put("isSessionActive", p.isSessionActive)
        put("planTier", p.planTier)
        put("accountName", p.accountName)
        put("isConnected", p.isConnected)
        put("updatedAt", p.updatedAt.toEpochMilli())
    }

    private fun decode(o: JSONObject) = UsagePayload(
        sessionUtilization = o.getDouble("sessionUtilization"),
        sessionResetsAt = o.instantOrNull("sessionResetsAt"),
        weeklyUtilization = o.getDouble("weeklyUtilization"),
        weeklyResetsAt = o.instantOrNull("weeklyResetsAt"),
        opusUtilization = if (o.isNull("opusUtilization")) null else o.getDouble("opusUtilization"),
        // Absent in payloads written before the label existed; an empty
        // label falls back to "Opus" at the render site, which is what
        // those payloads meant.
        scopedLabel = o.optString("scopedLabel", ""),
        extraUsage = o.optJSONObject("extraUsage")?.let { e ->
            ExtraUsage(
                isEnabled = e.optBoolean("isEnabled", false),
                usedMinor = if (e.isNull("usedMinor")) null else e.getDouble("usedMinor"),
                limitMinor = if (e.isNull("limitMinor")) null else e.getDouble("limitMinor"),
                utilization = if (e.isNull("utilization")) null else e.getDouble("utilization"),
                currency = e.optString("currency", "USD"),
                decimalPlaces = e.optInt("decimalPlaces", 2),
            )
        },
        burnRatePerHour = o.optDouble("burnRatePerHour", 0.0),
        projectedLimitAt = o.instantOrNull("projectedLimitAt"),
        isSessionActive = o.optBoolean("isSessionActive", false),
        planTier = o.optString("planTier", ""),
        accountName = o.optString("accountName", "Account"),
        isConnected = o.optBoolean("isConnected", true),
        updatedAt = o.instantOrNull("updatedAt") ?: Instant.now(),
    )

    private fun JSONObject.instantOrNull(key: String): Instant? =
        if (isNull(key)) null else Instant.ofEpochMilli(getLong(key))

    private companion object {
        const val KEY_PAYLOAD = "latest"
        const val KEY_SNAPSHOTS = "snapshots"
    }
}
