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
                headers = connection.headerFields
                    .filterKeys { it != null }
                    .mapValues { it.value.firstOrNull().orEmpty() },
            )
        } finally {
            connection.disconnect()
        }
    }
}
