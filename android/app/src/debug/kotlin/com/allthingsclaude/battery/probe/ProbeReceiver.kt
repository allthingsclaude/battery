package com.allthingsclaude.battery.probe

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Target of the live card's probe action (check 1).
 *
 * State-only: it never starts an activity, which is why the Android 12
 * trampoline ban does not apply. Logs the keyguard state so the locked-tap
 * question is answered from the same run.
 */
class ProbeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val km = context.getSystemService(KeyguardManager::class.java)
        Log.i(
            "BatteryProbe",
            "card action fired account=${intent.getStringExtra(EXTRA_ACCOUNT)} " +
                "locked=${km.isKeyguardLocked} secure=${km.isDeviceSecure}",
        )
    }

    companion object {
        const val ACTION = "com.allthingsclaude.battery.probe.SWITCH"
        const val EXTRA_ACCOUNT = "account"
    }
}
