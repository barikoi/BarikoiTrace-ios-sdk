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

    /// Must be called once, typically from
    /// `application(_:didFinishLaunchingWithOptions:)`, before any other
    /// method.
    ///
    /// ```swift
    /// BarikoiTrace.initialize(
    ///     TraceConfig(apiKey: "…", mqttUsername: "…", mqttPassword: "…")
    /// )
    /// ```
    ///
    /// Endpoints are applied *before* the manager starts, which matters:
    /// `initialize` resumes tracking if the previous process was tracking, and
    /// a resumed session builds its MQTT client immediately. Setting the
    /// broker URL afterwards — as the old `setMqttURL`-after-`initialize`
    /// sequence did — could point that first client at the wrong broker.
    public static func initialize(_ config: TraceConfig) {
        for warning in config.warnings {
            TraceManager.shared.log(level: "WARN", tag: "TraceConfig", message: warning)
        }

        TraceManager.shared.setMqttCredentials(
            username: config.mqttUsername,
            password: config.mqttPassword
        )
        TraceManager.shared.setBaseURL(config.baseURL)
        TraceManager.shared.setMqttURL(config.mqttURL)
        TraceManager.shared.setMqttClientIdPrefix(config.mqttClientIdPrefix)
        TraceManager.shared.initialize(apiKey: config.apiKey)
    }

    @available(*, deprecated, message: "Use initialize(_: TraceConfig). This overload cannot carry the broker URL, so it forces a setMqttURL call after initialize — which is too late if a previous session is being resumed.")
    public static func initialize(apiKey: String, mqttUsername: String, mqttPassword: String) {
        initialize(TraceConfig(
            apiKey: apiKey,
            mqttUsername: mqttUsername,
            mqttPassword: mqttPassword
        ))
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

    /// Overrides the MQTT client-id prefix (default `"iOSClient-"`; the
    /// Android SDK uses `"AndroidClient-"`). Only needed when the broker's ACL
    /// authorizes by client-id pattern rather than by credentials alone — the
    /// symptom is `notAuthorized` on a CONNECT whose username and password are
    /// correct. Call before `startTracking`.
    public static func setMqttClientIdPrefix(_ prefix: String) {
        TraceManager.shared.setMqttClientIdPrefix(prefix)
    }
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

    /// Prompts for When In Use location authorization —
    /// `requestLocationPermissions(activity)`'s counterpart. The SDK could
    /// already do this internally but never exposed it, so host apps had to
    /// stand up their own `CLLocationManager` purely to ask.
    public static func requestLocationPermissions() {
        TraceManager.shared.requestAuthorization(always: false)
    }

    /// Prompts for Always authorization —
    /// `requestBackgroundLocationPermission(activity)`'s counterpart. iOS only
    /// grants this after When In Use has been granted, so call
    /// `requestLocationPermissions()` first.
    public static func requestBackgroundLocationPermission() {
        TraceManager.shared.requestAuthorization(always: true)
    }

    /// Opens this app's Settings page. Stands in for
    /// `requestLocationServices(activity)`: iOS exposes no deep link to the
    /// system Location Services toggle, so the app's own settings page — which
    /// carries its Location row — is where the user is sent.
    @discardableResult
    public static func openAppSettings() -> Bool { SystemSettingsManager.openAppSettings() }

    // No counterparts to `requestNotificationPermission`,
    // `requestDisableBatteryOptimization`, `isBatteryOptimizationEnabled`,
    // `checkAppServicePermission`, `openAutostartSettings` or
    // `isGoogleAvailable`: all six exist to work around Android OEM process
    // killing and the foreground-service notification, neither of which this
    // platform has. `isBackgroundTrackingDegraded` below answers the question
    // they were actually asked for.

    // MARK: - Tracking

    public static func setTraceMode(_ mode: TraceMode) { TraceManager.shared.setTraceMode(mode) }

    public static func startTracking(_ mode: TraceMode, withTrip: Bool = false) {
        TraceManager.shared.startTracking(mode: mode, withTrip: withTrip)
    }

    public static func stopTracking() { TraceManager.shared.stopTracking() }

    /// Re-applies the stored `TraceMode` to a running session —
    /// `LocTraceManager.refreshTracking()`. `setTraceMode(_:)` already does
    /// this automatically while tracking; this is for callers that changed the
    /// mode through some other path.
    public static func refreshTracking() { TraceManager.shared.refreshTracking() }

    public static func isLocationTracking() -> Bool { TraceManager.shared.isLocationTracking() }
    public static func setOfflineTracking(_ enabled: Bool) { TraceManager.shared.setOfflineTracking(enabled) }
    public static func setLoggingEnabled(_ enabled: Bool) { TraceManager.shared.setLoggingEnabled(enabled) }
    public static func setBroadcastingEnabled(_ enabled: Bool) { TraceManager.shared.setBroadcastingEnabled(enabled) }

    /// Whether the SDK posts a local notification when location services go
    /// off — the port of Android's unconditional "Need to turn on location
    /// service" notification. On by default; the first post asks for
    /// notification authorization. Set `false` before `startTracking` to
    /// suppress both the notification and the prompt.
    public static func setLocationDisabledNotificationEnabled(_ enabled: Bool) {
        TraceNotifier.isEnabled = enabled
    }

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
