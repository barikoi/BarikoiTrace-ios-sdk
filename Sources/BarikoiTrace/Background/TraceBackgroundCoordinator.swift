import BackgroundTasks
import CoreLocation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Narrow protocol `TraceManager` conforms to, so this file doesn't need to
/// import/know about the full public facade — keeps the dependency direction
/// one-way (Background -> Manager via protocol) instead of circular.
public protocol TraceManagerProtocol: AnyObject {
    func handleLocation(_ location: CLLocation)
    func flushOfflineQueueAndReconnect() async
    func log(level: String, tag: String, message: String)
}

/// Owns the iOS background-execution trigger stack. There is no equivalent to
/// Android's persistent foreground `Service` here — iOS only ever grants
/// bounded wake windows in response to specific triggers. This class layers
/// three of them so the *user-visible outcome* approximates a continuously
/// running tracker even though the *mechanism* is fundamentally different:
///
/// 1. `CLLocationManager` background location delivery — primary trigger.
///    Wakes the app for each qualifying fix while backgrounded, as long as
///    `Always` authorization + the "location" Background Mode are both in
///    place. This is the main channel true background tracking rides on.
///
/// 2. Significant-location-change monitoring — low-power fallback, and
///    critically, the **only** mechanism that relaunches the app after the
///    OS or user has killed the process (delivers
///    `UIApplication.LaunchOptionsKey.location` to `didFinishLaunching`).
///    Triggers on ~500m/cell-change movement, not on a timer — a stationary
///    killed app will not silently resume the way Android's `BOOT_COMPLETED`
///    resumes tracking after a device reboot. That gap is inherent to the
///    platform, not a bug to chase here.
///
/// 3. `BGProcessingTask` via `BGTaskScheduler` — periodic offline-queue flush
///    and MQTT reconnect window, for when location-triggered wakes are too
///    infrequent (e.g. the device is stationary for hours). Unlike the
///    Kotlin SDK's `LocTraceDataService` — which is fully implemented but
///    never actually scheduled anywhere, so it's dead code today — this is
///    scheduled for real in `scheduleNextFlush()`, called on every start and
///    re-chained on every run.
public final class TraceBackgroundCoordinator: NSObject {

    public static let processingTaskIdentifier = "com.barikoi.trace.offlineflush"

    private let locationEngine: TraceLocationEngine
    private let dataStore: TraceDataStore
    private let offlineStore: OfflineLocationStore
    private weak var manager: TraceManagerProtocol?

    public init(
        locationEngine: TraceLocationEngine = TraceLocationEngine(),
        dataStore: TraceDataStore,
        offlineStore: OfflineLocationStore = .shared
    ) {
        self.locationEngine = locationEngine
        self.dataStore = dataStore
        self.offlineStore = offlineStore
    }

    /// Call once, as early as possible in
    /// `application(_:didFinishLaunchingWithOptions:)` — `BGTaskScheduler`
    /// requires task registration before the app finishes launching.
    public func registerBackgroundTasks(manager: TraceManagerProtocol) {
        self.manager = manager
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self?.handleProcessingTask(processingTask)
        }
    }

    /// Call from `application(_:didFinishLaunchingWithOptions:)`. Detects a
    /// significant-location-change relaunch after the process was previously
    /// killed and resumes tracking, restoring state entirely from
    /// `TraceDataStore` — no in-memory state is assumed to have survived.
    public func handleLaunch(options: [AnyHashable: Any]?) {
        #if canImport(UIKit)
        guard options?[UIApplication.LaunchOptionsKey.location] != nil else { return }
        #endif
        guard dataStore.isSdkTracking() else { return }
        start(mode: dataStore.getTraceMode())
    }

    public func start(mode: TraceMode) {
        locationEngine.startLocationUpdates(traceMode: mode, listener: self)
        locationEngine.startMonitoringSignificantLocationChanges()
        scheduleNextFlush()
    }

    public func stop() {
        locationEngine.stopLocationUpdates()
        locationEngine.stopMonitoringSignificantLocationChanges()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskIdentifier)
    }

    public func requestCurrentLocation() async throws -> CLLocation {
        try await locationEngine.getCurrentLocation()
    }

    /// Submits (or re-submits) the periodic flush task. Called on `start()`
    /// and re-chained at the top of every `handleProcessingTask` run so the
    /// cadence survives individual failures or early expiration.
    public func scheduleNextFlush(after interval: TimeInterval = 15 * 60) {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            manager?.log(level: "WARN", tag: "TraceBackground", message: "BGTask submit failed: \(error)")
        }
    }

    private func handleProcessingTask(_ task: BGProcessingTask) {
        // Reschedule first — a chained request, so the flush cadence survives
        // even if this run fails or is cut short by the expiration handler.
        scheduleNextFlush()

        let work = Task {
            await manager?.flushOfflineQueueAndReconnect()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - Degraded-capability visibility — no Android equivalent needed,
    // this is a real iOS-only requirement (see the work plan §3).

    public var isBackgroundTrackingDegraded: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        #if canImport(UIKit)
        if UIApplication.shared.backgroundRefreshStatus != .available { return true }
        #endif
        if CLLocationManager().authorizationStatus != .authorizedAlways { return true }
        return false
    }
}

extension TraceBackgroundCoordinator: LocationUpdateListener {
    public func onLocationReceived(_ location: CLLocation) {
        manager?.handleLocation(location)
    }

    public func onFailure(_ error: TraceError) {
        manager?.log(level: "ERROR", tag: "TraceBackground", message: error.message)
    }

    public func onProviderAvailabilityChanged(_ available: Bool) {
        manager?.log(level: "INFO", tag: "TraceBackground", message: "Location provider available: \(available)")
    }
}
