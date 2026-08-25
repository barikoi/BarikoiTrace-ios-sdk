import XCTest
@testable import BarikoiTrace

final class DateTimeUtilsTests: XCTestCase {

    func testDateTimeLocalFormat() {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 15
        components.hour = 10
        components.minute = 30
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")

        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(DateTimeUtils.dateTimeLocal(from: date), "2026-06-15 10:30:00")
    }

    func testCurrentTimeLocalMatchesExpectedShape() {
        let value = DateTimeUtils.currentTimeLocal()
        // yyyy-MM-dd HH:mm:ss is exactly 19 characters.
        XCTAssertEqual(value.count, 19)
        XCTAssertTrue(value.contains("-"))
        XCTAssertTrue(value.contains(":"))
    }
}
