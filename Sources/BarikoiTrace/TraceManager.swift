import CoreLocation
import Foundation

/// Orchestrator singleton — mirrors `LocTraceManager.kt`'s public surface and
/// wires `TraceDataStore`, `TraceApiClient`, `TraceLocationEngine`/
/// `TraceBackgroundCoordinator`, `TraceMqttClient`, and `OfflineLocationStore`
/// together. `BarikoiTrace` (the public facade) is a thin static wrapper
/// around this class, same relationship as `BarikoiTrace.kt` has to
/// `LocTraceManager.kt`.
public final class TraceManager: NSObject, TraceManagerProtocol {
    public static let shared = TraceManager()

    private let dataStore = TraceDataStore()
    private lazy var apiClient = TraceApiClient(dataStore: dataStore)
    private let offlineStore = OfflineLocationStore.shared
    private lazy var backgroundCoordinator = TraceBackgroundCoordinator(dataStore: dataStore, offlineStore: offlineStore)
    private lazy var oneShotLocationEngine = TraceLocationEngine()

    private var mqttClient: TraceMqttClient?
    private let locationBroadcast = AsyncBroadcast<CLLocation>()

    public var locationUpdates: AsyncStream<CLLocation> { locationBroadcast.stream() }
    public weak var logListener: TraceLogListener?

    private override init() { super.init() }

    // MARK: - Init

    public func setMqttCredentials(username: String, password: String) {
        dataStore.setMqttCredentials(username: username, password: password)
    }

    public func initialize(apiKey: String) {
        dataStore.setApiKey(apiKey)
        apiClient.setApiKey(apiKey)
        dataStore.setLogging(true)

        if dataStore.getDeviceToken() == nil {
            dataStore.setDeviceToken(UUID().uuidString)
        }

        if !NetworkChecker.isNetworkAvailable() {
            log(level: "WARN", tag: "TraceManager", message: TraceError.networkError().message)
        }

        backgroundCoordinator.registerBackgroundTasks(manager: self)

        // Resume tracking if it was active before this process launch
        // (ordinary relaunch, not the significant-location-change path —
        // that one goes through handleLaunch(options:) below).
        if dataStore.isSdkTracking() {
            startTracking(mode: dataStore.getTraceMode(), withTrip: dataStore.getLocalTripId() != nil)
        }
    }

    /// Call from AppDelegate's `application(_:didFinishLaunchingWithOptions:)`,
    /// after `initialize(apiKey:)`, so a significant-location-change relaunch
    /// after the process was killed correctly resumes tracking.
    public func handleLaunch(options: [AnyHashable: Any]?) {
        backgroundCoordinator.handleLaunch(options: options)
    }

    // MARK: - User

    public func setOrCreateUser(name: String?, email: String?, phone: String) async throws -> TraceUser {
        guard !phone.isEmpty else { throw TraceError.noDataError() }
        guard let apiKey = dataStore.getApiKey(), !apiKey.isEmpty else { throw TraceError.noKeyError() }

        // 24h local-cache short-circuit, mirrors LocTraceManager.kt.
        if let cached = dataStore.getUser(), cached.phone == phone,
           (Date().timeIntervalSince1970 * 1000 - cached.updatedAt) < 24 * 60 * 60 * 1000 {
            return cached
        }

        guard NetworkChecker.isNetworkAvailable() else { throw TraceError.networkError() }

        let user = try await apiClient.authenticate(name: name, email: email, phone: phone)
        apiClient.setUserId(user.userId)

        if let phone = user.phone, !phone.isEmpty {
            do {
                let mode = try await apiClient.getCompanySettings(phone: phone)
                dataStore.setTraceModeWithTiming(mode)
            } catch {
                log(level: "WARN", tag: "TraceManager", message: "Failed to fetch remote settings: \(error)")
            }
        }

        return user
    }

    public func getUser() -> TraceUser? { dataStore.getUser() }
    public func getUserId() -> String? { dataStore.getUserId() }

    // MARK: - URLs

    public func setBaseURL(_ url: String) {
        let normalized = url.hasSuffix("/") ? url : url + "/"
        guard dataStore.getBaseURL() != normalized else { return }
        dataStore.setBaseURL(normalized)
        dataStore.clearUser()
        dataStore.clearTraceModeWithTiming()
        apiClient.setBaseURL(normalized)
        stopTracking()
    }

    public func setMqttURL(_ url: String) { dataStore.setMqttURL(url) }

    public func resetURLs() {
        dataStore.resetURLs()
        apiClient.setBaseURL(TraceApiRoutes.baseURL)
        dataStore.clearUser()
        dataStore.clearTraceModeWithTiming()
        stopTracking()
    }

    // MARK: - Tracking

    public func setTraceMode(_ mode: TraceMode) {
        dataStore.setTraceMode(mode)
    }

    public func startTracking(mode: TraceMode, withTrip: Bool = false) {
        guard let userId = dataStore.getUserId(), !userId.isEmpty else {
            log(level: "WARN", tag: "TraceManager", message: TraceError.noUserError().message)
            return
        }
        guard SystemSettingsManager.checkPermissions(), SystemSettingsManager.checkLocationSettings() else {
            log(level: "WARN", tag: "TraceManager", message: TraceError.locationPermissionError().message)
            return
        }

        dataStore.setSdkTracking(true)
        dataStore.setTraceMode(mode)

        if withTrip {
            if dataStore.getLocalTripId() == nil {
                dataStore.setLocalTripId(UUID().uuidString)
            }
        } else {
            dataStore.clearLocalTrip()
        }

        connectMqttIfPossible()
        backgroundCoordinator.start(mode: mode)
    }

