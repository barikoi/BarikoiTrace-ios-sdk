import CoreLocation
import Foundation

/// SDK-internal debug log sink — same role as `BarikoiTrace.kt`'s
/// `TraceLogListener`, surfaced so a host app can show a live debug console
/// the way the Kotlin sample app's DemoActivity does.
public protocol TraceLogListener: AnyObject {
    func onLog(level: String, tag: String, message: String)
}

/// Public entry point. Method names and shapes deliberately mirror
/// `BarikoiTrace.kt` so call sites read the same on both platforms — Swift
/// async/await stands in for Kotlin's suspend functions; there's no need for
/// a second callback-based API the way the Kotlin facade offers for Java
/// interop, since async/await is the native idiom on this platform.
///
/// Two calls are required at startup that have no Kotlin equivalent, both
/// iOS-specific:
///   1. `initialize(apiKey:mqttUsername:mqttPassword:)` takes MQTT credentials
///      directly, rather than the Kotlin SDK's hardcoded broker constants —
///      see the work plan's Phase 0 for why that pattern isn't carried over.
///   2. `handleLaunch(options:)` must be called from
///      `application(_:didFinishLaunchingWithOptions:)` so a
///      significant-location-change relaunch after the process was killed
///      correctly resumes tracking (see `TraceBackgroundCoordinator`).
public enum BarikoiTrace {

    /// Must be called once, typically from `application(_:didFinishLaunchingWithOptions:)`,
    /// before any other method.
    public static func initialize(apiKey: String, mqttUsername: String, mqttPassword: String) {
        TraceManager.shared.setMqttCredentials(username: mqttUsername, password: mqttPassword)
        TraceManager.shared.initialize(apiKey: apiKey)
    }

    /// Call from `application(_:didFinishLaunchingWithOptions:)`, after
    /// `initialize`, passing through `launchOptions`.
    public static func handleLaunch(options: [AnyHashable: Any]?) {
        TraceManager.shared.handleLaunch(options: options)
    }

    public static func setLogListener(_ listener: TraceLogListener?) {
        TraceManager.shared.logListener = listener
    }

    // MARK: - URLs

    public static func setBaseURL(_ url: String) { TraceManager.shared.setBaseURL(url) }
    public static func setMqttURL(_ url: String) { TraceManager.shared.setMqttURL(url) }
    public static func resetURLs() { TraceManager.shared.resetURLs() }

    // MARK: - User

    public static func setOrCreateUser(name: String?, email: String?, phone: String) async throws -> TraceUser {
        try await TraceManager.shared.setOrCreateUser(name: name, email: email, phone: phone)
    }

    public static func getUser() -> TraceUser? { TraceManager.shared.getUser() }
    public static func getUserId() -> String? { TraceManager.shared.getUserId() }

    // MARK: - Permissions & settings

    public static func isLocationPermissionsGranted() -> Bool { SystemSettingsManager.checkPermissions() }
    public static func isLocationSettingsOn() -> Bool { SystemSettingsManager.checkLocationSettings() }
    public static func hasBackgroundPermission() -> Bool { SystemSettingsManager.hasAlwaysAuthorization() }

    // MARK: - Tracking

    public static func setTraceMode(_ mode: TraceMode) { TraceManager.shared.setTraceMode(mode) }

    public static func startTracking(_ mode: TraceMode, withTrip: Bool = false) {
        TraceManager.shared.startTracking(mode: mode, withTrip: withTrip)
    }

    public static func stopTracking() { TraceManager.shared.stopTracking() }
    public static func isLocationTracking() -> Bool { TraceManager.shared.isLocationTracking() }
    public static func setOfflineTracking(_ enabled: Bool) { TraceManager.shared.setOfflineTracking(enabled) }
    public static func setLoggingEnabled(_ enabled: Bool) { TraceManager.shared.setLoggingEnabled(enabled) }
    public static func setBroadcastingEnabled(_ enabled: Bool) { TraceManager.shared.setBroadcastingEnabled(enabled) }

    // MARK: - Trips
    //
    // Intentionally exposes only `getTripId()` — the Kotlin facade has both
    // `getTripId()` and `getCurrentTrip()` returning the exact same value,
    // flagged as redundant API surface in the SDK review. Not duplicated here.

    public static func isOnTrip() -> Bool { TraceManager.shared.isOnTrip() }
    public static func getTripId() -> String? { TraceManager.shared.getTripId() }

    // MARK: - Location

    public static func updateCurrentLocation() async throws -> CLLocation {
        try await TraceManager.shared.updateCurrentLocation()
    }

    public static func uploadOfflineData() { TraceManager.shared.uploadOfflineData() }

    public static func getSettingsFromRemote() async throws -> TraceMode {
        try await TraceManager.shared.getSettingsFromRemote()
    }

    // MARK: - Live updates

    /// Multi-consumer async stream of live location updates, gated by
    /// `setBroadcastingEnabled(true)` — mirrors `BarikoiTrace.kt`'s
    /// `locationUpdates: SharedFlow<Location>`.
    public static var locationUpdates: AsyncStream<CLLocation> { TraceManager.shared.locationUpdates }

    /// True if Low Power Mode, a downgraded/denied `Always` authorization, or
    /// a user-disabled Background App Refresh is currently limiting how
    /// reliably background tracking can run. No Android equivalent — this is
    /// a genuinely new requirement on this platform, not a port.
    public static var isBackgroundTrackingDegraded: Bool { TraceManager.shared.isBackgroundTrackingDegraded }
}
