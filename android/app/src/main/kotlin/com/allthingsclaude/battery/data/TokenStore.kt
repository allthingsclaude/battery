package com.allthingsclaude.battery.data

import android.content.Context
import com.allthingsclaude.battery.core.StoredTokens
import org.json.JSONObject

/**
 * Per-account OAuth tokens, encrypted at rest. Port of `ios/BatteryApp/TokenStore.swift`,
 * which keys Keychain items by account id; here the key is the filename inside
 * [SecureStore].
 *
 * Unlike iOS there is no App Group and no mirrored copy: on Android the widgets
 * run in this same process, so nothing ever needs a second, less-protected copy
 * of an access token. That whole class of exposure — `SharedStore.saveToken` and
 * its "less private than the Keychain" caveat — simply doesn't exist here.
 */
class TokenStore(context: Context) {

    private val secure = SecureStore(context)

    fun save(accountId: String, tokens: StoredTokens): Boolean = runCatching {
        secure.write(
            fileName(accountId),
            JSONObject()
                .put("accessToken", tokens.accessToken)
                .put("refreshToken", tokens.refreshToken ?: JSONObject.NULL)
                .put("expiresAt", tokens.expiresAt)
                .toString(),
        )
    }.isSuccess

    fun load(accountId: String): StoredTokens? {
        val raw = secure.read(fileName(accountId)) ?: return null
        return runCatching {
            val json = JSONObject(raw)
            StoredTokens(
                accessToken = json.getString("accessToken"),
                refreshToken = json.optString("refreshToken").takeIf {
                    it.isNotEmpty() && it != "null"
                },
                expiresAt = json.getLong("expiresAt"),
            )
        }.getOrNull()
    }

    fun delete(accountId: String) = secure.delete(fileName(accountId))

    fun deleteAll() = secure.deleteAll()

    private fun fileName(accountId: String) = "tokens_$accountId"
}
