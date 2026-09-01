import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

/// Wraps `CLLocationManager`. Mirrors `LocationEngine.kt`'s shape (continuous
/// updates + one-shot fetch), configured per the work plan's true-background
/// requirements: `allowsBackgroundLocationUpdates`, no automatic pausing, and
/// significant-location-change monitoring as the low-power / relaunch-trigger
/// fallback (see `TraceBackgroundCoordinator`).
///
/// Threading rules this file holds to, because both were violated in earlier
/// revisions and each produced a hang or a crash rather than a wrong value:
///   - Every `CLLocationManager` call is made on the main queue. The public
///     methods here are reachable from the CoreLocation delegate thread, from
///     a cooperative-pool `Task`, and from the host app's main thread.
///   - Every piece of mutable state — including `listener` and `activeMode` —
///     goes through `lock`, and the lock is never held across a call out to
///     the listener or a continuation resume.
public final class TraceLocationEngine: NSObject {
    private let manager = CLLocationManager()

    // MARK: State (all guarded by `lock`)

    private weak var listener: LocationUpdateListener?
    private var oneShotContinuation: CheckedContinuation<CLLocation, Error>?
    /// Set the moment a one-shot is claimed, cleared when it resolves. A
    /// second caller is rejected against *this*, not against
    /// `oneShotContinuation`: the continuation is only stored after the
    /// caller suspends, so two callers could both see it nil, and the first
    /// one's continuation would be overwritten and never resumed.
    private var oneShotInFlight = false
    /// Identifies the in-flight request so a timeout armed for request *n*
    /// cannot fail request *n+1*.
    private var oneShotToken: UInt64 = 0

    /// The mode the current subscription was started with, kept so
    /// `refreshLocationUpdates()` can re-apply it after a `TraceMode` change
    /// without the caller having to hand it back.
    private var activeMode: TraceMode?
    /// `LocationRequest.setMinUpdateIntervalMillis` has no CoreLocation
    /// equivalent — CoreLocation is purely distance-gated — so the rate limit
    /// is enforced here. Without it `TraceMode.active` (`updateInterval: 5`,
    /// `distanceFilter: 0`) ran as free-running updates on iOS, publishing far
    /// more often than the same mode does on Android.
    private var minimumInterval: TimeInterval = 0
    private var lastDeliveredAt: Date?
    /// `setMaxUpdateDelayMillis` equivalent: fixes are held and handed to the
    /// listener in one burst per `pingSyncInterval`, so a batch of publishes
    /// costs one radio wake instead of `n`.
    private var batchWindow: TimeInterval = 0
    private var batched: [CLLocation] = []
    private var batchTimer: DispatchSourceTimer?
    /// Ceiling on the hold-back buffer. A long background stretch with a large
    /// `pingSyncInterval` must not accumulate unboundedly.
    private let maxBatchSize = 50

    private let lock = NSLock()
    /// The batch timer lives here rather than on `.main`, which is not drained
    /// while the app is suspended in the background — the exact window this
    /// buffer exists to span.
    private let batchQueue = DispatchQueue(label: "com.barikoi.trace.locationbatch")

    /// Default timeout for a one-shot fetch. `requestLocation()` is documented
    /// to deliver or fail, but in practice it can also go silent; an
    /// un-timed-out wait is a permanent hang for the caller and a leaked
    /// `CheckedContinuation`.
    private static let defaultOneShotTimeout: TimeInterval = 30

    public override init() {
        super.init()
        onMain { self.manager.delegate = self }
        observeAppLifecycle()
    }

    deinit {
        #if canImport(UIKit)
        NotificationCenter.default.removeObserver(self)
        #endif
        batchTimer?.cancel()
        // A one-shot still in flight would otherwise never be resumed —
        // a permanent hang for its caller plus a checked-continuation leak.
        oneShotContinuation?.resume(throwing: TraceError.locationNotFoundError())
    }