    public func stopTracking() {
        // Best-effort final "completed" publish. If the process is killed
        // instead of calling stopTracking(), this never fires — same gap the
        // Kotlin SDK has in LocTraceForegroundService.onDestroy(), documented
        // rather than silently inherited (see the work plan's Phase 0).
        if let tripId = dataStore.getLocalTripId(), mqttClient?.isConnectedNow() == true {
            mqttClient?.publish(json: TraceLocationPayload.completedTripJson(tripId: tripId))
        }
        dataStore.stopSdkTracking()
        dataStore.clearLocalTrip()
        mqttClient?.disconnect()
        backgroundCoordinator.stop()
    }

    public func isLocationTracking() -> Bool { dataStore.isSdkTracking() }
    public func setOfflineTracking(_ enabled: Bool) { dataStore.setOfflineTracking(enabled) }
    public func setLoggingEnabled(_ enabled: Bool) { dataStore.setLogging(enabled) }
    public func setBroadcastingEnabled(_ enabled: Bool) { dataStore.setBroadcasting(enabled) }

    // MARK: - Trips

    public func isOnTrip() -> Bool { dataStore.getLocalTripId() != nil }
    public func getTripId() -> String? { dataStore.getLocalTripId() }

    // MARK: - Location

    public func updateCurrentLocation() async throws -> CLLocation {
        let location = try await oneShotLocationEngine.getCurrentLocation()
        persistOrPublish(location)
        return location
    }

    public func uploadOfflineData() {
        Task { await flushOfflineQueueAndReconnect() }
    }

    public func getSettingsFromRemote() async throws -> TraceMode {
        guard let user = dataStore.getUser(), let phone = user.phone, !phone.isEmpty else {
            throw TraceError.noUserError()
        }
        let mode = try await apiClient.getCompanySettings(phone: phone)
        dataStore.setTraceModeWithTiming(mode)
        return mode
    }

    public var isBackgroundTrackingDegraded: Bool { backgroundCoordinator.isBackgroundTrackingDegraded }

    // MARK: - TraceManagerProtocol (called back by TraceBackgroundCoordinator)

    public func handleLocation(_ location: CLLocation) {
        guard isValid(location) else { return }

        if dataStore.isBroadcasting() {
            locationBroadcast.yield(location)
        }

        persistOrPublish(location)
    }

    public func flushOfflineQueueAndReconnect() async {
        if dataStore.isDataSyncing() { return }
        dataStore.setDataSyncing(true)
        defer { dataStore.setDataSyncing(false) }

        connectMqttIfPossible()
        guard let mqttClient, mqttClient.isConnectedNow() else { return }

        while offlineStore.count() > 0 {
            let batch = offlineStore.batch(limit: 100)
            guard !batch.isEmpty else { break }
            for row in batch {
                mqttClient.publish(json: row.json)
            }
            offlineStore.deleteBatch(limit: 100)
        }
    }

    public func log(level: String, tag: String, message: String) {
        guard dataStore.isLogging() else { return }
        logListener?.onLog(level: level, tag: tag, message: message)
    }

    // MARK: - Private helpers

    private func isValid(_ location: CLLocation) -> Bool {
        guard location.timestamp.timeIntervalSinceNow > -10 else { return false } // reject fixes older than 10s
        let mode = dataStore.getTraceMode()
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Double(mode.accuracyFilter) else {
            return false
        }
        return true
    }

    private func persistOrPublish(_ location: CLLocation) {
        let user = dataStore.getUser()
        let tripId = dataStore.getLocalTripId()
        let json = TraceLocationPayload.json(
            location: location, userId: user?.userId, companyId: user?.companyId,
            userName: user?.name, tripId: tripId
        )

        connectMqttIfPossible()
        if let mqttClient, mqttClient.isConnectedNow() {
            mqttClient.publish(json: json)
        } else if dataStore.isOfflineTracking() {
            offlineStore.insert(json: json)
        }
    }

    private func connectMqttIfPossible() {
        guard let user = dataStore.getUser(),
              let companyId = user.companyId,
              let group = user.group,
              let deviceToken = dataStore.getDeviceToken(),
              let mqttUsername = dataStore.getMqttUsername(),
              let mqttPassword = dataStore.getMqttPassword() else { return }

        if mqttClient == nil {
            let mqttURL = dataStore.getMqttURL() ?? TraceApiRoutes.mqttURL
            let (host, port) = TraceManager.parseMqttURL(mqttURL)
            let client = TraceMqttClient(
                host: host, port: port,
                userId: user.userId, companyId: companyId, groupId: group, deviceUUID: deviceToken,
                userName: user.name, mqttUsername: mqttUsername, mqttPassword: mqttPassword
            )
            client.delegate = self
            mqttClient = client
        }

        if mqttClient?.isConnectedNow() == false {
            mqttClient?.connect()
        }
    }

    private static func parseMqttURL(_ url: String) -> (host: String, port: UInt16) {
        guard let components = URLComponents(string: url), let host = components.host else {
            return ("broker.trace.bmapsbd.com", 1883)
        }
        return (host, UInt16(components.port ?? 1883))
    }

}

extension TraceManager: TraceMqttStatusDelegate {
    public func mqttConnectionStatusChanged(state: TraceMqttState, message: String) {
        log(level: "INFO", tag: "TraceMqtt", message: "\(state): \(message)")
        if state == .connected {
            Task { await flushOfflineQueueAndReconnect() }
        }
    }

    public func mqttMessageDelivered(topic: String) {
        log(level: "DEBUG", tag: "TraceMqtt", message: "Published to \(topic)")
    }

    public func mqttMessageReceived(topic: String, message: String) {
        log(level: "DEBUG", tag: "TraceMqtt", message: "Received on \(topic): \(message)")
    }
}
