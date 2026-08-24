package com.allthingsclaude.battery.data

import android.content.Context
import com.allthingsclaude.battery.core.AccountCycle
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** One Claude account. Tokens live in [TokenStore], keyed by [id]. */
data class Account(
    val id: String,
    val name: String,
    /**
     * The plan badge, resolved once at sign-in from `/api/oauth/profile`.
     *
     * Stored beside the name because it comes from the same call and has the
     * same character: a label, resolved once, not worth a request per poll. The
     * usage endpoint carries no plan information at all — measured — so this is
     * the only place it can come from.
     */
    val planTier: String = "",
) {
    companion object {
        fun new(name: String, planTier: String = "") =
            Account(UUID.randomUUID().toString(), name, planTier)
    }
}

/**
 * The account list and which one is selected. Plain (unencrypted) preferences on
 * purpose: this is metadata — an id and a display name. The credential it points
 * at is the thing that needs protecting, and that's [TokenStore]'s job.
 *
 * Port of `ios/BatteryApp/Account.swift`.
 */
class AccountStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("accounts", Context.MODE_PRIVATE)

    fun load(): List<Account> {
        val raw = prefs.getString(KEY_ACCOUNTS, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).map { i ->
                val obj = array.getJSONObject(i)
                // optString: accounts saved before the plan existed have no
                // such key, and an empty badge is exactly what they mean.
                Account(obj.getString("id"), obj.getString("name"), obj.optString("planTier", ""))
            }
        }.getOrDefault(emptyList())
    }

    fun save(accounts: List<Account>) {
        val array = JSONArray()
        accounts.forEach {
            array.put(JSONObject().put("id", it.id).put("name", it.name).put("planTier", it.planTier))
        }
        prefs.edit().putString(KEY_ACCOUNTS, array.toString()).apply()
    }

    var selectedId: String?
        get() = prefs.getString(KEY_SELECTED, null)
        set(value) = prefs.edit().apply {
            if (value == null) remove(KEY_SELECTED) else putString(KEY_SELECTED, value)
        }.apply()

    /**
     * The account everything should be reading, resolving an unset selection to
     * the first one — the same rule the repository polls by, kept here so the
     * widgets and the tile cannot disagree with it.
     */
    val activeId: String? get() = selectedId ?: load().firstOrNull()?.id

    /**
     * The account after the selected one, wrapping past the end.
     *
     * A cycle, not a toggle. The list is N long, not two, and "switch" has to
     * keep meaning something at three — so the primitive is "next", and the
     * two-account case falls out of it for free rather than being a second code
     * path that can disagree with the first. It is the same reason Alt-Tab was
     * never designed as a two-window toggle.
     *
     * Null when there is nothing to switch to: no accounts, or only one. See
     * [AccountCycle] for the rules and the cases they are pinned to.
     */
    fun nextAccountId(): String? =
        AccountCycle.next(load().map { it.id }, selectedId)

    /**
     * "Account N" using the highest existing suffix, so removing #1 from [1, 2]
     * doesn't produce a second "Account 2". Ported deliberately — the naive
     * `size + 1` version collides.
     */
    fun nextAccountName(existing: List<Account>): String {
        val used = existing.mapNotNull { account ->
            account.name.removePrefix("Account ").takeIf { it != account.name }?.toIntOrNull()
        }
        return "Account ${(used.maxOrNull() ?: existing.size) + 1}"
    }

    private companion object {
        const val KEY_ACCOUNTS = "accounts"
        const val KEY_SELECTED = "selected"
    }
}
