package com.allthingsclaude.battery.live

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.allthingsclaude.battery.data.AccountSwitcher
import com.allthingsclaude.battery.data.UsageRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * The live card's "Switch to …" button.
 *
 * State-only, and that is the whole reason it is allowed to exist: Android 12
 * bans a notification from launching an activity via a receiver used as a
 * trampoline, but a receiver that only mutates state and lets the card repaint
 * itself is the shape the platform documents as correct. Measured on One UI 8.5:
 * the action fires with the device locked and secure, the keyguard never drops,
 * and the card keeps `FLAG_PROMOTED_ONGOING` with the button attached.
 *
 * The button is not on the collapsed Now Bar pill — reaching it from the lock
 * screen costs one tap to expand the card first. That is why this is the
 * convenience path for a session already on screen, and the Quick Settings tile
 * is the one that works from anywhere.
 */
class AccountSwitchReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ACCOUNT_ID) ?: return
        val appContext = context.applicationContext

        // The switch polls, so it cannot finish inside onReceive's main-thread
        // budget. goAsync buys roughly ten seconds — enough for one request, and
        // the card repaints itself either way.
        val pending = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val repository = UsageRepository(appContext)
                AccountSwitcher(appContext, repository).switchTo(id)
            } catch (t: Throwable) {
                Log.w(TAG, "switch from the card failed", t)
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        private const val TAG = "AccountSwitch"
        const val ACTION = "com.allthingsclaude.battery.action.SWITCH_ACCOUNT"
        const val EXTRA_ACCOUNT_ID = "account_id"
    }
}
