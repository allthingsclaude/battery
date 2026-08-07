package com.allthingsclaude.battery.live

import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings

/**
 * Whether One UI will actually surface our Live Update on the Now Bar and the
 * status-bar chip.
 *
 * One UI 8.5 gates third-party Live Updates behind **Developer options ▸ "Live
 * notifications for all apps"**, which ships OFF. With it off a promoted
 * notification still reports every success — `canPostPromotedNotifications()` is
 * true, `FLAG_PROMOTED_ONGOING` is set, the lock-screen card appears — and only
 * the Now Bar pill and the chip are missing. That partial failure is why it
 * reads as a missing capability rather than a switch.
 *
 * The toggle is stored as a readable `Settings.Secure` key, so it *can* be
 * detected even though it can't be written without `WRITE_SECURE_SETTINGS`
 * (a privileged permission no ordinary app can hold). Reading is enough: the
 * app can stop guessing and point at the exact screen.
 *
 * Key discovered by diffing `settings list secure` after flipping it on a
 * Galaxy S24 Ultra; `settings_change_history` corroborates it, recording
 * `notification_nowbar_test|com.android.settings` at the moment of the change.
 */
object NowBarGate {

    /**
     * Samsung's own name for it. Undocumented, and the `_test` suffix suggests
     * it may be renamed — which is why an absent key is treated as "not
     * applicable" rather than "off".
     */
    private const val KEY = "enable_notification_nowbar_test"

    enum class State {
        /** The gate is open; the Now Bar and the chip will render. */
        ENABLED,

        /** Present and off. This is the case worth telling the user about. */
        DISABLED,

        /**
         * Developer options are off entirely, so the toggle isn't reachable yet.
         * Needs the Build-number tap first, which is worth saying explicitly
         * rather than sending someone to a screen that doesn't exist for them.
         */
        DEVELOPER_OPTIONS_OFF,

        /**
         * No such key. Either a non-Samsung device, or a One UI version that
         * renamed or removed the gate. Assume nothing is wrong — a banner
         * telling a Pixel owner to find a Samsung setting would be worse than
         * silence.
         */
        NOT_APPLICABLE,
    }

    fun state(context: Context): State {
        // Live Updates don't exist below API 36, so there is nothing to gate.
        if (Build.VERSION.SDK_INT < 36) return State.NOT_APPLICABLE

        val resolver = context.contentResolver
        // -1 as the sentinel: `getInt` cannot otherwise distinguish "absent"
        // from "present and 0", and those mean very different things here.
        val value = Settings.Secure.getInt(resolver, KEY, -1)
        if (value < 0) return State.NOT_APPLICABLE
        if (value > 0) return State.ENABLED

        val devOptions = Settings.Global.getInt(
            resolver,
            Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
            0,
        )
        return if (devOptions == 0) State.DEVELOPER_OPTIONS_OFF else State.DISABLED
    }

    /** Opens Developer options, or the About screen when they aren't unlocked yet. */
    fun settingsIntent(state: State): Intent? = when (state) {
        State.DISABLED ->
            Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        State.DEVELOPER_OPTIONS_OFF ->
            // There is no intent that unlocks developer options; the closest
            // useful destination is the screen holding the Build number the
            // user has to tap.
            Intent(Settings.ACTION_DEVICE_INFO_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        else -> null
    }

    /** What to tell the user, or null when there is nothing worth saying. */
    fun advice(state: State): Advice? = when (state) {
        State.DISABLED -> Advice(
            title = "Turn on the Now Bar",
            body = "Your session card shows on the lock screen, but Samsung hides " +
                "the Now Bar pill and the status-bar chip behind a developer " +
                "setting. Enable “Live notifications for all apps”.",
            action = "Open Developer options",
        )
        State.DEVELOPER_OPTIONS_OFF -> Advice(
            title = "Turn on the Now Bar",
            body = "Samsung keeps this behind Developer options, which aren't " +
                "unlocked yet: tap Build number seven times, then enable " +
                "“Live notifications for all apps”.",
            action = "Open About phone",
        )
        else -> null
    }

    data class Advice(val title: String, val body: String, val action: String)
}
