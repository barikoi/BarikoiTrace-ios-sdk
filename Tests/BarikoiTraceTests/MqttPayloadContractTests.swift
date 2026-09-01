import CoreLocation
import XCTest
@testable import BarikoiTrace

/// Contract test for the work plan's Phase 6: asserts the MQTT payload shape
/// against the Kotlin `dev-v3` schema field-for-field, not just "looks
/// reasonable." This is what actually prevents the `gpx_time`-style drift
/// documented in `docs/WORK_PLAN.md` §2/§7 from recurring — a doc comment
/// saying "match the schema" isn't enough on its own.
///
/// Reference schema (from `MqttManager.kt` / `LocTraceForegroundService.kt`
/// on the Android `dev-v3` branch, audited directly against source):
///   live publish   -> latitude, longitude, gpx_time (epoch-ms number),
///                      user_id, company_id, speed, bearing, altitude,
///                      accuracy, user_name?, trip_id?, trip_status?
///   offline write  -> latitude, longitude, bearing, altitude,
///                      gpx_time ("yyyy-MM-dd HH:mm:ss" UTC string), speed,
///                      accuracy, trip_id?, trip_status?  (NO user_id,
///                      company_id, or user_name at write time)
///   offline flush  -> offline write shape + injected user_id only
///                      (company_id and user_name never get added back)
///
/// This iOS payload is intentionally a single shape used on every path
/// (live, offline-insert, offline-flush) — see `TraceLocationPayload`'s doc
/// comment for the three specific Kotlin divergences this fixes rather than
/// ports.
final class MqttPayloadContractTests: XCTestCase {
    private func makeLocation(
        lat: Double = 23.7808875,
        lon: Double = 90.4179844,
        course: Double = 45.5,
        altitude: Double = 12.3,
        speed: Double = 3.2,
        accuracy: Double = 8.0,
        timestamp: Date = Date(timeIntervalSince1970: 1_745_000_000)
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: altitude,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }

