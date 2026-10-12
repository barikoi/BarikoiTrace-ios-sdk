import CoreLocation
import XCTest
@testable import BarikoiTrace

final class TraceUserTests: XCTestCase {

    func testMinimalUserInitialization() {
        let user = TraceUser(userId: "u-100")

        XCTAssertEqual(user.userId, "u-100")
        XCTAssertNil(user.phone)
        XCTAssertNil(user.companyId)
        XCTAssertNil(user.group)
        XCTAssertEqual(user.lastLat, 0)
        XCTAssertEqual(user.lastLon, 0)
        XCTAssertGreaterThan(user.updatedAt, 0)
    }

    func testFullUserInitialization() {
        let timestamp: Double = 1_700_000_000_000
        let user = TraceUser(
            userId: "u-200",
            phone: "01700032522",
            companyId: "comp-1",
            group: "group-1",
            lastLat: 23.8103,
            lastLon: 90.4125,
            updatedAt: timestamp
        )

        XCTAssertEqual(user.userId, "u-200")
        XCTAssertEqual(user.phone, "01700032522")
        XCTAssertEqual(user.companyId, "comp-1")
        XCTAssertEqual(user.group, "group-1")
        XCTAssertEqual(user.lastLat, 23.8103)
        XCTAssertEqual(user.lastLon, 90.4125)
        XCTAssertEqual(user.updatedAt, timestamp)
    }

    func testUserEquatable() {
        let user1 = TraceUser(
            userId: "u-1", phone: "01700000000",
            companyId: "c-1", group: "g-1",
            lastLat: 23.0, lastLon: 90.0, updatedAt: 5000
        )
        let user2 = TraceUser(
            userId: "u-1", phone: "01700000000",
            companyId: "c-1", group: "g-1",
            lastLat: 23.0, lastLon: 90.0, updatedAt: 5000
        )
        let user3 = TraceUser(
            userId: "u-2", phone: "01700000000",
            companyId: "c-1", group: "g-1",
            lastLat: 23.0, lastLon: 90.0, updatedAt: 5000
        )

        XCTAssertEqual(user1, user2)
        XCTAssertNotEqual(user1, user3)
    }

    func testPayloadWithoutUserNameDoesNotContainUserNameKey() {
        let loc = CLLocation(latitude: 23.8103, longitude: 90.4125)
        let payload = TraceLocationPayload.dictionary(
            location: loc,
            userId: "u-1",
            companyId: "c-1",
            userName: nil,
            tripId: nil
        )

        XCTAssertNil(payload[TraceLocationPayload.Key.userName])
        XCTAssertEqual(payload[TraceLocationPayload.Key.userId] as? String, "u-1")
        XCTAssertEqual(payload[TraceLocationPayload.Key.companyId] as? String, "c-1")
    }

    func testSparseUserRoundtripInDataStore() {
        let store = TraceDataStore(suiteName: "com.barikoi.trace.tests.sparse")
        defer {
            store.clearUser()
        }

        let sparse = TraceUser(userId: "u-sparse")
        store.setUser(sparse)

        let retrieved = store.getUser()
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.userId, "u-sparse")
        XCTAssertNil(retrieved?.phone)
        XCTAssertNil(retrieved?.companyId)
        XCTAssertNil(retrieved?.group)
    }
}
