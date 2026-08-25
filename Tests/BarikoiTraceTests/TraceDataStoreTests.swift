import XCTest
@testable import BarikoiTrace

/// Exercises TraceDataStore against a dedicated suite/Keychain-service name
/// (`"com.barikoi.trace.tests"`) so these tests never touch a real app's
/// stored identity, and clears everything in tearDown so runs don't leak
/// into each other. Keychain access is expected to work under the iOS
/// Simulator this test target runs against in CI; no special entitlement
/// should be needed there.
final class TraceDataStoreTests: XCTestCase {
    private var store: TraceDataStore!

    override func setUp() {
        super.setUp()
        store = TraceDataStore(suiteName: "com.barikoi.trace.tests")
    }

    override func tearDown() {
        store.clearUser()
        store.resetURLs()
        store.stopSdkTracking()
        store.clearLocalTrip()
        store = nil
        super.tearDown()
    }

    // MARK: - API key / MQTT credentials

    func testApiKeyRoundtrip() {
        XCTAssertNil(store.getApiKey())
        store.setApiKey("key-123")
        XCTAssertEqual(store.getApiKey(), "key-123")
    }

    func testMqttCredentialsRoundtrip() {
        store.setMqttCredentials(username: "user", password: "pass")
        XCTAssertEqual(store.getMqttUsername(), "user")
        XCTAssertEqual(store.getMqttPassword(), "pass")
    }

    // MARK: - URLs

    func testBaseURLDefaultsToNilThenRoundtrips() {
        XCTAssertNil(store.getBaseURL())
        store.setBaseURL("https://staging.example.com/api/v1/")
        XCTAssertEqual(store.getBaseURL(), "https://staging.example.com/api/v1/")
    }

    func testResetURLsClearsBoth() {
        store.setBaseURL("https://staging.example.com/")
        store.setMqttURL("tcp://staging-broker:1883")
        store.resetURLs()
        XCTAssertNil(store.getBaseURL())
        XCTAssertNil(store.getMqttURL())
    }

    // MARK: - User

    func testUserRoundtrip() {
        let user = TraceUser(
            userId: "u1", name: "Jane", email: "jane@example.com", phone: "+8801700000000",
            companyId: "c1", group: "g1", updatedAt: 1_000
        )
        store.setUser(user)

        let fetched = store.getUser()
        XCTAssertEqual(fetched?.userId, "u1")
        XCTAssertEqual(fetched?.name, "Jane")
        XCTAssertEqual(fetched?.companyId, "c1")
        XCTAssertEqual(fetched?.group, "g1")
        XCTAssertEqual(fetched?.updatedAt, 1_000)
        XCTAssertEqual(store.getUserId(), "u1")
    }

    func testClearUserRemovesEverything() {
        store.setUser(TraceUser(userId: "u1", phone: "+8801700000000"))
        store.clearUser()
        XCTAssertNil(store.getUser())
        XCTAssertNil(store.getUserId())
    }

    // MARK: - Tracking state

    func testSdkTrackingDefaultsFalse() {
        XCTAssertFalse(store.isSdkTracking())
        store.setSdkTracking(true)
        XCTAssertTrue(store.isSdkTracking())
    }

    func testStopSdkTrackingClearsModeToo() {
        store.setTraceMode(.active)
        store.setSdkTracking(true)

        store.stopSdkTracking()

        XCTAssertFalse(store.isSdkTracking())
        // getTraceMode() falls back to defaults once the stored mode is cleared.
        let mode = store.getTraceMode()
        XCTAssertEqual(mode.updateInterval, 5)
        XCTAssertEqual(mode.accuracyFilter, 200)
    }

    func testLocalTripIdRoundtrip() {
        XCTAssertNil(store.getLocalTripId())
        store.setLocalTripId("trip-1")
        XCTAssertEqual(store.getLocalTripId(), "trip-1")
        store.clearLocalTrip()
        XCTAssertNil(store.getLocalTripId())
    }

    // MARK: - TraceMode

    func testTraceModeRoundtrip() {
        let mode = TraceMode.Builder()
            .setUpdateInterval(30)
            .setDistanceFilter(50)
            .setAccuracyFilter(75)
            .setDesiredAccuracy(.medium)
            .setPingSyncInterval(15)
            .build()

        store.setTraceMode(mode)
        let fetched = store.getTraceMode()

        XCTAssertEqual(fetched.updateInterval, 30)
        XCTAssertEqual(fetched.distanceFilter, 50)
        XCTAssertEqual(fetched.accuracyFilter, 75)
        XCTAssertEqual(fetched.desiredAccuracy, .medium)
        XCTAssertEqual(fetched.pingSyncInterval, 15)
    }

    func testTraceModeWithTimingRoundtripsStartEndTime() {
        var start = DateComponents()
        start.hour = 8
        start.minute = 0
        start.second = 0
        var end = DateComponents()
        end.hour = 18
        end.minute = 30
        end.second = 0

        let mode = TraceMode.Builder()
            .setUpdateInterval(10)
            .setStartTime(start)
            .setEndTime(end)
            .build()

        store.setTraceModeWithTiming(mode)
        let fetched = store.getTraceMode()

        XCTAssertEqual(fetched.startTime.hour, 8)
        XCTAssertEqual(fetched.endTime.hour, 18)
        XCTAssertEqual(fetched.endTime.minute, 30)
    }

    func testClearTraceModeWithTimingRemovesWindow() {
        let mode = TraceMode.Builder().setUpdateInterval(10).build()
        store.setTraceModeWithTiming(mode)
        store.clearTraceModeWithTiming()

        // Falls back to the default full-day window once cleared.
        let fetched = store.getTraceMode()
        XCTAssertEqual(fetched.startTime, TraceMode.dayStart)
        XCTAssertEqual(fetched.endTime, TraceMode.dayEnd)
    }
}
