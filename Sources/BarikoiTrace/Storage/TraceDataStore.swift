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
        /// The host app's explicit `setOfflineTracking(_:)` override.
        static let offlineTracking = "bkoi_trace_offline_tracking"
        /// `TraceMode.offline`, kept on its own key. These used to share
        /// `offlineTracking`, so every `startTracking`/`setOrCreateUser` (both
        /// call `setTraceMode*`) silently reverted the host app's explicit
        /// `setOfflineTracking(false)` — two public APIs fighting over one key.
        static let modeOfflineSync = "bkoi_trace_mode_offline_sync"
        /// Legacy — the syncing flag is in-memory now. Kept only so `init`
        /// can clear a stuck `true` written by an older build.
        static let legacyDataSyncing = "bkoi_trace_data_syncing"
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
        // Migration: an older build persisted the flush re-entrancy guard. A
        // kill mid-flush left it `true` and permanently blocked offline
        // flushing, so drop any stored value on launch.
        defaults.removeObject(forKey: Keys.legacyDataSyncing)
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

    /// Defaults to **true** when the host app has never set it explicitly.
    /// `defaults.bool(forKey:)` returns `false` for an absent key, which used
    /// to mean a fresh install silently *discarded* every fix produced before
    /// the MQTT socket finished connecting (see `TraceManager.persistOrPublish`).
    /// The durable queue is the safe default; an explicit `false` is still
    /// honored.
    public func isOfflineTracking() -> Bool {
        if defaults.object(forKey: Keys.offlineTracking) != nil {
            return defaults.bool(forKey: Keys.offlineTracking)
        }
        if defaults.object(forKey: Keys.modeOfflineSync) != nil {
            return defaults.bool(forKey: Keys.modeOfflineSync)
        }
        return true
    }

    /// In-memory only, deliberately. This is a re-entrancy guard around a
    /// single flush run, not durable state: when it lived in UserDefaults, a
    /// process kill mid-flush left it `true` forever and every subsequent
    /// `flushOfflineQueueAndReconnect()` early-returned for the lifetime of
    /// the install.
    /// `NSLock.withLock` is iOS 16+, this package targets iOS 15 — hence the
    /// explicit lock/unlock pair.
    public func setDataSyncing(_ syncing: Bool) {
        Self.syncLock.lock()
        defer { Self.syncLock.unlock() }
        Self.dataSyncing = syncing
    }

    public func isDataSyncing() -> Bool {
        Self.syncLock.lock()
        defer { Self.syncLock.unlock() }
        return Self.dataSyncing
    }

    /// Compare-and-set entry point for the flush guard. `isDataSyncing()`
    /// followed by `setDataSyncing(true)` is check-then-act across two
    /// separately-locked calls, and there are three concurrent callers of
    /// `flushOfflineQueueAndReconnect()` (public API, the `.connected`
    /// delegate, and the `BGProcessingTask`), so two runs could both pass the
    /// check and then have the first to finish clear the flag for both.
    /// Returns `true` only to the caller that actually claimed the run.
    public func beginDataSyncIfIdle() -> Bool {
        Self.syncLock.lock()
        defer { Self.syncLock.unlock() }
        guard !Self.dataSyncing else { return false }
        Self.dataSyncing = true
        return true
    }

    /// Static so the flag is shared across `TraceDataStore` instances
    /// (`TraceManager` and `TraceApiClient` each hold one) — a per-instance
    /// flag would not actually guard anything.
    private static let syncLock = NSLock()
    private static var dataSyncing = false

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
        // `getTraceMode()` reads `offline` back out, but this method never
        // wrote it — a mode built with `.setOfflineSync(false)` was silently
        // ignored. Written and read on the same key now, and that key is the
        // mode's own, not the host app's override.
        defaults.set(mode.offline, forKey: Keys.modeOfflineSync)
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
                .setOfflineSync(defaults.object(forKey: Keys.modeOfflineSync) != nil
                    ? defaults.bool(forKey: Keys.modeOfflineSync) : true)
                .setPingSyncInterval(defaults.integer(forKey: Keys.pingSyncInterval))
                .setDesiredAccuracy(.fromString(defaults.string(forKey: Keys.desiredAccuracy)))
            // `updateInterval` and `distanceFilter` are alternatives, and zero
            // means "not this axis". The builder floors them (5s / 10m), so
            // calling the setters unconditionally turned a stored 0 into a
            // live value: a `.passive` mode (interval 0, distance 100)
            // round-tripped as interval 5, and `.active` (interval 5,
            // distance 0) came back distance-gated at 10m. Harmless while the
            // engine applied `distanceFilter` unconditionally; now that the
            // engine honors the interval/distance split, it would silently
            // convert every stored mode into the wrong one.
            if updateInterval != 0 { builder.setUpdateInterval(updateInterval) }
            if distanceFilter != 0 { builder.setDistanceFilter(distanceFilter) }
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
        // `modeOfflineSync` belongs to the mode, so it clears with it —
        // otherwise a mode with `offline == false` would keep the durable
        // queue disabled after the mode itself was cleared.
        [Keys.desiredAccuracy, Keys.updateInterval, Keys.distanceFilter, Keys.stopDuration,
         Keys.accuracyFilter, Keys.pingSyncInterval, Keys.trackingType, Keys.debug,
         Keys.modeOfflineSync]
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
