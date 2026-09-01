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

    /// Trip-completion payload. Mirrors `LocTraceForegroundService.onDestroy()`,
    /// which publishes the **full** location payload for the last known fix
    /// with `trip_status: "completed"` — not a bare `{trip_id, trip_status}`
    /// pair. The thin form this used to emit carried no `user_id`,
    /// `company_id`, coordinates or timestamp, so a broker consumer keyed on
    /// `user_id` could not attribute the message at all.
    ///
    /// `location` is optional because iOS can reach `stopTracking()` before
    /// any fix has arrived; in that case the identity fields are still sent
    /// so the message remains attributable.
    static func completedTripJson(
        tripId: String,
        location: CLLocation?,
        userId: String?,
        companyId: String?,
        userName: String?
    ) -> String {
        var payload: [String: Any]
        if let location {
            payload = dictionary(
                location: location, userId: userId, companyId: companyId,
                userName: userName, tripId: nil
            )
        } else {
            payload = [Key.gpxTime: DateTimeUtils.dateTimeLocal(from: Date())]
            if let userId, !userId.isEmpty { payload[Key.userId] = userId }
            if let companyId, !companyId.isEmpty { payload[Key.companyId] = companyId }
            if let userName, !userName.isEmpty { payload[Key.userName] = userName }
        }
        payload[Key.tripId] = tripId
        payload[Key.tripStatus] = "completed"

        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Fills in `user_id`/`company_id`/`user_name` on a queued row that was
    /// written before they were known — the flush-time backfill
    /// `LocTraceForegroundService.flushOfflineData()` performs. A fix
    /// persisted before `setOrCreateUser` completed was previously flushed
    /// with no `user_id` at all and was permanently unattributable.
    /// Existing values are never overwritten. Returns the row unchanged if it
    /// is not parseable JSON.
    static func backfilled(
        json: String,
        userId: String?,
        companyId: String?,
        userName: String?
    ) -> String {
        guard let data = json.data(using: .utf8),
              var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return json
        }

        var changed = false
        func fill(_ key: String, _ value: String?) {
            guard payload[key] == nil, let value, !value.isEmpty else { return }
            payload[key] = value
            changed = true
        }
        fill(Key.userId, userId)
        fill(Key.companyId, companyId)
        fill(Key.userName, userName)

        guard changed,
              let patched = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: patched, encoding: .utf8) else {
            return json
        }
        return string
    }
}
