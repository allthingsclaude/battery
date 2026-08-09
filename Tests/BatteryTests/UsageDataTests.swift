import XCTest
@testable import Battery

final class UsageDataTests: XCTestCase {

    func testDecodeFullResponse() throws {
        let json = """
        {
            "five_hour": {
                "utilization": 45.2,
                "resets_at": "2025-01-15T15:30:00Z"
            },
            "seven_day": {
                "utilization": 23.8,
                "resets_at": "2025-01-20T00:00:00Z"
            },
            "seven_day_sonnet": {
                "utilization": 12.1,
                "resets_at": "2025-01-20T00:00:00Z"
            },
            "seven_day_opus": {
                "utilization": 67.3,
                "resets_at": "2025-01-20T00:00:00Z"
            },
            "extra_usage": {
                "is_enabled": true,
                "monthly_limit": 100.0,
                "used_credits": 4.50,
                "utilization": 4.5
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertEqual(response.fiveHour?.utilization, 45.2)
        XCTAssertEqual(response.sevenDay.utilization, 23.8)
        XCTAssertEqual(response.sevenDaySonnet?.utilization, 12.1)
        XCTAssertEqual(response.sevenDayOpus?.utilization, 67.3)
        XCTAssertEqual(response.extraUsage?.isEnabled, true)
        XCTAssertEqual(response.extraUsage?.usedCredits, 4.50)
    }

    func testDecodeMinimalResponse() throws {
        let json = """
        {
            "five_hour": {
                "utilization": 10.0,
                "resets_at": "2025-01-15T15:30:00Z"
            },
            "seven_day": {
                "utilization": 5.0,
                "resets_at": "2025-01-20T00:00:00Z"
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertEqual(response.fiveHour?.utilization, 10.0)
        XCTAssertNil(response.sevenDaySonnet)
        XCTAssertNil(response.sevenDayOpus)
        XCTAssertNil(response.extraUsage)
    }

    func testDecodeRealAPIResponse() throws {
        // Matches the actual API response format with null fields and extra keys
        let json = """
        {
            "five_hour": {
                "utilization": 100.0,
                "resets_at": "2026-02-06T18:00:00.406306+00:00"
            },
            "seven_day": {
                "utilization": 46.0,
                "resets_at": "2026-02-08T14:00:00.406328+00:00"
            },
            "seven_day_oauth_apps": null,
            "seven_day_opus": null,
            "seven_day_sonnet": {
                "utilization": 6.0,
                "resets_at": "2026-02-10T13:00:00.406334+00:00"
            },
            "seven_day_cowork": null,
            "iguana_necktie": null,
            "extra_usage": {
                "is_enabled": false,
                "monthly_limit": null,
                "used_credits": null,
                "utilization": null
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertEqual(response.fiveHour?.utilization, 100.0)
        XCTAssertEqual(response.sevenDay.utilization, 46.0)
        XCTAssertEqual(response.sevenDaySonnet?.utilization, 6.0)
        XCTAssertNil(response.sevenDayOpus)
        XCTAssertEqual(response.extraUsage?.isEnabled, false)
        XCTAssertNil(response.extraUsage?.usedCredits)
    }

    /// Fable has no `seven_day_fable` bucket — it is only ever reported as a
    /// `weekly_scoped` entry in `limits`, identified by its model display name.
    func testDecodeFableFromLimits() throws {
        let json = """
        {
            "five_hour": { "utilization": 25.0, "resets_at": "2026-01-15T18:00:00.111111+00:00" },
            "seven_day": { "utilization": 40.0, "resets_at": "2026-01-20T06:00:00.222222+00:00" },
            "seven_day_opus": null,
            "seven_day_sonnet": null,
            "limits": [
                {
                    "group": "session", "is_active": false, "kind": "session",
                    "percent": 25, "resets_at": "2026-01-15T18:00:00.111111+00:00",
                    "scope": null, "severity": "normal"
                },
                {
                    "group": "weekly", "is_active": false, "kind": "weekly_all",
                    "percent": 40, "resets_at": "2026-01-20T06:00:00.222222+00:00",
                    "scope": null, "severity": "normal"
                },
                {
                    "group": "weekly", "is_active": true, "kind": "weekly_scoped",
                    "percent": 55, "resets_at": "2026-01-20T06:00:00.333333+00:00",
                    "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null },
                    "severity": "normal"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertEqual(response.fableUtilization, 55)
        XCTAssertNotNil(response.fableLimit?.resetsAtDate)
        // The session and weekly_all entries restate top-level buckets — they
        // must not be mistaken for a per-model window.
        XCTAssertEqual(response.limits.count, 3)
        XCTAssertNil(response.sevenDayOpus)
    }

    /// A response with no Fable usage must leave the gauge off rather than
    /// showing 0%, and the older shape has no `limits` array at all.
    func testFableAbsentWhenNotInLimits() throws {
        let json = """
        {
            "five_hour": { "utilization": 10.0, "resets_at": "2025-01-15T15:30:00Z" },
            "seven_day": { "utilization": 5.0, "resets_at": "2025-01-20T00:00:00Z" }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertNil(response.fableUtilization)
        XCTAssertTrue(response.limits.isEmpty)
    }

    /// `display_name` is the only identifier the API offers (`id` is null), so
    /// the match must not be thrown by casing.
    func testFableModelNameMatchIsCaseInsensitive() throws {
        let json = """
        {
            "seven_day": { "utilization": 5.0, "resets_at": "2025-01-20T00:00:00Z" },
            "limits": [
                {
                    "kind": "weekly_scoped", "percent": 31, "is_active": true,
                    "resets_at": "2025-01-20T00:00:00Z",
                    "scope": { "model": { "display_name": "fable", "id": null } }
                }
            ]
        }
        """.data(using: .utf8)!

        XCTAssertEqual(try JSONDecoder().decode(UsageResponse.self, from: json).fableUtilization, 31)
    }

    /// A scoped window for some other model must not be read as Fable's.
    func testOtherScopedModelIsNotTreatedAsFable() throws {
        let json = """
        {
            "seven_day": { "utilization": 5.0, "resets_at": "2025-01-20T00:00:00Z" },
            "limits": [
                {
                    "kind": "weekly_scoped", "percent": 88, "is_active": true,
                    "resets_at": "2025-01-20T00:00:00Z",
                    "scope": { "model": { "display_name": "Opus", "id": null } }
                }
            ]
        }
        """.data(using: .utf8)!

        XCTAssertNil(try JSONDecoder().decode(UsageResponse.self, from: json).fableUtilization)
    }

    func testResetsAtDateParsing() {
        let bucket = UsageBucket(utilization: 50.0, resetsAt: "2025-01-15T15:30:00Z")
        let date = bucket.resetsAtDate
        XCTAssertNotNil(date)
    }

    func testResetsAtDateWithFractionalSeconds() {
        let bucket = UsageBucket(utilization: 50.0, resetsAt: "2026-02-06T18:00:00.406306+00:00")
        let date = bucket.resetsAtDate
        XCTAssertNotNil(date)
    }
}
