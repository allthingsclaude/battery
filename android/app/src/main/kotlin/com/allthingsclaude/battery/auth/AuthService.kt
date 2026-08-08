package com.allthingsclaude.battery.auth

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.browser.customtabs.CustomTabsClient
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

    // Written from the UI thread (start/cancel) and read from the loopback
    // daemon thread. Volatile for the happens-before edge; the attempt's own
    // state is captured rather than read back off the field, so a re-tap during
    // an in-flight exchange can't make attempt 1 send attempt 2's value.
    @Volatile
    private var listener: LoopbackListener? = null

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

        val server = LoopbackListener(
            expectedState = oauthState,
            onCode = { code, returnedState, port ->
                // Note the absence of a null check. An earlier version read
                // `returnedState != null && returnedState != oauthState`, which
                // fired only on a WRONG state and never on a MISSING one — so
                // omitting the parameter skipped the guard completely. That is
                // an authorization-code injection: any local app can probe
                // loopback ports, POST its own `?code=` with no `state`, and
                // bind this install to an account the user does not control.
                // PKCE does not cover it — PKCE binds the code to *our*
                // verifier, which is precisely what makes an attacker's code
                // exchangeable by us.
                //
                // Redundant by construction now that the listener holds
                // `expectedState` and will not call this on a mismatch. Kept
                // anyway: it costs one comparison, and the failure it prevents
                // is binding the install to somebody else's account.
                if (returnedState != oauthState) {
                    onResult(Result.Failure("Sign-in failed: state mismatch."))
                    return@LoopbackListener
                }
                onResult(exchange(code, codeVerifier, port, oauthState))
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

        // launchUrl is a bare implicit ACTION_VIEW that catches nothing, so on a
        // device where no browser resolves https — a work profile, a managed
        // device with the browser disabled, an AOSP build — this throws
        // ActivityNotFoundException straight out of a Compose onClick and takes
        // the process with it. The listener is already bound and its thread
        // already running by this point, so failing without tearing that down
        // would also leak both. The immediately preceding failure (a socket that
        // will not bind) is handled; this one was not.
        val launched = runCatching {
            val tab = CustomTabsIntent.Builder().setShowTitle(true).build()
            // Pin the request to a real browser where one can be identified.
            // RFC 8252 asks for this, and the reason is specific to what this
            // URL carries: `state` is the only thing standing between the
            // loopback listener and an injected authorization code, and it is a
            // query parameter — so every app that can resolve the intent reads
            // it. An unpinned ACTION_VIEW hands that to whatever the system
            // picks, including a disambiguation dialog the user may mis-tap.
            browserPackage(context)?.let { tab.intent.setPackage(it) }
            tab.launchUrl(context, authorizeUrl)
        }
        if (launched.isFailure) {
            cancel()
            onResult(Result.Failure("No browser available to sign in."))
        }
    }

    /**
     * A browser to pin the authorization request to, or null to let the system
     * choose.
     *
     * Prefers a Custom Tabs provider, then the user's default browser. Returns
     * null rather than guessing when neither resolves — pinning to an arbitrary
     * entry out of a chooser list would be worse than the implicit launch,
     * because it would silently pick for the user rather than letting them pick.
     *
     * The `android` package is the system's own ResolverActivity, which is what
     * comes back when no default browser is set; treating that as a package to
     * pin would make the launch fail outright.
     *
     * This is not complete protection and should not be described as such: an
     * app that registers a hostless https filter *is* a browser as far as the
     * platform is concerned, and if the user makes it the default it will be
     * chosen here. What this closes is every non-browser interception path and
     * the mis-tapped chooser.
     */
    private fun browserPackage(context: Context): String? {
        CustomTabsClient.getPackageName(context, null)?.let { return it }

        val probe = Intent(Intent.ACTION_VIEW, Uri.parse("https://claude.ai"))
            .addCategory(Intent.CATEGORY_BROWSABLE)
        val resolved = context.packageManager
            .resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY)
            ?.activityInfo
            ?.packageName
        return resolved?.takeUnless { it == "android" || it.isEmpty() }
    }

    /** Tear down any in-flight attempt. Safe to call repeatedly. */
    fun cancel() {
        listener?.close()
        listener = null
    }

    private fun exchange(
        code: String,
        codeVerifier: String,
        port: Int,
        oauthState: String,
    ): Result {
        val body = JsonBody()
            .put("grant_type", "authorization_code")
            .put("code", code)
            .put("client_id", AppConfig.OAUTH_CLIENT_ID)
            .put("code_verifier", codeVerifier)
            .put("redirect_uri", redirectUri(port))
            .put("state", oauthState)
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
        }
        // Deliberately no `finally { cancel() }`. The listener has already closed
        // itself on the success path, and cancelling here would tear down a
        // *newer* attempt's listener if the user re-tapped sign-in while this
        // exchange was in flight — leaving that attempt's redirect to hit a
        // closed port.
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
    /**
     * The `state` this attempt will accept, checked *before* the attempt is
     * consumed. Held here rather than only in the caller because the caller runs
     * too late to matter: the listener used to commit on the mere presence of a
     * `code`, setting its one-shot flag and closing the socket, and only then
     * hand the state up to be rejected. A local app that guessed the port could
     * therefore kill every sign-in attempt with `GET /callback?code=x` — the
     * user's browser then hit a closed socket, and the error blamed a state
     * mismatch. The listener is trivially findable, too: it answers every other
     * path with a fixed string.
     */
    private val expectedState: String,
    private val onCode: (code: String, state: String?, port: Int) -> Unit,
    private val onTimeout: () -> Unit,
) : Closeable {

    @Volatile
    private var server: ServerSocket? = null
    private val finished = AtomicBoolean(false)
    private var deadline: Long = 0L

    fun start(): Int? = try {
        val socket = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        // An ABSOLUTE deadline, not a per-accept timeout. soTimeout applies to
        // each accept() call individually, so any stray request — a favicon
        // probe, or a hostile local app connecting once a minute — completes an
        // iteration and restarts the clock, keeping the listener alive
        // indefinitely.
        deadline = System.nanoTime() + TIMEOUT_MS * 1_000_000L
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
                val remainingMs = (deadline - System.nanoTime()) / 1_000_000L
                if (remainingMs <= 0) throw java.net.SocketTimeoutException("attempt expired")
                socket.soTimeout = remainingMs.coerceAtMost(TIMEOUT_MS.toLong()).toInt()

                val client = socket.accept()
                client.use {
                    // accept() has a timeout; the accepted socket does not. Any
                    // local app could connect and send nothing, blocking
                    // readLine() forever — the loop would never return to
                    // accept(), so the attempt would neither complete nor time
                    // out, leaking both sockets and the thread.
                    it.soTimeout = CLIENT_READ_TIMEOUT_MS
                    val reader = it.getInputStream().bufferedReader()
                    // Scoped to this connection. Letting a read timeout reach
                    // the outer handler turns "one local app connected and said
                    // nothing" into "the sign-in was cancelled" — a second way
                    // for a stranger to end the attempt with one socket.
                    val requestLine = try {
                        reader.readLine().orEmpty()
                    } catch (_: java.net.SocketTimeoutException) {
                        return@use
                    }
                    val target = requestLine.split(" ").getOrNull(1).orEmpty()

                    // Exact path, not a prefix: `startsWith` also matches
                    // `/callbackXYZ`, and there is no reason to accept a code on
                    // a path we never advertised.
                    val path = target.substringBefore('?')
                    if (path != AppConfig.OAUTH_REDIRECT_PATH) {
                        it.getOutputStream().write(response("Waiting for sign-in…").toByteArray())
                        return@use
                    }

                    val params = queryParams(target)
                    val code = params["code"]
                    val returnedState = params["state"]

                    // Anything that is not *our* redirect is answered and
                    // ignored, exactly like an unknown path — it must not
                    // consume the attempt. A missing state counts as wrong.
                    if (code == null || returnedState != expectedState) {
                        it.getOutputStream()
                            .write(response("Waiting for sign-in…").toByteArray())
                        it.getOutputStream().flush()
                        return@use
                    }

                    it.getOutputStream().write(response(SUCCESS_HTML).toByteArray())
                    it.getOutputStream().flush()

                    if (finished.compareAndSet(false, true)) {
                        val port = socket.localPort
                        close()
                        onCode(code, returnedState, port)
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
        const val CLIENT_READ_TIMEOUT_MS = 10 * 1000

        /** Same copy and palette as the iOS listener's success page. */
        val SUCCESS_HTML = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><title>Battery</title></head>
            <body style="font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#FAF8F4;color:#2c2c2c">
            <div style="text-align:center"><h2 style="margin:0 0 8px;font-size:28px">Authenticated</h2>
            <p style="color:#888;margin:0">Return to Battery.</p></div></body></html>
        """.trimIndent()
    }
}

