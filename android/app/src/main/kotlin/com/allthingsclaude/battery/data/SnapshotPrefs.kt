package com.allthingsclaude.battery.data

import android.content.SharedPreferences
import com.allthingsclaude.battery.core.SnapshotStore
import com.allthingsclaude.battery.core.UsageSnapshot
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/**
 * The burn-rate sample buffer, persisted alongside the payload.
 *
 * Persisted rather than held in memory for the reason the iOS comments spell
 * out: the regression needs samples from *every* poll, whoever made it. On
 * Android the foreground service, the WorkManager keep-warm job and a manual
 * refresh are three entry points into the same process, and a buffer that only
 * lived in one of them is why iOS spent so long showing an em dash instead of a
 * burn rate.
 *
 * Field names are single letters because at [SessionHistory.CAPACITY] = 30 this
 * is written on every poll, and the long form tripled the string for no reader's
 * benefit — nothing but this file ever parses it.
 */
internal class SnapshotPrefs(private val prefs: SharedPreferences) : SnapshotStore {

    override fun load(): List<UsageSnapshot> {
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).map { i ->
                val obj = array.getJSONObject(i)
                UsageSnapshot(
                    timestamp = Instant.ofEpochMilli(obj.getLong("t")),
                    sessionUtilization = obj.getDouble("u"),
                    sessionResetsAt = Instant.ofEpochMilli(obj.getLong("r")),
                )
            }
        }.getOrDefault(emptyList())
    }

    override fun save(snapshots: List<UsageSnapshot>) {
        val array = JSONArray()
        snapshots.forEach {
            array.put(
                JSONObject()
                    .put("t", it.timestamp.toEpochMilli())
                    .put("u", it.sessionUtilization)
                    .put("r", it.sessionResetsAt.toEpochMilli())
            )
        }
        prefs.edit().putString(KEY, array.toString()).apply()
    }

    override fun clear() {
        prefs.edit().remove(KEY).apply()
    }

    private companion object {
        const val KEY = "snapshots"
    }
}
