package com.allthingsclaude.battery.probe

import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import com.allthingsclaude.battery.R

/**
 * The Quick Settings account switcher, in its earliest form (PLAN_02 Phase 4).
 *
 * Still synthetic: it does not touch the real [AccountStore] yet, because the
 * debug build has its own applicationId and so its own empty prefs, and because
 * what needed answering first was whether the *surface* works at all. It does —
 * see the manifest for what the device proved.
 *
 * A **cycle**, not a toggle. Three names rather than two on purpose: with two,
 * "next" and "the other one" are indistinguishable, and the wrap from the last
 * account back to the first — the step most likely to be written wrong — never
 * gets exercised.
 */
class AccountTileService : TileService() {

    private val prefs by lazy {
        applicationContext.getSharedPreferences("probe_tile", MODE_PRIVATE)
    }

    private var selected: Int
        get() = prefs.getInt("selected", 0)
        set(v) = prefs.edit().putInt("selected", v).apply()

    override fun onTileAdded() {
        Log.i(TAG, "onTileAdded")
        render()
    }

    override fun onStartListening() {
        Log.i(TAG, "onStartListening secure=${isSecure} locked=${isLocked}")
        render()
    }

    /**
     * The whole point of the tile: this runs in *our* process, on tap, with no
     * activity launch and no PendingIntent in the path. If the locked-state log
     * below shows locked=true and the state still flipped, a switch costs two
     * gestures from a locked phone.
     */
    override fun onClick() {
        selected = (selected + 1) % NAMES.size
        Log.i(TAG, "onClick -> selected=$selected secure=${isSecure} locked=${isLocked}")
        render()
    }

    private fun render() {
        val tile = qsTile ?: run { Log.w(TAG, "qsTile null"); return }
        val name = NAMES[selected]
        tile.label = name
        tile.subtitle = "${42 + selected * 17}% used"
        tile.contentDescription = "Active account $name"
        tile.stateDescription = "$name selected"
        tile.state = Tile.STATE_ACTIVE
        tile.icon = Icon.createWithResource(this, R.drawable.ic_stat_battery)
        tile.updateTile()
        Log.i(TAG, "updateTile label=$name subtitle=${tile.subtitle}")
    }

    private companion object {
        const val TAG = "BatteryProbe"
        // Three, not two: the cycle has to be shown wrapping 3 -> 1.
        val NAMES = arrayOf("Work", "Personal", "Client")
    }
}