    private func decode(_ json: String) -> [String: Any] {
        let data = Data(json.utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Field set

    func testFullPayloadHasExactKeySet() {
        let json = TraceLocationPayload.json(
            location: makeLocation(), userId: "u1", companyId: "c1", userName: "Jane", tripId: "trip-1"
        )
        let decoded = decode(json)

        let expectedKeys: Set<String> = [
            "latitude", "longitude", "bearing", "altitude", "gpx_time",
            "speed", "accuracy", "user_id", "company_id", "user_name",
            "trip_id", "trip_status"
        ]
        XCTAssertEqual(Set(decoded.keys), expectedKeys)
    }

    func testMinimalPayloadOmitsOptionalKeysRatherThanNulling() {
        let json = TraceLocationPayload.json(
            location: makeLocation(), userId: nil, companyId: nil, userName: nil, tripId: nil
        )
        let decoded = decode(json)

        let alwaysPresent: Set<String> = [
            "latitude", "longitude", "bearing", "altitude", "gpx_time", "speed", "accuracy"
        ]
        XCTAssertEqual(Set(decoded.keys), alwaysPresent)
        XCTAssertNil(decoded["user_id"])
        XCTAssertNil(decoded["company_id"])
        XCTAssertNil(decoded["user_name"])
        XCTAssertNil(decoded["trip_id"])
        XCTAssertNil(decoded["trip_status"])
    }

    func testTripIdAndTripStatusAppearTogetherOnly() {
        let withTrip = decode(TraceLocationPayload.json(
            location: makeLocation(), userId: nil, companyId: nil, userName: nil, tripId: "trip-9"
        ))
        XCTAssertEqual(withTrip["trip_id"] as? String, "trip-9")
        XCTAssertEqual(withTrip["trip_status"] as? String, "active")

        let withoutTrip = decode(TraceLocationPayload.json(
            location: makeLocation(), userId: nil, companyId: nil, userName: nil, tripId: nil
        ))
        XCTAssertNil(withoutTrip["trip_id"])
        XCTAssertNil(withoutTrip["trip_status"])
    }

    // MARK: - gpx_time — the specific defect this test exists to catch

    func testGpxTimeIsAlwaysTheUtcStringFormatNeverEpochMillis() {
        let json = TraceLocationPayload.json(
            location: makeLocation(timestamp: Date(timeIntervalSince1970: 1_745_000_000)),
            userId: "u1", companyId: "c1", userName: nil, tripId: nil
        )
        let decoded = decode(json)

        // Must be a string, never a JSON number (that's the live-path bug on
        // the Kotlin side — gpx_time as epoch-ms — this must never regress).
        XCTAssertTrue(decoded["gpx_time"] is String, "gpx_time must be a string, not a numeric epoch value")

        let gpxTime = decoded["gpx_time"] as? String
        // "yyyy-MM-dd HH:mm:ss" UTC, space separator, no T/Z/millis.
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#
        XCTAssertNotNil(gpxTime)
        XCTAssertTrue(
            gpxTime.map { $0.range(of: pattern, options: .regularExpression) != nil } ?? false,
            "gpx_time '\(gpxTime ?? "nil")' does not match yyyy-MM-dd HH:mm:ss"
        )
        XCTAssertEqual(gpxTime, "2025-04-18 18:13:20") // fixed timestamp above, UTC
    }

    func testGpxTimeIdenticalOnEveryPath() {
        // There is only one payload builder in this SDK (TraceManager routes
        // live-publish, offline-insert, and offline-flush all through
        // TraceLocationPayload) — this test documents that invariant so a
        // future refactor that reintroduces a second builder gets caught.
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let a = decode(TraceLocationPayload.json(
            location: makeLocation(timestamp: ts), userId: "u1", companyId: "c1", userName: nil, tripId: nil
        ))
        let b = decode(TraceLocationPayload.json(
            location: makeLocation(timestamp: ts), userId: nil, companyId: nil, userName: nil, tripId: nil
        ))
        XCTAssertEqual(a["gpx_time"] as? String, b["gpx_time"] as? String)
    }

    // MARK: - Numeric field types (Gson emits numbers for these; JSONSerialization must too)

    func testNumericFieldsAreNumbersNotStrings() {
        let decoded = decode(TraceLocationPayload.json(
            location: makeLocation(), userId: nil, companyId: nil, userName: nil, tripId: nil
        ))
        for key in ["latitude", "longitude", "bearing", "altitude", "speed", "accuracy"] {
            XCTAssertTrue(decoded[key] is NSNumber, "\(key) should decode as a number")
        }
    }

    func testNegativeSpeedAndCourseAreClampedToZero() {
        // CLLocation reports -1 for speed/course when invalid; Kotlin's
        // Android Location API doesn't have this convention, but a negative
        // value is never meaningful here either way — clamp rather than
        // publish a negative speed/bearing.
        let decoded = decode(TraceLocationPayload.json(
            location: makeLocation(course: -1, speed: -1), userId: nil, companyId: nil, userName: nil, tripId: nil
        ))
        XCTAssertEqual(decoded["bearing"] as? Double, 0)
        XCTAssertEqual(decoded["speed"] as? Double, 0)
    }

    // MARK: - Topic / LWT contract

    func testLocationTopicMatchesKotlinPattern() {
        let client = TraceMqttClient(
            host: "broker.example.com", userId: "u1", companyId: "c1", groupId: "g1",
            deviceUUID: "dev-1", mqttUsername: "user", mqttPassword: "pass"
        )
        XCTAssertEqual(client.topic, "company/c1/g1/u1/location")
    }

    func testLwtTopicMatchesKotlinPattern() {
        let client = TraceMqttClient(
            host: "broker.example.com", userId: "u1", companyId: "c1", groupId: "g1",
            deviceUUID: "dev-1", mqttUsername: "user", mqttPassword: "pass"
        )
        XCTAssertEqual(client.lwtTopic, "device/u1/status")
    }

    // MARK: - Completed-trip payload

    /// The Kotlin SDK publishes the *full* location payload on trip
    /// completion (`LocTraceForegroundService.onDestroy` →
    /// `MqttManager.publishLocation(location, tripId, "completed")`), not a
    /// bare id pair. This asserts the ported shape: every live-path field,
    /// plus `trip_id` and `trip_status: "completed"`.
    func testCompletedTripPayloadCarriesFullLocation() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 23.8103, longitude: 90.4125),
            altitude: 12,
            horizontalAccuracy: 8,
            verticalAccuracy: 8,
            course: 90,
            speed: 3,
            timestamp: Date()
        )
        let decoded = decode(TraceLocationPayload.completedTripJson(
            tripId: "trip-42", location: location,
            userId: "user-1", companyId: "company-1", userName: "Rilus"
        ))

