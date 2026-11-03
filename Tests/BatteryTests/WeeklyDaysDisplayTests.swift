import XCTest
@testable import Battery

final class WeeklyDaysDisplayTests: XCTestCase {

    func testUsedPercentageConvertsToDaysOfTheWeek() {
        XCTAssertEqual(AppSettings.weekDays(forUtilization: 0, remaining: false), 0, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.weekDays(forUtilization: 25, remaining: false), 1.75, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.weekDays(forUtilization: 50, remaining: false), 3.5, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.weekDays(forUtilization: 100, remaining: false), 7, accuracy: 1e-9)
    }

    func testRemainingCountsTheDaysLeft() {
        XCTAssertEqual(AppSettings.weekDays(forUtilization: 25, remaining: true), 5.25, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.weekDays(forUtilization: 100, remaining: true), 0, accuracy: 1e-9)
    }

    func testRemainingNeverGoesNegativeWhenOverTheLimit() {
        XCTAssertEqual(AppSettings.weekDays(forUtilization: 104, remaining: true), 0, accuracy: 1e-9)
    }

    func testFormatsToOneDecimal() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(AppSettings.formatWeekDays(2.5, locale: en), "2.5")
        XCTAssertEqual(AppSettings.formatWeekDays(0, locale: en), "0.0")
        XCTAssertEqual(AppSettings.formatWeekDays(7, locale: en), "7.0")
        XCTAssertEqual(AppSettings.formatWeekDays(1.75, locale: en), "1.8")
    }

    func testFormatUsesTheLocaleDecimalMark() {
        XCTAssertEqual(AppSettings.formatWeekDays(2.5, locale: Locale(identifier: "de_DE")), "2,5")
    }
}
