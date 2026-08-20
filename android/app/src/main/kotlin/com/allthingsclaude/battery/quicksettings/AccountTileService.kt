package com.allthingsclaude.battery.quicksettings

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.allthingsclaude.battery.data.AccountSwitcher
import com.allthingsclaude.battery.data.AccountStore
import com.allthingsclaude.battery.data.UsageRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Switch accounts from the quick panel, without unlocking the phone.
 *
 * This is the only switcher that works from anywhere, and the reason is
 * structural: [onClick] runs in this app's own process, so there is no activity
 * launch and no `PendingIntent` in the path — and therefore none of the Android
 * 12 notification-trampoline rules, and none of the Android 14/15/17
 * background-activity-launch tightening, applies to it. Measured on One UI 8.5:
 * every click fires with the device reporting both locked and secure, and no
 * credential prompt appears.
 *
 * The header tabs are better when the app is already open, and the card action
 * is better while a session is live and on screen. This is what covers the rest
 * of the day.
 *
 * A **cycle**, not a toggle — hence no `TOGGLEABLE_TILE` in the manifest, which
 * would declare a two-state switch to accessibility services and describe this
 * as something it is not.
 */
class AccountTileService : TileService() {

    // Main.immediate so an optimistic re-render lands in the same frame as the
    // tap rather than a frame later.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val accounts by lazy { AccountStore(applicationContext) }
    private val repository by lazy { UsageRepository(applicationContext) }
    private val switcher by lazy { AccountSwitcher(applicationContext, repository) }

    override fun onStartListening() = render()

    override fun onClick() {
        val next = accounts.nextAccountId()
        // Nothing to switch to is an ordinary state — one account, or none. A
        // tile that reported an error for it would be wrong, so it just redraws.
        if (next == null) {
            render()
            return
        }

        // Redraw against the incoming account before the poll, so the tile moves
        // under the finger. The percentage is briefly the outgoing account's —
        // which is why the switch clears the payload cache rather than leaving a
        // stale number to be read as the new account's.
        render(previewAccountId = next)
        scope.launch {
            switcher.switchTo(next)
            render()
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    /**
     * @param previewAccountId draw this account instead of the stored selection,
     *   for the moment between the tap and the switch completing.
     */
    private fun render(previewAccountId: String? = null) {
        val tile = qsTile ?: return
        val all = accounts.load()
        val id = previewAccountId ?: repository.selectedAccountId
        val account = all.firstOrNull { it.id == id } ?: all.firstOrNull()

        if (account == null) {
            tile.state = Tile.STATE_UNAVAILABLE
            tile.label = getString(com.allthingsclaude.battery.R.string.app_name)
            tile.subtitle = "Not signed in"
            tile.icon = Icon.createWithResource(this, com.allthingsclaude.battery.R.drawable.ic_stat_battery)
            tile.updateTile()
            return
        }

        tile.state = Tile.STATE_ACTIVE
        tile.label = account.name
        tile.subtitle = subtitle(previewAccountId != null)
        // The label is what names the account, and One UI 8.5 lets the user
        // shrink a tile to 1x1, which drops it. So the icon has to carry the
        // identity too — as a glyph, because the system tints tile icons by
        // state and would flatten any colour coding to a single hue.
        tile.icon = initialIcon(account.name)
        tile.contentDescription = "Claude usage account"
        tile.stateDescription = "${account.name} selected"
        tile.updateTile()
    }

    private fun subtitle(switching: Boolean): String {
        if (switching) return "Switching…"
        val payload = repository.lastKnownPayload ?: return "No reading yet"
        return "${payload.sessionUtilization.roundToInt()}% used"
    }

    private fun initialIcon(name: String): Icon {
        val letter = name.trim().firstOrNull()?.uppercase() ?: "?"
        val bitmap = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            // White, so the system's state tint multiplies to whatever the panel
            // wants. Anything else fights the tint and loses.
            color = Color.WHITE
            textSize = ICON_PX * 0.72f
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val baseline = ICON_PX / 2f - (paint.descent() + paint.ascent()) / 2f
        Canvas(bitmap).drawText(letter, ICON_PX / 2f, baseline, paint)
        return Icon.createWithBitmap(bitmap)
    }

    companion object {
        private const val ICON_PX = 96

        /**
         * Ask the system to bind us so a switch made elsewhere reaches the tile.
         *
         * Needed because the tile is declared `ACTIVE_TILE`: the system then
         * binds it for adds, removes and taps only, and would otherwise keep
         * showing the account the user switched away from until they next opened
         * the panel.
         */
        fun requestRefresh(context: Context) {
            runCatching {
                requestListeningState(
                    context,
                    ComponentName(context, AccountTileService::class.java),
                )
            }
        }
    }
}