        XCTAssertEqual(decoded["trip_id"] as? String, "trip-42")
        XCTAssertEqual(decoded["trip_status"] as? String, "completed")
        XCTAssertEqual(decoded["user_id"] as? String, "user-1")
        XCTAssertEqual(decoded["company_id"] as? String, "company-1")
        XCTAssertEqual(decoded["user_name"] as? String, "Rilus")
        XCTAssertEqual(decoded["latitude"] as? Double, 23.8103)
        XCTAssertEqual(decoded["longitude"] as? Double, 90.4125)
        XCTAssertNotNil(decoded["gpx_time"] as? String)
        XCTAssertNotNil(decoded["speed"])
        XCTAssertNotNil(decoded["accuracy"])
    }

    /// `stopTracking()` can be reached before any fix has arrived. The message
    /// must still be attributable, so identity fields are sent without
    /// coordinates rather than the message being skipped.
    func testCompletedTripPayloadWithoutLocationKeepsIdentity() {
        let decoded = decode(TraceLocationPayload.completedTripJson(
            tripId: "trip-42", location: nil,
            userId: "user-1", companyId: "company-1", userName: nil
        ))

        XCTAssertEqual(decoded["trip_id"] as? String, "trip-42")
        XCTAssertEqual(decoded["trip_status"] as? String, "completed")
        XCTAssertEqual(decoded["user_id"] as? String, "user-1")
        XCTAssertEqual(decoded["company_id"] as? String, "company-1")
        XCTAssertNil(decoded["latitude"])
        XCTAssertNil(decoded["user_name"])
    }

    // MARK: - Flush-time backfill

    /// Mirrors `flushOfflineData()`'s backfill pass: a row queued before
    /// authentication gets `user_id`/`company_id`/`user_name` filled in on the
    /// way out, so it is never published unattributed.
    func testBackfillAddsMissingIdentityFields() {
        let queued = #"{"latitude":23.8,"longitude":90.4}"#
        let decoded = decode(TraceLocationPayload.backfilled(
            json: queued, userId: "user-1", companyId: "company-1", userName: "Rilus"
        ))

        XCTAssertEqual(decoded["user_id"] as? String, "user-1")
        XCTAssertEqual(decoded["company_id"] as? String, "company-1")
        XCTAssertEqual(decoded["user_name"] as? String, "Rilus")
        XCTAssertEqual(decoded["latitude"] as? Double, 23.8)
    }

    /// Values already on the row win — a fix written while user A was signed
    /// in must not be re-attributed to user B at flush time.
    func testBackfillNeverOverwritesExistingValues() {
        let queued = #"{"user_id":"original","latitude":23.8}"#
        let decoded = decode(TraceLocationPayload.backfilled(
            json: queued, userId: "replacement", companyId: "company-1", userName: nil
        ))

        XCTAssertEqual(decoded["user_id"] as? String, "original")
        XCTAssertEqual(decoded["company_id"] as? String, "company-1")
    }

    func testBackfillLeavesUnparseableRowsUntouched() {
        let garbage = "not json"
        XCTAssertEqual(
            TraceLocationPayload.backfilled(
                json: garbage, userId: "user-1", companyId: nil, userName: nil
            ),
            garbage
        )
    }
}
