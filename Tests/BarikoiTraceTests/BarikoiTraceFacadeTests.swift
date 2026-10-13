import XCTest
@testable import BarikoiTrace

final class BarikoiTraceFacadeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: "com.barikoi.trace.tests")?.removePersistentDomain(forName: "com.barikoi.trace.tests")
    }

    override func tearDown() {
        BarikoiTrace.logout()
        BarikoiTrace.resetURLs()
        BarikoiTrace.setNotificationConfig(title: nil, content: nil)
        UserDefaults(suiteName: "com.barikoi.trace.tests")?.removePersistentDomain(forName: "com.barikoi.trace.tests")
        super.tearDown()
    }

    func testNotificationConfigGettersAndSetters() {
        BarikoiTrace.setNotificationConfig(title: "Custom Title", content: "Custom Content")
        XCTAssertEqual(BarikoiTrace.getNotificationTitle(), "Custom Title")
        XCTAssertEqual(BarikoiTrace.getNotificationContent(), "Custom Content")

        BarikoiTrace.setNotificationConfig(title: nil, content: nil)
        XCTAssertNil(BarikoiTrace.getNotificationTitle())
        XCTAssertNil(BarikoiTrace.getNotificationContent())
    }

    func testUpdateUserNameThrowsWhenNoUser() async {
        BarikoiTrace.logout()
        do {
            _ = try await BarikoiTrace.updateUserName("Alice")
            XCTFail("Expected noUserError to be thrown")
        } catch let error as TraceError {
            XCTAssertEqual(error.code, TraceError.noUserError().code)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUpdateUserNameThrowsWhenBlankOrWhitespace() async {
        let store = TraceDataStore()
        store.setUser(TraceUser(userId: "u-123", phone: "+8801700000000"))

        for invalid in ["", "   "] {
            do {
                _ = try await BarikoiTrace.updateUserName(invalid)
                XCTFail("Expected noDataError for '\(invalid)'")
            } catch let error as TraceError {
                XCTAssertEqual(error.code, TraceError.noDataError().code)
            } catch {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    func testUpdateUserNameSuccess() async throws {
        let store = TraceDataStore()
        store.setUser(TraceUser(userId: "u-123", name: "OldName", phone: "+8801700000000"))

        let updated = try await BarikoiTrace.updateUserName("  NewName  ")
        XCTAssertEqual(updated.name, "NewName")
        XCTAssertEqual(BarikoiTrace.getUser()?.name, "NewName")
    }

    func testLogoutClearsSessionAndOfflineStore() {
        let store = TraceDataStore()
        store.setUser(TraceUser(userId: "u-123", name: "Test", phone: "+8801700000000"))
        store.setLocalTripId("trip-abc")
        store.setSdkTracking(true)

        BarikoiTrace.logout()

        XCTAssertNil(BarikoiTrace.getUser())
        XCTAssertNil(BarikoiTrace.getUserId())
        XCTAssertNil(BarikoiTrace.getTripId())
        XCTAssertFalse(BarikoiTrace.isOnTrip())
        XCTAssertFalse(store.isSdkTracking())
    }

    func testSetOrCreateUserValidatesPhoneAndApiKey() async {
        do {
            _ = try await BarikoiTrace.setOrCreateUser(phone: "")
            XCTFail("Expected noDataError on empty phone")
        } catch let error as TraceError {
            XCTAssertEqual(error.code, TraceError.noDataError().code)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let store = TraceDataStore()
        store.setApiKey("")
        do {
            _ = try await BarikoiTrace.setOrCreateUser(phone: "+8801700000000")
            XCTFail("Expected noKeyError on empty apiKey")
        } catch let error as TraceError {
            XCTAssertEqual(error.code, TraceError.noKeyError().code)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResetURLsRestoresDefaults() {
        BarikoiTrace.setBaseURL("https://custom.api.com/")
        BarikoiTrace.setMqttURL("tcp://custom.mqtt.com:1883")

        BarikoiTrace.resetURLs()

        let store = TraceDataStore()
        XCTAssertNil(store.getBaseURL())
        XCTAssertNil(store.getMqttURL())
    }
}