    /// `CLLocationManager` is not thread-safe and expects to be driven from the
    /// thread it was created on. `async` (not `sync`) throughout: a `sync` hop
    /// from the CoreLocation delegate thread would deadlock against a main
    /// thread waiting on `lock`.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// True only if the host app declares the `location` background mode.
    /// Setting `allowsBackgroundLocationUpdates` without it raises
    /// `NSInvalidArgumentException` and takes the app down — authorization
    /// alone is not enough to make the assignment safe.
    private static var hasLocationBackgroundMode: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }()

    private static var canEnableBackgroundUpdates: Bool {
        hasLocationBackgroundMode && SystemSettingsManager.hasAlwaysAuthorization()
    }

    /// The held-back batch is the one piece of state that lives only in RAM.
    /// Android gets batching from the system (`setMaxUpdateDelayMillis`), which
    /// survives the process; this buffer does not, so it is drained at every
    /// point the app might be about to stop running. That bounds the loss
    /// window to an outright crash instead of every backgrounding.
    private func observeAppLifecycle() {
        #if canImport(UIKit)
        let names: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleAppLifecycleEvent), name: name, object: nil
            )
        }
        #endif
    }

    @objc private func handleAppLifecycleEvent() { flushBatch() }

    // MARK: - Continuous updates

    public func startLocationUpdates(traceMode: TraceMode, listener: LocationUpdateListener) {
        guard SystemSettingsManager.checkPermissions() else {
            // Nothing is retained on a refused start: `activeMode` is what
            // `currentMode`/`isEngineRunning`/`isLocationTracking()` answer
            // from, and holding the listener would let a lifecycle flush
            // deliver into a session that never began.
            clearSession()
            listener.onFailure(.locationPermissionError())
            return
        }

        // Drained before the new listener is installed: these fixes were
        // produced under the previous mode, for the previous listener, and
        // handing them to a newly-installed one misattributes them.
        flushBatch()

        lock.lock()
        self.listener = listener
        self.activeMode = traceMode
        minimumInterval = traceMode.updateInterval > 0 ? TimeInterval(traceMode.updateInterval) : 0
        batchWindow = (traceMode.updateInterval > 0 && traceMode.pingSyncInterval > 0)
            ? TimeInterval(traceMode.pingSyncInterval)
            : 0
        lastDeliveredAt = nil
        lock.unlock()

        onMain {
            self.manager.desiredAccuracy = TraceLocationEngine.accuracy(for: traceMode.desiredAccuracy)
            // Interval and distance are alternatives, matching
            // `LocationEngine.kt`'s if/else-if: an interval-driven mode must
            // not also be distance-gated, or a stationary device reports
            // nothing at all.
            if traceMode.updateInterval > 0 {
                self.manager.distanceFilter = kCLDistanceFilterNone
            } else {
                self.manager.distanceFilter = traceMode.distanceFilter > 0
                    ? CLLocationDistance(traceMode.distanceFilter)
                    : kCLDistanceFilterNone
            }

            // Required for the app to keep receiving updates once backgrounded.
            self.manager.allowsBackgroundLocationUpdates = TraceLocationEngine.canEnableBackgroundUpdates
            self.manager.pausesLocationUpdatesAutomatically = false
            self.manager.activityType = .otherNavigation
            self.manager.startUpdatingLocation()
        }
    }

    /// Re-applies the stored `TraceMode` to a live subscription. `LocationEngine`
    /// is configured once at `startUpdatingLocation()`, so without this a
    /// `setTraceMode(_:)` mid-session changed nothing until the next
    /// stop/start — the gap `LocTraceManager.refreshTracking()` closes on
    /// Android.
    public func refreshLocationUpdates(traceMode: TraceMode) {
        lock.lock()
        let current = listener
        lock.unlock()
        guard let current else { return }

        flushBatch()

        // Re-checked after the flush: delivering the buffered fixes runs the
        // listener, and the listener can stop tracking (the daily window
        // closing does exactly that). Restarting on the strong local captured
        // above would resurrect a session that was just torn down, with
        // nothing left holding a reference to stop it again.
        lock.lock()
        let stillActive = listener != nil
        lock.unlock()
        guard stillActive else { return }

        onMain { self.manager.stopUpdatingLocation() }
        startLocationUpdates(traceMode: traceMode, listener: current)
    }

    /// The mode this engine is currently running with, if any.
    public var currentMode: TraceMode? {
        lock.lock()
        defer { lock.unlock() }
        return activeMode
    }

    public func stopLocationUpdates() {
        flushBatch()
        onMain { self.manager.stopUpdatingLocation() }
        clearSession()
    }

    private func clearSession() {
        lock.lock()
        batchTimer?.cancel()
        batchTimer = nil
        batched.removeAll()
        activeMode = nil
        listener = nil
        lock.unlock()
    }

    // MARK: - Rate limiting / batching

    /// Returns true when this fix is far enough past the previous delivery to
    /// pass the `updateInterval` gate.
    private func passesRateLimit(_ location: CLLocation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A fix timestamped in the future must not become the reference point:
        // it would gate every subsequent fix until the next restart.
        guard location.timestamp.timeIntervalSinceNow < 5 else { return false }
        guard minimumInterval > 0 else { return true }
        if let last = lastDeliveredAt, location.timestamp.timeIntervalSince(last) < minimumInterval {
            return false
        }
        lastDeliveredAt = location.timestamp
        return true
    }

    /// Hands `location` to the listener, either immediately or on the next
    /// batch boundary when `pingSyncInterval` is configured.
    private func deliver(_ location: CLLocation) {
        lock.lock()
        // Batching is a power optimization that only makes sense while the
        // process is guaranteed to still be running when the window closes.
        // Backgrounded, it is the opposite: iOS can suspend between the append
        // and the flush, so a held fix waits for the *next* wake instead of
        // going out in this one. Android's `setMaxUpdateDelayMillis` batches
        // inside the system, which is why it has no such problem.
        let window = AppState.isBackground ? 0 : batchWindow
        guard window > 0 else {
            let target = listener
            lock.unlock()
            target?.onLocationReceived(location)
            return
        }
        batched.append(location)
        // The cap has to be enforced on the way in, not only via `flushBatch`:
        // `flushBatch` declines to drain when no listener is installed, so a
        // buffer that outlives its listener would otherwise grow without
        // bound. Oldest goes first.
        if batched.count > maxBatchSize { batched.removeFirst(batched.count - maxBatchSize) }
        let full = batched.count >= maxBatchSize
        if batchTimer == nil && !full {
            let timer = DispatchSource.makeTimerSource(queue: batchQueue)
            timer.schedule(deadline: .now() + window)
            timer.setEventHandler { [weak self] in self?.flushBatch() }
            batchTimer = timer
            timer.resume()
        }
        lock.unlock()

        if full { flushBatch() }
    }

    private func flushBatch() {
        lock.lock()
        batchTimer?.cancel()
        batchTimer = nil
        let target = listener
        // Kept when there is no one to deliver to: dropping them here would
        // discard fixes that a subsequent `startLocationUpdates` could still
        // hand over.
        guard target != nil else {
            lock.unlock()
            return
        }
        let pending = batched
        batched.removeAll()
        lock.unlock()

        for location in pending { target?.onLocationReceived(location) }
    }

    // MARK: - Significant-location-change (fallback wake source + relaunch-after-kill trigger)

    public func startMonitoringSignificantLocationChanges() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        onMain { self.manager.startMonitoringSignificantLocationChanges() }
    }

    public func stopMonitoringSignificantLocationChanges() {
        onMain { self.manager.stopMonitoringSignificantLocationChanges() }
    }

    // MARK: - One-shot fetch (mirrors LocationEngine.kt's getCurrentLocation())

    public func getCurrentLocation() async throws -> CLLocation {
        try await getCurrentLocation(timeout: Self.defaultOneShotTimeout)
    }

    /// - Parameter timeout: bound for callers running inside a window the OS
    ///   will close on them — a `BGProcessingTask` that never reaches
    ///   `setTaskCompleted` is penalized in future scheduling.
    ///
    /// One request at a time. A concurrent second caller is failed rather than
    /// queued, because the alternative — overwriting the stored continuation —
    /// strands the first caller forever.
    public func getCurrentLocation(timeout: TimeInterval) async throws -> CLLocation {
        guard SystemSettingsManager.checkPermissions() else {
            throw TraceError.locationPermissionError()
        }

        // Claimed *before* suspending, so two callers cannot both pass.
        lock.lock()
        guard !oneShotInFlight else {
            lock.unlock()
            throw TraceError.locationNotFoundError()
        }
        oneShotInFlight = true
        oneShotToken &+= 1
        let token = oneShotToken
        lock.unlock()

        return try await withTaskCancellationHandler {
            try await awaitOneShot(token: token, timeout: timeout)
        } onCancel: {
            // Without this, a cancelled `BGProcessingTask` still waited out the
            // full timeout before `setTaskCompleted` — the classic watchdog
            // termination. `withCheckedThrowingContinuation` does not observe
            // cancellation on its own.
            cancelOneShot(token: token)
        }
    }

    /// Cancellation can land before the continuation exists —
    /// `withTaskCancellationHandler` runs `onCancel` immediately when the task
    /// is already cancelled at install time, which is precisely the expired
    /// `BGProcessingTask` case. Resolving the (absent) continuation would do
    /// nothing and leave `oneShotInFlight` set, so the request would then
    /// proceed and wait out its whole timeout. Releasing the claim here makes
    /// the guard in `awaitOneShot` fail instead.
    private func cancelOneShot(token: UInt64) {
        lock.lock()
        guard oneShotToken == token else {
            lock.unlock()
            return
        }
        let continuation = oneShotContinuation
        oneShotContinuation = nil
        oneShotInFlight = false
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
    }

    private func awaitOneShot(token: UInt64, timeout: TimeInterval) async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            // The task may already have been cancelled before this body ran;
            // `cancelOneShot` releases the claim in that case, so this guard
            // is what stops the request from going out at all.
            guard oneShotInFlight, oneShotToken == token else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            oneShotContinuation = continuation
            lock.unlock()

            onMain {
                // The one-shot engine is used from background wake windows, so
                // it needs the same background-updates flag the continuous one
                // sets — without it the request may never deliver there.
                self.manager.allowsBackgroundLocationUpdates = TraceLocationEngine.canEnableBackgroundUpdates
                self.manager.requestLocation()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                // Token check: only time out the request this timer was armed
                // for.
                guard self.oneShotToken == token, let pending = self.oneShotContinuation else {
                    self.lock.unlock()
                    return
                }
                self.oneShotContinuation = nil
                self.oneShotInFlight = false
                self.lock.unlock()
                pending.resume(throwing: TraceError.locationNotFoundError())
            }
        }
    }

    /// Hands the pending one-shot its result, if there is one. Returns whether
    /// this callback was consumed by a one-shot rather than the continuous
    /// stream.
    private func resolveOneShot(_ result: Result<CLLocation, Error>) -> Bool {
        lock.lock()
        guard let continuation = oneShotContinuation else {
            lock.unlock()
            return false
        }
        oneShotContinuation = nil
        oneShotInFlight = false
        lock.unlock()

        continuation.resume(with: result)
        return true
    }

    // MARK: - Authorization

    public func requestAuthorization(always: Bool) {
        onMain {
            if always {
                self.manager.requestAlwaysAuthorization()
            } else {
                self.manager.requestWhenInUseAuthorization()
            }
        }
    }

    private static func accuracy(for desired: TraceMode.DesiredAccuracy) -> CLLocationAccuracy {
        switch desired {
        case .high: return kCLLocationAccuracyBest
        case .medium: return kCLLocationAccuracyHundredMeters
        case .low: return kCLLocationAccuracyKilometer
        }
    }

    private func currentListener() -> LocationUpdateListener? {
        lock.lock()
        defer { lock.unlock() }
        return listener
    }
}

