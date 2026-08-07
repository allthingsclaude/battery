package com.allthingsclaude.battery.data

import android.content.Context
import com.allthingsclaude.battery.core.SessionPolicy

/**
 * User preferences. Mirrors `ios/BatteryApp/Settings.swift`, minus the app-icon
 * picker — Android's only mechanism for that is `activity-alias` swapping, which
 * drops the user's home-screen shortcut on One UI.
 */
class Settings(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("settings", Context.MODE_PRIVATE)

    /**
     * When the lock-screen card should exist. Defaults to [SessionPolicy.Mode.SMART]
     * — quietest — but [SessionPolicy.Mode.WHENEVER_OPEN] is the one for anyone
     * who wants the meter up for the whole window.
     */
    var cardMode: SessionPolicy.Mode
        get() = prefs.getString(KEY_CARD_MODE, null)
            ?.let { raw -> SessionPolicy.Mode.entries.firstOrNull { it.name == raw } }
            ?: SessionPolicy.Mode.SMART
        set(value) = prefs.edit().putString(KEY_CARD_MODE, value.name).apply()

    private companion object {
        const val KEY_CARD_MODE = "card_mode"
    }
}

/** Titles and one-line explanations, kept beside the enum they describe. */
val SessionPolicy.Mode.title: String
    get() = when (this) {
        SessionPolicy.Mode.OFF -> "Off"
        SessionPolicy.Mode.SMART -> "Smart"
        SessionPolicy.Mode.WHENEVER_OPEN -> "Whole session"
    }

val SessionPolicy.Mode.subtitle: String
    get() = when (this) {
        SessionPolicy.Mode.OFF -> "Never show a lock-screen card"
        SessionPolicy.Mode.SMART -> "Only while a session is busy or past 40%"
        SessionPolicy.Mode.WHENEVER_OPEN -> "Any time a 5-hour window is open, at any percentage"
    }
