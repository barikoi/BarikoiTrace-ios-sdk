import XCTest
@testable import BarikoiTrace

final class TraceErrorTests: XCTestCase {

    func testFactoryCodesMatchKotlin() {
        XCTAssertEqual(TraceError.noUserError().code, "NO_USER")
        XCTAssertEqual(TraceError.noKeyError().code, "NO_KEY")
        XCTAssertEqual(TraceError.noDataError().code, "NO_DATA")
        XCTAssertEqual(TraceError.networkError().code, "NETWORK")
        XCTAssertEqual(TraceError.locationPermissionError().code, "PERMISSION")
        XCTAssertEqual(TraceError.locationNotFoundError().code, "LOCATION")
        XCTAssertEqual(TraceError.serverError().code, "SERVER")
        XCTAssertEqual(TraceError.tripStateError().code, "TRIP")
        XCTAssertEqual(TraceError.mockAppError().code, "MOCK")
    }

    func testJsonErrorIncludesDetail() {
        let error = TraceError.jsonError("unexpected token")
        XCTAssertEqual(error.code, "JSON")
        XCTAssertTrue(error.message.contains("unexpected token"))
    }

    func testEquatable() {
        XCTAssertEqual(TraceError.networkError(), TraceError.networkError())
        XCTAssertNotEqual(TraceError.networkError(), TraceError.serverError())
    }

    func testLocalizedErrorDescriptionIsMessage() {
        let error = TraceError.noUserError()
        XCTAssertEqual(error.errorDescription, error.message)
    }
}
