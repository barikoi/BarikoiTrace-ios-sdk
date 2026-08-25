import Foundation

/// Mirrors `TraceDataStore.kt`'s key set and behavior. Identity + credentials
/// (API key, MQTT username/password, user fields) live in the Keychain; runtime
/// config/flags (URLs, tracking mode, feature toggles) live in UserDefaults —
/// matching the sensitivity split, unlike the Kotlin side which puts everything
/// in plain DataStore Preferences.
public final class TraceDataStore {
    private let defaults: UserDefaults
    private let keychain: KeychainStore

    private enum Keys {
        static let baseURL = "bkoi_trace_base_url"
        static let mqttURL = "bkoi_trace_mqtt_url"
        static let deviceToken = "bkoi_trace_device_token"
        static let sdkTracking = "bkoi_trace_sdk_tracking"
        static let localTripId = "bkoi_trace_local_trip_id"
        static let offlineTracking = "bkoi_trace_offline_tracking"
        static let dataSyncing = "bkoi_trace_data_syncing"
        static let logging = "bkoi_trace_logging"
        static let broadcasting = "bkoi_trace_broadcasting"
        static let desiredAccuracy = "bkoi_trace_desired_accuracy"
        static let updateInterval = "bkoi_trace_update_interval"
        static let distanceFilter = "bkoi_trace_distance_filter"
        static let stopDuration = "bkoi_trace_stop_duration"
        static let accuracyFilter = "bkoi_trace_accuracy_filter"
        static let pingSyncInterval = "bkoi_trace_ping_sync_interval"
        static let trackingType = "bkoi_trace_tracking_type"
        static let startTime = "bkoi_trace_start_time"
        static let endTime = "bkoi_trace_end_time"
        static let debug = "bkoi_trace_debug"
    }

    private enum SecureKeys {
        static let apiKey = "apiKey"
        static let mqttUsername = "mqttUsername"
        static let mqttPassword = "mqttPassword"
        static let userId = "userId"
        static let userName = "userName"
        static let userEmail = "userEmail"
        static let userPhone = "userPhone"
        static let userCompany = "userCompany"
        static let userGroup = "userGroup"
        static let userUpdatedAt = "userUpdatedAt"
    }

