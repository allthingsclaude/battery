package com.allthingsclaude.battery.core

import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URI

/**
 * The default [UsageApi.HttpTransport], on `HttpURLConnection`.
 *
 * Plain JDK networking rather than OkHttp: it's two requests, `HttpURLConnection`
 * is present on both the JVM and Android, and keeping it here means `core` needs
 * no third-party runtime dependency at all. Android's implementation of this
 * class is OkHttp underneath anyway.
 */
class UrlConnectionTransport : UsageApi.HttpTransport {

    override fun request(
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String?,
    ): UsageApi.HttpTransport.Response {
        val connection = URI(url).toURL().openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = method
            // HttpURLConnection forwards request headers across a same-scheme
            // redirect, which would carry the Bearer token to whatever host the
            // redirect names. Nothing we call redirects; make that explicit
            // rather than trusting it.
            connection.instanceFollowRedirects = false
            connection.connectTimeout = AppConfig.REQUEST_TIMEOUT_SECONDS * 1000
            connection.readTimeout = AppConfig.REQUEST_TIMEOUT_SECONDS * 1000
            headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }

            if (body != null) {
                connection.doOutput = true
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }

            val code = connection.responseCode
            // A 4xx/5xx puts the body on the error stream, not the input stream,
            // and reading the wrong one throws — which would surface a perfectly
            // clear "429 Too Many Requests" as an opaque IOException.
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader()?.use(BufferedReader::readText).orEmpty()

            UsageApi.HttpTransport.Response(
                code = code,
                body = text,
                // Case-INSENSITIVE. HTTP/2 mandates lowercase field names on
                // the wire and api.anthropic.com serves h2, so the header
                // arrives as `retry-after`; a plain LinkedHashMap lookup for
                // "Retry-After" silently returns null and the server's requested
                // backoff is ignored entirely.
                headers = java.util.TreeMap<String, String>(String.CASE_INSENSITIVE_ORDER).apply {
                    connection.headerFields.forEach { (name, values) ->
                        if (name != null) put(name, values.firstOrNull().orEmpty())
                    }
                },
            )
        } finally {
            // Deliberately NOT disconnect(): that tears down the pooled
            // connection and makes every poll pay a fresh TLS handshake.
            // Closing the streams is enough to return it to the pool.
            runCatching { connection.inputStream?.close() }
            runCatching { connection.errorStream?.close() }
        }
    }
}
