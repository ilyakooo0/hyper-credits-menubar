import XCTest
@testable import UsageMenubar

final class VersionFormatterTests: XCTestCase {

    // MARK: - Fixed-date formatting

    func testFormatExampleFromSpec() {
        // 2026-07-09 14:23 UTC → "2026.07.09.1423"
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 9
        components.hour = 14
        components.minute = 23
        components.timeZone = TimeZone.utc

        let date = Calendar(identifier: .gregorian).date(from: components)!
        let version = VersionFormatter.format(date: date)
        XCTAssertEqual(version, "2026.07.09.1423")
    }

    func testFormatMidnight() {
        // 2026-01-01 00:00 UTC → "2026.01.01.0000"
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.timeZone = TimeZone.utc

        let date = Calendar(identifier: .gregorian).date(from: components)!
        let version = VersionFormatter.format(date: date)
        XCTAssertEqual(version, "2026.01.01.0000")
    }

    func testFormatEndOfDay() {
        // 2026-12-31 23:59 UTC → "2026.12.31.2359"
        var components = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 31
        components.hour = 23
        components.minute = 59
        components.timeZone = TimeZone.utc

        let date = Calendar(identifier: .gregorian).date(from: components)!
        let version = VersionFormatter.format(date: date)
        XCTAssertEqual(version, "2026.12.31.2359")
    }

    func testFormatSingleDigitMonthDay() {
        // 2026-03-05 09:07 UTC → "2026.03.05.0907"
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 5
        components.hour = 9
        components.minute = 7
        components.timeZone = TimeZone.utc

        let date = Calendar(identifier: .gregorian).date(from: components)!
        let version = VersionFormatter.format(date: date)
        XCTAssertEqual(version, "2026.03.05.0907")
    }

    // MARK: - Structure / format validation

    func testVersionHasCorrectNumberOfSegments() {
        let version = VersionFormatter.formatNow()
        let segments = version.split(separator: ".")
        // YYYY.MM.DD.HHHH → 4 segments
        XCTAssertEqual(segments.count, 4)
    }

    func testVersionLastSegmentIsFourDigits() {
        let version = VersionFormatter.formatNow()
        let segments = version.split(separator: ".")
        XCTAssertEqual(segments[3].count, 4, "Last segment should be 4 digits (HHMM)")
    }

    func testVersionOnlyContainsDigitsAndDots() {
        let version = VersionFormatter.formatNow()
        for char in version {
            XCTAssertTrue(char.isNumber || char == ".", "Unexpected character: \(char)")
        }
    }

    // MARK: - Time zone conversion

    func testNonUTCTimeZoneIsConvertedToUTC() {
        // 2026-07-09 14:23 UTC = 2026-07-09 07:23 PDT (UTC-7)
        // Formatting with PDT should produce the UTC version "2026.07.09.1423"
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 9
        components.hour = 7
        components.minute = 23
        components.timeZone = TimeZone(identifier: "America/Los_Angeles") // PDT = UTC-7 in summer

        let date = Calendar(identifier: .gregorian).date(from: components)!
        let version = VersionFormatter.format(date: date, timeZone: TimeZone.utc)
        XCTAssertEqual(version, "2026.07.09.1423")
    }
}
