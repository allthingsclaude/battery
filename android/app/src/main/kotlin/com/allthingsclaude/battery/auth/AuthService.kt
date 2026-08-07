package com.allthingsclaude.battery.auth

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import com.allthingsclaude.battery.core.AppConfig
import com.allthingsclaude.battery.core.StoredTokens
import com.allthingsclaude.battery.core.UsageApi
import java.io.Closeable
import java.net.InetAddress
import java.net.ServerSocket
import java.security.MessageDigest
import java.security.SecureRandom
import android.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * OAuth PKCE sign-in, mirroring `ios/BatteryApp/AuthService.swift`: a loopback
 * HTTP listener on an ephemeral port catches the `?code=` redirect, and the
 * authorize page opens in a Custom Tab.
 *
 * Why a loopback redirect rather than a custom scheme: the registered OAuth
 * client is the one Claude Code and the menu-bar app already use, and it permits
 * `http://localhost:<port>/callback`. Inventing a `battery://` scheme would need
 * a client change we don't control. This is also the OAuth-for-native-apps BCP
 * (RFC 8252), not a workaround.
 *
 * A subtlety that trips people up: the app's own cleartext network policy does
 * **not** apply here. We are the *server*; the HTTP client is Chrome, in its own
 * process, which loads `http://localhost` happily. No `usesCleartextTraffic` and
 * no network-security-config entry is required.
 */
class AuthService(private val context: Context) {

    sealed class Result {
        data class Success(val tokens: StoredTokens) : Result()
        data class Failure(val message: String) : Result()
        /** The user dismissed the tab. Not an error worth surfacing. */
        object Cancelled : Result()
    }

    private var listener: LoopbackListener? = null
    private var state: String? = null

    /**
     * Start sign-in. Opens a Custom Tab and returns immediately; [onResult] fires
     * on a background thread once the redirect lands, the attempt times out, or
     * it fails.
     *
     * @param scopes defaults to the app's own set. Kept as a parameter because
     * the iOS app uses a narrower `user:profile` grant for its relay, and any
     * future equivalent here would want the same seam.
     */
    fun start(
        scopes: String = AppConfig.OAUTH_SCOPES,
        onResult: (Result) -> Unit,
    ) {
        // Never leave a previous attempt's socket and thread running.
        cancel()

        val codeVerifier = randomUrlSafe()
        val challenge = codeChallenge(codeVerifier)
        val oauthState = randomUrlSafe()
        state = oauthState

        val server = LoopbackListener(
            onCode = { code, returnedState, port ->
                if (returnedState != null && returnedState != oauthState) {
                    // CSRF guard. iOS sends `state` but never checks the value
                    // that comes back; there's no reason to inherit that.
                    onResult(Result.Failure("Sign-in failed: state mismatch."))
                    return@LoopbackListener
                }
                onResult(exchange(code, codeVerifier, port))
            },
            onTimeout = { onResult(Result.Cancelled) },
        )

        val port = server.start()
        if (port == null) {
            onResult(Result.Failure("Couldn't start the local sign-in listener."))
            return
        }
        listener = server

        val authorizeUrl = Uri.parse(AppConfig.OAUTH_AUTHORIZE_URL).buildUpon()
            .appendQueryParameter("client_id", AppConfig.OAUTH_CLIENT_ID)
            .appendQueryParameter("redirect_uri", redirectUri(port))
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("scope", scopes)
            .appendQueryParameter("code_challenge", challenge)
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("state", oauthState)
            .build()

        CustomTabsIntent.Builder()
            .setShowTitle(true)
            .build()
            .launchUrl(context, authorizeUrl)
    }

    /** Tear down any in-flight attempt. Safe to call repeatedly. */
    fun cancel() {
        listener?.close()
        listener = null
    }

    private fun exchange(code: String, codeVerifier: String, port: Int): Result {
        val body = JsonBody()
            .put("grant_type", "authorization_code")
            .put("code", code)
            .put("client_id", AppConfig.OAUTH_CLIENT_ID)
            .put("code_verifier", codeVerifier)
            .put("redirect_uri", redirectUri(port))
            .apply { state?.let { put("state", it) } }
            .toString()

        return try {
            val response = com.allthingsclaude.battery.core.UrlConnectionTransport().request(
                url = AppConfig.OAUTH_TOKEN_URL,
                method = "POST",
                headers = mapOf(
                    "Content-Type" to "application/json",
                    "User-Agent" to userAgent,
                ),
                body = body,
            )
            if (response.code != 200) {
                return Result.Failure("Sign-in failed: HTTP ${response.code}")
            }
            Result.Success(UsageApi.parseTokens(response.body, previous = null))
        } catch (e: Exception) {
            Result.Failure("Sign-in failed: ${e.message}")
        } finally {
            cancel()
        }
    }

