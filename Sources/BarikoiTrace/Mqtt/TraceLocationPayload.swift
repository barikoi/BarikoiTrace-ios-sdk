import CoreLocation
import Foundation

/// Builds the MQTT location-publish JSON payload. Pulled out of `TraceManager`
/// into its own type for two reasons: it's the one piece of this SDK with a
/// hard cross-platform contract (the Kotlin broker/consumer side parses this
/// shape), and it needs to be independently unit-testable rather than buried
/// as a private helper.
///
/// Deliberately **one** code path for both the live-publish and the
/// offline-insert/offline-flush cases (`TraceManager.persistOrPublish` calls
/// this once and either publishes the result immediately or stores it in
/// `OfflineLocationStore` verbatim) — see the work plan's Phase 0 and defect
/// carry-forward checklist. The Kotlin SDK (`MqttManager.kt` /
/// `LocTraceForegroundService.kt`) currently has three divergences this type
/// intentionally does not reproduce:
///   1. `gpx_time` is a numeric epoch-ms value on the live path but a
///      `"yyyy-MM-dd HH:mm:ss"` UTC string on the offline path. Here it is
///      always the UTC string (`DateTimeUtils.dateTimeLocal`), everywhere.
///   2. The offline-flush payload is missing `company_id` (only `user_id`
///      gets injected at flush time). Here `company_id` is present on every
///      payload whenever the caller has one, live or queued.
///   3. The offline-write/flush payloads never carry `user_name`, even when
///      it's known. Here `user_name` is included whenever available, same
///      condition as the live path.
enum TraceLocationPayload {
    /// Field keys, centralized so the contract test and the builder can't
    /// drift from each other by typo.
    enum Key {
        static let latitude = "latitude"
        static let longitude = "longitude"
        static let bearing = "bearing"
        static let altitude = "altitude"
        static let gpxTime = "gpx_time"
        static let speed = "speed"
        static let accuracy = "accuracy"
        static let userId = "user_id"
        static let companyId = "company_id"
        static let userName = "user_name"
        static let tripId = "trip_id"
        static let tripStatus = "trip_status"
    }

    static func dictionary(
        location: CLLocation,
        userId: String?,
        companyId: String?,
        userName: String?,
        tripId: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            Key.latitude: location.coordinate.latitude,
            Key.longitude: location.coordinate.longitude,
            Key.bearing: max(location.course, 0),
            Key.altitude: location.altitude,
            Key.gpxTime: DateTimeUtils.dateTimeLocal(from: location.timestamp),
            Key.speed: max(location.speed, 0),
            Key.accuracy: location.horizontalAccuracy
        ]
        if let userId, !userId.isEmpty { payload[Key.userId] = userId }
        if let companyId, !companyId.isEmpty { payload[Key.companyId] = companyId }
        if let userName, !userName.isEmpty { payload[Key.userName] = userName }
        if let tripId, !tripId.isEmpty {
            payload[Key.tripId] = tripId
            payload[Key.tripStatus] = "active"
        }
        return payload
    }

    static func json(
        location: CLLocation,
        userId: String?,
        companyId: String?,
        userName: String?,
        tripId: String?
    ) -> String {
        let payload = dictionary(
            location: location, userId: userId, companyId: companyId, userName: userName, tripId: tripId
        )
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func completedTripJson(tripId: String) -> String {
        "{\"\(Key.tripId)\":\"\(tripId)\",\"\(Key.tripStatus)\":\"completed\"}"
    }
}
