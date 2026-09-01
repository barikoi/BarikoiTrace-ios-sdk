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
    /// Waits for a flush already in progress before running its own, instead
    /// of returning immediately. The background task needs this: the fix it
    /// just handed to `handleLocation` spawns its own detached flush, so a
    /// non-waiting call would find the sync claim taken, do nothing, and let
    /// the task report completion while the real work was still running
    /// outside the window it was granted.
    func flushOfflineQueueAndReconnect(waitingForInFlight: Bool) async
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
    /// Dedicated to the background task's one-shot fetch — see the note in
    /// `handleProcessingTask`. Must not be the engine driving continuous
    /// updates.
    private let oneShotEngine = TraceLocationEngine()
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
        AppState.startObserving()
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
    /// - Returns: whether tracking was actually resumed. Callers use this to
    ///   decide whether to grant resources (the broker permit) that must not
    ///   outlive a session that never began.
    @discardableResult
    public func handleLaunch(options: [AnyHashable: Any]?) -> Bool {
        #if canImport(UIKit)
        guard options?[UIApplication.LaunchOptionsKey.location] != nil else { return false }
        #endif
        guard dataStore.isSdkTracking() else { return false }
        start(mode: dataStore.getTraceMode())
        return true
    }

    public func start(mode: TraceMode) {
        locationEngine.startLocationUpdates(traceMode: mode, listener: self)
        locationEngine.startMonitoringSignificantLocationChanges()
        scheduleNextFlush()
    }

    /// Re-applies a changed `TraceMode` to the live subscription without
    /// tearing the session down — `LocTraceManager.refreshTracking()`'s role,
    /// minus the service stop/start Android needs to get there.
    public func refresh(mode: TraceMode) {
        locationEngine.refreshLocationUpdates(traceMode: mode)
    }

    /// Whether the location subscription is actually running, as opposed to
    /// the persisted "should be tracking" flag. Android reads the real service
    /// state via `ActivityManager`; this is the equivalent question.
    public var isEngineRunning: Bool { locationEngine.currentMode != nil }

    public func stop() {
        locationEngine.stopLocationUpdates()
        locationEngine.stopMonitoringSignificantLocationChanges()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskIdentifier)
    }

    /// Routed through `oneShotEngine`, not the continuous one:
    /// `requestLocation()` is unsupported on a manager already running
    /// `startUpdatingLocation()`, and sharing an engine means the one-shot
    /// continuation swallows the next continuous fix instead of the listener
    /// receiving it.
    public func requestCurrentLocation() async throws -> CLLocation {
        try await oneShotEngine.getCurrentLocation()
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

        // Armed before the work starts. Assigning it afterwards left a window
        // in which an expiration cancelled nothing and the task ran past the
        // budget the OS granted it.
        let cancellation = TaskCancellationBox()
        task.expirationHandler = { cancellation.cancel() }

        let work = Task { [weak self] in
            // Take a fresh fix first, then flush. `LocTraceDataService` (the
            // Android counterpart) exists precisely to guarantee one fix per
            // period when the continuous stream is starved; this handler used
            // to flush only, so a stationary or throttled iOS app produced
            // *zero* new fixes between wakes. Failure is non-fatal — the flush
            // below is still worth running.
            if let self, self.dataStore.isSdkTracking(), !Task.isCancelled {
                do {
                    // A *separate* engine: `requestLocation()` is not supported
                    // on a manager already running `startUpdatingLocation()`,
                    // and sharing one meant the one-shot continuation swallowed
                    // the next continuous fix (and any error) instead of the
                    // listener seeing it.
                    let location = try await self.oneShotEngine.getCurrentLocation(timeout: 20)
                    self.manager?.handleLocation(location)
                } catch {
                    self.manager?.log(level: "WARN", tag: "TraceBackground", message: "Periodic fix failed: \(error)")
                }
            }
            guard !Task.isCancelled else {
                // Expired rather than finished — report it honestly so the
                // scheduler doesn't treat a truncated run as a clean one.
                task.setTaskCompleted(success: false)
                return
            }
            await self?.manager?.flushOfflineQueueAndReconnect(waitingForInFlight: true)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        cancellation.attach(work)
    }

    /// Bridges `expirationHandler` — which can fire before the `Task` exists —
    /// to the task itself. A handler that captured `work` directly could not
    /// be installed until after the task had already started running.
    private final class TaskCancellationBox {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelledEarly = false

        func attach(_ task: Task<Void, Never>) {
            lock.lock()
            let alreadyCancelled = cancelledEarly
            self.task = task
            lock.unlock()
            if alreadyCancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            let task = self.task
            cancelledEarly = true
            lock.unlock()
            task?.cancel()
        }
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
        // Same post/cancel pair as `LocTraceForegroundService`: tell the user
        // when tracking has stopped for a reason only they can fix, and take
        // the notice back down when it resolves.
        if available {
            TraceNotifier.clearLocationDisabled()
        } else {
            TraceNotifier.showLocationDisabled()
        }
    }
}