    private fun redirectUri(port: Int) = "http://localhost:$port${AppConfig.OAUTH_REDIRECT_PATH}"

    private val userAgent: String
        get() = AppConfig.userAgent(
            runCatching {
                context.packageManager.getPackageInfo(context.packageName, 0).versionName
            }.getOrNull() ?: "0"
        )

    // ── PKCE ────────────────────────────────────────────────────────────────

    private fun randomUrlSafe(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    private fun codeChallenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    /** Minimal JSON object builder — org.json would work but escapes differently. */
    private class JsonBody {
        private val fields = mutableListOf<Pair<String, String>>()
        fun put(key: String, value: String) = apply { fields += key to value }
        override fun toString() = fields.joinToString(",", "{", "}") { (k, v) ->
            "${quote(k)}:${quote(v)}"
        }
        private fun quote(s: String) =
            "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
    }
}

/**
 * A minimal loopback HTTP server that captures the OAuth redirect.
 *
 * Bound explicitly to `127.0.0.1` rather than all interfaces: a listener on
 * `0.0.0.0` would accept an authorization code from anything on the same
 * network for as long as sign-in is open.
 */
private class LoopbackListener(
    private val onCode: (code: String, state: String?, port: Int) -> Unit,
    private val onTimeout: () -> Unit,
) : Closeable {

    private var server: ServerSocket? = null
    private val finished = AtomicBoolean(false)

    fun start(): Int? = try {
        val socket = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        // Bounds the whole attempt. Without it an abandoned sign-in leaks the
        // socket and its thread for the life of the process — the iOS original
        // needs a 5-minute timer for exactly this.
        socket.soTimeout = TIMEOUT_MS
        server = socket
        thread(isDaemon = true, name = "oauth-loopback") { accept(socket) }
        socket.localPort
    } catch (_: Exception) {
        null
    }

    private fun accept(socket: ServerSocket) {
        try {
            while (!finished.get() && !socket.isClosed) {
                val client = socket.accept()
                client.use {
                    val reader = it.getInputStream().bufferedReader()
                    val requestLine = reader.readLine().orEmpty()
                    val target = requestLine.split(" ").getOrNull(1).orEmpty()

                    if (!target.startsWith(AppConfig.OAUTH_REDIRECT_PATH)) {
                        it.getOutputStream().write(response("Waiting for sign-in…").toByteArray())
                        return@use
                    }

                    val params = queryParams(target)
                    val code = params["code"]
                    it.getOutputStream().write(
                        response(if (code != null) SUCCESS_HTML else "No authorization code received.")
                            .toByteArray()
                    )
                    it.getOutputStream().flush()

                    if (code != null && finished.compareAndSet(false, true)) {
                        val port = socket.localPort
                        close()
                        onCode(code, params["state"], port)
                        return
                    }
                }
            }
        } catch (_: java.net.SocketTimeoutException) {
            if (finished.compareAndSet(false, true)) {
                close()
                onTimeout()
            }
        } catch (_: Exception) {
            // Socket closed by cancel(); nothing to report.
        }
    }

    private fun queryParams(target: String): Map<String, String> {
        val query = target.substringAfter('?', "")
        if (query.isEmpty()) return emptyMap()
        return query.split("&").mapNotNull { pair ->
            val name = pair.substringBefore('=', "")
            val value = pair.substringAfter('=', "")
            if (name.isEmpty()) null
            else name to Uri.decode(value)
        }.toMap()
    }

    private fun response(html: String): String {
        val bytes = html.toByteArray(Charsets.UTF_8)
        return "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: ${bytes.size}\r\n" +
            "Connection: close\r\n\r\n" +
            html
    }

    override fun close() {
        runCatching { server?.close() }
        server = null
    }

    private companion object {
        const val TIMEOUT_MS = 5 * 60 * 1000

        /** Same copy and palette as the iOS listener's success page. */
        val SUCCESS_HTML = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><title>Battery</title></head>
            <body style="font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#FAF8F4;color:#2c2c2c">
            <div style="text-align:center"><h2 style="margin:0 0 8px;font-size:28px">Authenticated</h2>
            <p style="color:#888;margin:0">Return to Battery.</p></div></body></html>
        """.trimIndent()
    }
}

