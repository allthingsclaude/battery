package com.allthingsclaude.battery.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.time.Instant
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Runs `fixtures/usage-forecast.json`.
 *
 * This covers the outlook/pace state machine and every user-visible string —
 * the most drift-prone surface in the port, and the one the Swift suite has no
 * tests for at all. Expected values were derived by hand from
 * `ios/BatteryKit/UsageForecast.swift`, never by running this Kotlin; each case
 * carries a `why` spelling out the arithmetic so a reader can check it.
 */
class UsageForecastFixtureTest {

    private val fixtures: File = System.getProperty("battery.fixtures")
        ?.let(::File)
        ?.takeIf { it.isDirectory }
        ?: fail("Fixture directory not found; core/build.gradle.kts passes -Dbattery.fixtures.")

    private val now: Instant = Instant.parse("2026-01-01T12:00:00Z")

    @Test
    fun `forecast matches the hand-derived Swift behaviour`() {
        val cases = Json.parseToJsonElement(
            File(fixtures, "usage-forecast.json").readText()
        ).jsonObject["cases"]!!.jsonArray

        assertTrue(cases.isNotEmpty(), "fixture has no cases")

        for (element in cases) {
            val case = element.jsonObject
            val name = case["name"]!!.jsonPrimitive.content

            val forecast = UsageForecast(
                utilization = case["utilization"]!!.jsonPrimitive.double,
                resetsAt = case["resetsAtOffsetSeconds"]
                    ?.jsonPrimitive?.double
                    ?.let { now.plusSeconds(it.toLong()) },
                burnRatePerHour = case["burnRatePerHour"]?.jsonPrimitive?.double ?: 0.0,
                projectedLimitAt = case["projectedLimitAtOffsetSeconds"]
                    ?.jsonPrimitive?.double
                    ?.let { now.plusSeconds(it.toLong()) },
                isSessionActive = case["isSessionActive"]?.jsonPrimitive?.boolean ?: false,
                now = now,
            )

            val expect = case["expect"]!!.jsonObject

            expect["outlook"]?.let {
                assertEquals(it.jsonPrimitive.content, forecast.outlook.name, "$name → outlook")
            }
            expect["pace"]?.let {
                assertEquals(it.jsonPrimitive.content, forecast.pace.name, "$name → pace")
            }
            expect["headline"]?.let {
                assertEquals(it.jsonPrimitive.content, forecast.headline, "$name → headline")
            }
            expect["badgeLabel"]?.let {
                assertEquals(it.jsonPrimitive.content, forecast.badgeLabel, "$name → badgeLabel")
            }
            expect["limitIsAnchored"]?.let {
                assertEquals(
                    it.jsonPrimitive.boolean,
                    forecast.limitIsAnchored,
                    "$name → limitIsAnchored",
                )
            }
            expect["projectedAtReset"]?.let {
                val expected = it.jsonPrimitive.double
                assertTrue(
                    abs(forecast.projectedAtReset - expected) < 0.5,
                    "$name → projectedAtReset: expected $expected, was ${forecast.projectedAtReset}",
                )
            }
            // `detail` is nullable, and JSON null is a meaningful expectation
            // here — one case asserts there is no second line at all.
            expect["detail"]?.let {
                if (it is JsonNull) {
                    assertNull(forecast.detail, "$name → detail should be absent")
                } else {
                    assertEquals(it.jsonPrimitive.content, forecast.detail, "$name → detail")
                }
            }
            expect["landingStat"]?.jsonObject?.let { stat ->
                val actual = forecast.landingStat
                assertEquals(
                    stat["label"]!!.jsonPrimitive.content,
                    actual.label,
                    "$name → landingStat.label",
                )
                assertEquals(
                    stat["value"]!!.jsonPrimitive.content,
                    actual.value,
                    "$name → landingStat.value",
                )
                assertEquals(
                    stat["isUrgent"]!!.jsonPrimitive.boolean,
                    actual.isUrgent,
                    "$name → landingStat.isUrgent",
                )
            }
        }
    }

    @Test
    fun `every forecast case explains its arithmetic`() {
        // The other fixtures assert a `from` naming a Swift test. These cases
        // have no Swift test to name, so the guarantee has to be different: each
        // one states how its expected values were derived, which is what makes
        // the file auditable rather than a snapshot of whatever the code did.
        val cases = Json.parseToJsonElement(
            File(fixtures, "usage-forecast.json").readText()
        ).jsonObject["cases"]!!.jsonArray

        for (element in cases) {
            val case = element.jsonObject
            val why = case["why"]?.jsonPrimitive?.content
            assertTrue(
                !why.isNullOrBlank(),
                "case '${case["name"]?.jsonPrimitive?.content}' has no `why`",
            )
        }
    }

    /**
     * The one invariant that holds across every case regardless of the fixture:
     * a forecast built from a payload must equal one built from the same fields
     * passed individually. The convenience constructor is what every surface
     * actually calls, so a mismatch there would make the fixtures meaningless.
     */
    @Test
    fun `the payload constructor agrees with the explicit one`() {
        val payload = UsagePayload(
            sessionUtilization = 62.0,
            sessionResetsAt = now.plusSeconds(5400),
            weeklyUtilization = 10.0,
            weeklyResetsAt = now.plusSeconds(86_400),
            burnRatePerHour = 12.5,
            projectedLimitAt = now.plusSeconds(2400),
            isSessionActive = true,
            updatedAt = now,
        )

        val fromPayload = UsageForecast(payload, now = now)
        val explicit = UsageForecast(
            utilization = payload.sessionUtilization,
            resetsAt = payload.sessionResetsAt,
            burnRatePerHour = payload.burnRatePerHour,
            projectedLimitAt = payload.projectedLimitAt,
            isSessionActive = payload.isSessionActive,
            now = now,
        )

        assertEquals(explicit.outlook, fromPayload.outlook)
        assertEquals(explicit.pace, fromPayload.pace)
        assertEquals(explicit.headline, fromPayload.headline)
        assertEquals(explicit.detail, fromPayload.detail)
        assertEquals(explicit.badgeLabel, fromPayload.badgeLabel)
    }
}