    public init(suiteName: String = "com.barikoi.trace") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.keychain = KeychainStore(service: suiteName)
    }

    // MARK: - API key / MQTT credentials

    public func setApiKey(_ key: String) { keychain.set(key, forKey: SecureKeys.apiKey) }
    public func getApiKey() -> String? { keychain.get(SecureKeys.apiKey) }

    /// No hardcoded fallback here on purpose — see the work plan's Phase 0 note
    /// on the Kotlin SDK's hardcoded `MqttManager.kt` credentials. The host app
    /// must supply real credentials via `BarikoiTrace.initialize`.
    public func setMqttCredentials(username: String, password: String) {
        keychain.set(username, forKey: SecureKeys.mqttUsername)
        keychain.set(password, forKey: SecureKeys.mqttPassword)
    }
    public func getMqttUsername() -> String? { keychain.get(SecureKeys.mqttUsername) }
    public func getMqttPassword() -> String? { keychain.get(SecureKeys.mqttPassword) }

    // MARK: - URLs

    public func setBaseURL(_ url: String) { defaults.set(url, forKey: Keys.baseURL) }
    public func getBaseURL() -> String? { defaults.string(forKey: Keys.baseURL) }
    public func setMqttURL(_ url: String) { defaults.set(url, forKey: Keys.mqttURL) }
    public func getMqttURL() -> String? { defaults.string(forKey: Keys.mqttURL) }
    public func resetURLs() {
        defaults.removeObject(forKey: Keys.baseURL)
        defaults.removeObject(forKey: Keys.mqttURL)
    }

    // MARK: - Device token

    public func setDeviceToken(_ token: String) { defaults.set(token, forKey: Keys.deviceToken) }
    public func getDeviceToken() -> String? { defaults.string(forKey: Keys.deviceToken) }

    // MARK: - User

    public func setUser(_ user: TraceUser) {
        keychain.set(user.userId, forKey: SecureKeys.userId)
        if let v = user.name { keychain.set(v, forKey: SecureKeys.userName) }
        if let v = user.email { keychain.set(v, forKey: SecureKeys.userEmail) }
        if let v = user.phone { keychain.set(v, forKey: SecureKeys.userPhone) }
        if let v = user.companyId { keychain.set(v, forKey: SecureKeys.userCompany) }
        if let v = user.group { keychain.set(v, forKey: SecureKeys.userGroup) }
        keychain.set(String(user.updatedAt), forKey: SecureKeys.userUpdatedAt)
    }

    public func getUser() -> TraceUser? {
        guard let userId = keychain.get(SecureKeys.userId) else { return nil }
        return TraceUser(
            userId: userId,
            name: keychain.get(SecureKeys.userName),
            email: keychain.get(SecureKeys.userEmail),
            phone: keychain.get(SecureKeys.userPhone),
            companyId: keychain.get(SecureKeys.userCompany),
            group: keychain.get(SecureKeys.userGroup),
            updatedAt: keychain.get(SecureKeys.userUpdatedAt).flatMap(Double.init) ?? 0
        )
    }

    public func getUserId() -> String? { keychain.get(SecureKeys.userId) }

    public func clearUser() {
        [SecureKeys.userId, SecureKeys.userName, SecureKeys.userEmail,
         SecureKeys.userPhone, SecureKeys.userCompany, SecureKeys.userGroup,
         SecureKeys.userUpdatedAt].forEach(keychain.remove)
    }

    // MARK: - Tracking state

    public func setSdkTracking(_ on: Bool) { defaults.set(on, forKey: Keys.sdkTracking) }
    public func isSdkTracking() -> Bool { defaults.bool(forKey: Keys.sdkTracking) }

    public func setLocalTripId(_ tripId: String?) {
        if let tripId {
            defaults.set(tripId, forKey: Keys.localTripId)
        } else {
            defaults.removeObject(forKey: Keys.localTripId)
        }
    }
    public func getLocalTripId() -> String? { defaults.string(forKey: Keys.localTripId) }
    public func clearLocalTrip() { defaults.removeObject(forKey: Keys.localTripId) }

    public func setOfflineTracking(_ enabled: Bool) { defaults.set(enabled, forKey: Keys.offlineTracking) }
    public func isOfflineTracking() -> Bool { defaults.bool(forKey: Keys.offlineTracking) }

    public func setDataSyncing(_ syncing: Bool) { defaults.set(syncing, forKey: Keys.dataSyncing) }
    public func isDataSyncing() -> Bool { defaults.bool(forKey: Keys.dataSyncing) }

    public func setLogging(_ enabled: Bool) { defaults.set(enabled, forKey: Keys.logging) }
    public func isLogging() -> Bool { defaults.bool(forKey: Keys.logging) }

    public func setBroadcasting(_ enabled: Bool) { defaults.set(enabled, forKey: Keys.broadcasting) }
    public func isBroadcasting() -> Bool { defaults.bool(forKey: Keys.broadcasting) }

    // MARK: - TraceMode

    public func setTraceMode(_ mode: TraceMode) {
        defaults.set(mode.desiredAccuracy.rawValue, forKey: Keys.desiredAccuracy)
        defaults.set(mode.updateInterval, forKey: Keys.updateInterval)
        defaults.set(mode.distanceFilter, forKey: Keys.distanceFilter)
        defaults.set(mode.stopDuration, forKey: Keys.stopDuration)
        defaults.set(mode.accuracyFilter, forKey: Keys.accuracyFilter)
        defaults.set(mode.pingSyncInterval, forKey: Keys.pingSyncInterval)
        defaults.set(mode.trackingMode.rawValue, forKey: Keys.trackingType)
        defaults.set(mode.debug, forKey: Keys.debug)
    }

    public func setTraceModeWithTiming(_ mode: TraceMode) {
        setTraceMode(mode)
        defaults.set(TraceDataStore.encode(mode.startTime), forKey: Keys.startTime)
        defaults.set(TraceDataStore.encode(mode.endTime), forKey: Keys.endTime)
    }

    public func getTraceMode() -> TraceMode {
        let updateInterval = defaults.integer(forKey: Keys.updateInterval)
        let distanceFilter = defaults.integer(forKey: Keys.distanceFilter)

        let builder: TraceMode.Builder
        if updateInterval != 0 || distanceFilter != 0 {
            builder = TraceMode.Builder()
                .setAccuracyFilter(defaults.object(forKey: Keys.accuracyFilter) != nil
                    ? defaults.integer(forKey: Keys.accuracyFilter) : 200)
                .setDistanceFilter(distanceFilter)
                .setUpdateInterval(updateInterval)
                .setOfflineSync(defaults.object(forKey: Keys.offlineTracking) != nil
                    ? defaults.bool(forKey: Keys.offlineTracking) : true)
                .setPingSyncInterval(defaults.integer(forKey: Keys.pingSyncInterval))
                .setDesiredAccuracy(.fromString(defaults.string(forKey: Keys.desiredAccuracy)))
        } else {
            builder = TraceMode.Builder()
                .setAccuracyFilter(200)
                .setDistanceFilter(0)
                .setUpdateInterval(5)
                .setOfflineSync(true)
                .setDesiredAccuracy(.high)
        }

        if let endStr = defaults.string(forKey: Keys.endTime), let end = TraceDataStore.decode(endStr) {
            builder.setEndTime(end)
            if let startStr = defaults.string(forKey: Keys.startTime), let start = TraceDataStore.decode(startStr) {
                builder.setStartTime(start)
            }
        }

        return builder.build()
    }

    public func getTrackingType() -> Int { defaults.integer(forKey: Keys.trackingType) }
    public func getUpdateInterval() -> Int { defaults.integer(forKey: Keys.updateInterval) }

    public func clearTraceMode() {
        [Keys.desiredAccuracy, Keys.updateInterval, Keys.distanceFilter, Keys.stopDuration,
         Keys.accuracyFilter, Keys.pingSyncInterval, Keys.trackingType, Keys.debug]
            .forEach(defaults.removeObject)
    }

    public func clearTraceModeWithTiming() {
        clearTraceMode()
        defaults.removeObject(forKey: Keys.startTime)
        defaults.removeObject(forKey: Keys.endTime)
    }

    public func stopSdkTracking() {
        setSdkTracking(false)
        clearTraceMode()
    }

    // MARK: - Helpers

    private static func encode(_ comps: DateComponents) -> String {
        "\(comps.hour ?? 0):\(comps.minute ?? 0):\(comps.second ?? 0)"
    }

    private static func decode(_ value: String) -> DateComponents? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var comps = DateComponents()
        comps.hour = parts[0]
        comps.minute = parts[1]
        comps.second = parts.count > 2 ? parts[2] : 0
        return comps
    }
}