extension TraceLocationEngine: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }

        if resolveOneShot(.success(newest)) { return }

        // Every location in the array, not just the newest. iOS defers
        // delivery while the app is suspended and then hands over the whole
        // stretch at once; keeping only `locations.last` threw away the middle
        // of the track and left gaps a foreground service never produces.
        // Android's `LocationResult` is drained the same way.
        for location in locations {
            // `updateInterval` gate first, then the `pingSyncInterval` batch —
            // same order as `LocationRequest`'s minUpdateInterval /
            // maxUpdateDelay. The gate also does the thinning here: a deferred
            // burst is exactly what `updateInterval` is meant to rate-limit.
            guard passesRateLimit(location) else { continue }
            deliver(location)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if resolveOneShot(.failure(TraceError.locationNotFoundError())) { return }
        currentListener()?.onFailure(.locationNotFoundError())
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let listener = currentListener()
        // Losing authorization ends the subscription as far as CoreLocation is
        // concerned, so the engine stops claiming to be running — that is what
        // makes `TraceManager.isLocationTracking()`'s "live state, not just the
        // flag" contract true rather than aspirational.
        if !SystemSettingsManager.checkPermissions() {
            flushBatch()
            clearSession()
        }

        // This is the one callback that reliably follows a change to the
        // device-wide Location Services switch, so it is where the cached
        // answer is refreshed — and the listener is notified from the
        // completion rather than from a synchronous re-read, which would
        // still be looking at the pre-change value and would take the
        // "location is off" notification straight back down again.
        SystemSettingsManager.refreshLocationServicesState { enabled in
            listener?.onProviderAvailabilityChanged(enabled)
        }
    }
}
