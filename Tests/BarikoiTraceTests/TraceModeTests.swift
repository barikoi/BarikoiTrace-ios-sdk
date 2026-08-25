import XCTest
@testable import BarikoiTrace

final class TraceModeTests: XCTestCase {

    func testPresetsMatchKotlinValues() {
        XCTAssertEqual(TraceMode.active.updateInterval, 5)
        XCTAssertEqual(TraceMode.active.accuracyFilter, 50)
        XCTAssertEqual(TraceMode.active.desiredAccuracy, .high)

        XCTAssertEqual(TraceMode.passive.distanceFilter, 100)
        XCTAssertEqual(TraceMode.passive.accuracyFilter, 300)
        XCTAssertEqual(TraceMode.passive.pingSyncInterval, 120)

        XCTAssertEqual(TraceMode.reactive.distanceFilter, 100)
        XCTAssertEqual(TraceMode.reactive.accuracyFilter, 100)
        XCTAssertEqual(TraceMode.reactive.pingSyncInterval, 30)
    }

    func testBuilderFloorsUpdateInterval() {
        let mode = TraceMode.Builder().setUpdateInterval(2).build()
        XCTAssertEqual(mode.updateInterval, 5, "should floor at 5s, matching TraceMode.kt")
    }

    func testBuilderFloorsDistanceFilter() {
        let mode = TraceMode.Builder().setDistanceFilter(3).build()
        XCTAssertEqual(mode.distanceFilter, 10, "should floor at 10m, matching TraceMode.kt")
    }

    func testBuilderFloorsAccuracyFilter() {
        let mode = TraceMode.Builder().setAccuracyFilter(5).build()
        XCTAssertEqual(mode.accuracyFilter, 20, "should floor at 20m, matching TraceMode.kt")
    }

    func testBuilderAcceptsValuesAboveFloor() {
        let mode = TraceMode.Builder()
            .setUpdateInterval(30)
            .setDistanceFilter(50)
            .setAccuracyFilter(100)
            .build()
        XCTAssertEqual(mode.updateInterval, 30)
        XCTAssertEqual(mode.distanceFilter, 50)
        XCTAssertEqual(mode.accuracyFilter, 100)
    }

    func testBuilderProducesCustomTrackingMode() {
        let mode = TraceMode.Builder().build()
        XCTAssertEqual(mode.trackingMode, .custom)
    }

    func testDesiredAccuracyFromStringFallsBackToHigh() {
        XCTAssertEqual(TraceMode.DesiredAccuracy.fromString(nil), .high)
        XCTAssertEqual(TraceMode.DesiredAccuracy.fromString(""), .high)
        XCTAssertEqual(TraceMode.DesiredAccuracy.fromString("not-a-value"), .high)
        XCTAssertEqual(TraceMode.DesiredAccuracy.fromString("MEDIUM"), .medium)
    }
}
