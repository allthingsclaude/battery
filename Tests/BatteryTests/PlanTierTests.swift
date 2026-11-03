import XCTest
@testable import Battery

final class PlanTierTests: XCTestCase {

    func testFromRateLimitTier() {
        XCTAssertEqual(PlanTier.from(rateLimitTier: "claude_pro"), .pro)
        XCTAssertEqual(PlanTier.from(rateLimitTier: "claude_max"), .max)
        XCTAssertEqual(PlanTier.from(rateLimitTier: "claude_max_5x"), .max5x)
        XCTAssertEqual(PlanTier.from(rateLimitTier: "something_else"), .unknown)
    }

    /// Ultra accounts still report the Max 20x tier, which contains "max" — it
    /// must not fall through to plain Max.
    func testTwentyXIsUltra() {
        XCTAssertEqual(PlanTier.from(rateLimitTier: "default_claude_max_20x"), .ultra)
        XCTAssertEqual(PlanTier.from(rateLimitTier: "claude_max20x"), .ultra)
        XCTAssertEqual(PlanTier.from(rateLimitTier: "default_claude_ultra"), .ultra)
    }

    /// The 2026-10-30 rename: Max 20x is Ultra, Max 5x is plain Max.
    func testDisplayNamesFollowTheRename() {
        XCTAssertEqual(PlanTier.ultra.displayName, "Ultra")
        XCTAssertEqual(PlanTier.max5x.displayName, "Max")
        XCTAssertEqual(PlanTier.max.displayName, "Max")
        XCTAssertEqual(PlanTier.pro.displayName, "Pro")
    }

    /// Raw values are persisted on accounts and snapshot rows, so the renamed
    /// tier must keep reading back from what older builds wrote.
    func testPersistedRawValuesStillDecode() {
        XCTAssertEqual(PlanTier(rawValue: "max_5x"), .max5x)
        XCTAssertEqual(PlanTier(rawValue: "max"), .max)
    }

    func testOpusAccess() {
        XCTAssertFalse(PlanTier.pro.hasOpusAccess)
        XCTAssertTrue(PlanTier.max.hasOpusAccess)
        XCTAssertTrue(PlanTier.max5x.hasOpusAccess)
        XCTAssertTrue(PlanTier.ultra.hasOpusAccess)
    }
}
