package com.allthingsclaude.battery.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * AES-GCM encryption backed by a key that never leaves the Android Keystore.
 * This is the Keychain analogue, and the reason it's hand-rolled:
 * `androidx.security:security-crypto` — the library everyone reaches for — was
 * **deprecated in April 2025** at 1.1.0-alpha07 with no drop-in successor. The
 * current guidance is exactly what's below: your own AES-GCM over a Keystore
 * key, with the ciphertext in ordinary storage.
 *
 * Properties that matter:
 *  - `setUserAuthenticationRequired(false)` — the app must poll while the phone
 *    is locked in a pocket, which is the entire point of the product. Requiring
 *    auth would make the token unreadable exactly when it's needed.
 *  - No `setIsStrongBoxBacked` — StrongBox is absent on many devices and throws
 *    at generation time rather than falling back.
 *  - A fresh random IV per encryption, prepended to the ciphertext. GCM with a
 *    reused IV and the same key is catastrophic, not merely weak.
 */
class SecureStore(context: Context) {

    private val appContext = context.applicationContext
    private val dir = File(appContext.filesDir, "secure").apply { mkdirs() }

    fun write(name: String, plaintext: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key()) }
        val ciphertext = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        // IV first so `read` can recover it without a second file to keep in sync.
        val blob = cipher.iv + ciphertext
        File(dir, name).writeText(Base64.encodeToString(blob, Base64.NO_WRAP))
    }

    fun read(name: String): String? {
        val file = File(dir, name)
        if (!file.exists()) return null
        return try {
            val blob = Base64.decode(file.readText(), Base64.NO_WRAP)
            if (blob.size <= IV_LENGTH) return null
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(
                    Cipher.DECRYPT_MODE,
                    key(),
                    GCMParameterSpec(TAG_LENGTH_BITS, blob, 0, IV_LENGTH),
                )
            }
            String(cipher.doFinal(blob, IV_LENGTH, blob.size - IV_LENGTH), Charsets.UTF_8)
        } catch (_: Exception) {
            // Unreadable rather than absent: the Keystore key is gone (app data
            // cleared, device restored from backup, or the key was invalidated).
            // Deleting is the honest response — the ciphertext is permanently
            // undecryptable, and leaving it means retrying forever.
            file.delete()
            null
        }
    }

    fun delete(name: String) {
        File(dir, name).delete()
    }

    fun deleteAll() {
        dir.listFiles()?.forEach { it.delete() }
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                // See the class doc: the app polls while the device is locked.
                .setUserAuthenticationRequired(false)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "battery_tokens"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_LENGTH = 12
        const val TAG_LENGTH_BITS = 128
    }
}
