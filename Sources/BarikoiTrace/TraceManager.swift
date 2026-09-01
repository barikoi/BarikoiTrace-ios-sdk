import CoreLocation
import Foundation
import os

/// Orchestrator singleton — mirrors `LocTraceManager.kt`'s public surface and
/// wires `TraceDataStore`, `TraceApiClient`, `TraceLocationEngine`/
/// `TraceBackgroundCoordinator`, `TraceMqttClient`, and `OfflineLocationStore`
/// together. `BarikoiTrace` (the public facade) is a thin static wrapper
/// around this class, same relationship as `BarikoiTrace.kt` has to
/// `LocTraceManager.kt`.
public final class TraceManager: NSObject, TraceManagerProtocol {
    public static let shared = TraceManager()

    // Eagerly constructed, not `lazy`. Swift's `lazy` is not atomic, and this
    // is a singleton whose members are first touched from several threads
    // (`initialize` on main, `setOrCreateUser` from an arbitrary Task, the
    // CoreLocation callback thread). Two concurrent first-touches could build
    // two coordinators — meaning two `CLLocationManager` stacks and a
    // duplicate `BGTaskScheduler` registration, which traps.
    private let dataStore: TraceDataStore
    private let apiClient: TraceApiClient
    private let offlineStore: OfflineLocationStore
    private let backgroundCoordinator: TraceBackgroundCoordinator
    private let oneShotLocationEngine = TraceLocationEngine()

    /// Guarded by `mqttLock` — `connectMqttIfPossible()` runs both on the
    /// CoreLocation callback thread (`handleLocation`) and off-thread from
    /// `flushOfflineQueueAndReconnect()`'s `Task`, so the check-then-create
    /// below would otherwise be able to build two clients, leaking one with a
    /// live socket.
    private var mqttClient: TraceMqttClient?
    /// Identity + broker the live `mqttClient` was built for. A mismatch means
    /// the client is publishing to a topic or broker that no longer matches
    /// the current user/config, so it is retired and rebuilt.
    private var mqttClientFingerprint: String?
    /// De-dupes the per-fix "why is MQTT not up" log — see `logMqttBlocked`.
    /// Also `mqttLock`-guarded.
    private var lastMqttBlockReason: String?
    /// Whether the SDK is currently allowed to hold a broker connection.
    /// `mqttLock`-guarded. Set by `startTracking`/`uploadOfflineData`, cleared
    /// by `stopTracking`. Without it, a flush `Task` still in flight across a
    /// stop reached `connectMqttIfPossible()`, found `mqttClient` already
    /// nil'd, and built a *fresh* connected client that nothing would ever
    /// tear down — the SDK reporting stopped while a broker socket stayed up
    /// for the rest of the process.
    private var isMqttPermitted = false
    /// Bumped by every teardown. `connectMqttIfPossible()` builds and connects
    /// its client across two separate lock holds — it cannot hold the lock
    /// while connecting — so it compares this afterwards to find out whether a
    /// stop landed mid-flight, and destroys what it built if so. A permit flag
    /// alone could not close that window: the ordering that leaks is
    /// build-then-clear, which passes any number of permit checks.
    private var mqttTeardownGeneration: UInt64 = 0
    /// Bumped by every *grant*. `uploadOfflineData` captures it and only tears
    /// its connection down if the value is unchanged — otherwise a
    /// `startTracking()` that landed during the upload's flush would have its
    /// brand-new permit revoked by the upload's cleanup, leaving tracking on
    /// with MQTT permanently refused. Reading `isSdkTracking()` alone cannot
    /// close that: the read and the teardown are two separate steps.
    private var mqttPermitGeneration: UInt64 = 0
    /// The fingerprint the broker rejected. While it matches the current one,
    /// connecting is pointless — see `mqttConnectionStatusChanged`.
    private var rejectedFingerprint: String?
    /// See `TraceMqttClient.defaultClientIdPrefix` — part of the fingerprint,
    /// so changing it rebuilds the client and clears any rejection recorded
    /// against the old one.
    private var mqttClientIdPrefix = TraceMqttClient.defaultClientIdPrefix
    private let mqttLock = NSLock()

    /// How long a flush waits for the broker before deferring to the next
    /// wake. Comfortably inside the ~30s an expiring background assertion
    /// leaves, and long enough for a TCP connect plus CONNACK on a slow
    /// mobile link.
    private static let connectWaitTimeout: TimeInterval = 12

    /// Matches `LocTraceForegroundService`'s 10s rule.
    private static let foregroundMaxFixAge: TimeInterval = 10
    /// Deferred background delivery can hand over fixes several minutes old;
    /// they are still the only fixes for that stretch of the track, so they are
    /// worth publishing. Anything older than this is a stale cache hit rather
    /// than a deferred delivery.
    private static let backgroundMaxFixAge: TimeInterval = 10 * 60
    /// Tolerance for a fix timestamped slightly ahead of `Date()` — normal
    /// jitter between the GPS clock and the system clock.
    private static let maximumClockSkew: TimeInterval = 5
    private let locationBroadcast = AsyncBroadcast<CLLocation>()
    /// The last fix that passed validation — `LocTraceForegroundService`'s
    /// `lastLocation`. The trip-completion publish needs it to send a real
    /// position rather than a bare id pair.
    private var lastValidLocation: CLLocation?
    private let lastLocationLock = NSLock()
    /// Guards `stopTracking()` against re-entering itself via the location
    /// batch it drains — see the comment there.
    private var isStopping = false
    private let stopLock = NSLock()

    public var locationUpdates: AsyncStream<CLLocation> { locationBroadcast.stream() }
    public weak var logListener: TraceLogListener?

    private override init() {
        // Locals, not `self.dataStore` — in an `NSObject` subclass no instance
        // property may be *read* before `super.init()`, even one that was just
        // assigned. (`lazy` sidestepped this by deferring the read; it is also
        // not atomic, which is why these are eager now.)
        let store = TraceDataStore()
        let offline = OfflineLocationStore.shared
        dataStore = store
        offlineStore = offline
        apiClient = TraceApiClient(dataStore: store)
        backgroundCoordinator = TraceBackgroundCoordinator(dataStore: store, offlineStore: offline)
        super.init()
    }

    // MARK: - Init

    public func setMqttCredentials(username: String, password: String) {
        dataStore.setMqttCredentials(username: username, password: password)
        // New credentials are a reason to try again — the fingerprint changes,
        // but clearing here also covers a re-`initialize` with the same values
        // after a broker-side fix.
        mqttLock.lock()
        rejectedFingerprint = nil
        mqttLock.unlock()
    }

    public func initialize(apiKey: String) {
        // Started first: the staleness rule and the batching bypass both ask
        // whether the process is backgrounded, and a relaunch triggered by a
        // significant location change begins in exactly that state.
        AppState.startObserving()

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
        // The coordinator's relaunch path calls `start(mode:)` directly rather
        // than going back through `startTracking`, so the broker permit has to
        // be granted too — otherwise a significant-location-change relaunch
        // tracks with MQTT refused and sends every fix to the offline queue.
        // Granted only if it actually started, not merely because the
        // persisted flag says tracking was on: `initialize()`'s resume can bail
        // on missing permissions while leaving that flag set, and a permit with
        // nothing tracking lets the background task open a broker connection
        // for a stopped SDK.
        guard backgroundCoordinator.handleLaunch(options: options) else { return }
        grantMqttPermit()
    }

    // MARK: - User

    /// Authenticates/creates the user, then opportunistically refreshes the
    /// remote `TraceMode` settings as a side effect.
    ///
    /// **Error-handling decision (was an open question in `docs/STATUS.md`,
    /// resolved here rather than left pending):** the settings refresh below
    /// swallows its own failure into a log line, but `getSettingsFromRemote()`
    /// — the explicit, caller-invoked version of the same fetch — propagates
    /// errors normally via `throws`. That split is deliberate, not an
    /// oversight to "fix" toward one behavior everywhere:
    ///   - Here, the settings fetch is an *implicit* side effect of a
    ///     successful authentication. A caller asked to authenticate a user,
    ///     not to fetch settings; failing the whole call because a secondary,
    ///     best-effort step failed would be surprising, and `TraceDataStore`
    ///     already has a sane fallback (`TraceMode`'s defaults) for a device
    ///     that has never received remote settings. This matches
    ///     `LocTraceManager.kt`'s intent, not just its mechanism.
    ///   - `getSettingsFromRemote()` is the *explicit* version — a caller
    ///     invoking it directly is asking specifically for this network call
    ///     to succeed or fail, so it should see the real error (e.g. to show
    ///     a "couldn't refresh settings" UI state), not a silently-swallowed
    ///     one.
    /// If a host app needs to know the implicit refresh above failed too,
    /// call `getSettingsFromRemote()` explicitly after `setOrCreateUser`
    /// rather than changing this method's error behavior.
    public func setOrCreateUser(name: String?, email: String?, phone: String) async throws -> TraceUser {
        guard !phone.isEmpty else { throw TraceError.noDataError() }
        guard let apiKey = dataStore.getApiKey(), !apiKey.isEmpty else { throw TraceError.noKeyError() }

        // 24h local-cache short-circuit, mirrors LocTraceManager.kt.
        if let cached = dataStore.getUser(), cached.phone == phone,
           (Date().timeIntervalSince1970 * 1000 - cached.updatedAt) < 24 * 60 * 60 * 1000 {
            return cached
        }

        // Waits briefly for the path monitor's first real update rather than
        // deciding from its seed value — this runs seconds after launch, where
        // the seed was previously the only thing available.
        guard await NetworkChecker.isNetworkAvailable(waitingUpTo: 1) else { throw TraceError.networkError() }

        let user = try await apiClient.authenticate(name: name, email: email, phone: phone)
        apiClient.setUserId(user.userId)

        if let phone = user.phone, !phone.isEmpty {
            do {
                let mode = try await apiClient.getCompanySettings(phone: phone)
                dataStore.setTraceModeWithTiming(mode)
            } catch {
                // Deliberately swallowed — see the method doc comment above.
                log(level: "WARN", tag: "TraceManager", message: "Failed to fetch remote settings: \(error)")
            }
        }

        return user
    }

    public func getUser() -> TraceUser? { dataStore.getUser() }
    public func getUserId() -> String? { dataStore.getUserId() }

    // MARK: - URLs

    public func setBaseURL(_ url: String) {
        // Collapses repeated trailing slashes, matching Kotlin's
        // `trimEnd('/') + "/"`. Appending only when absent let
        // `https://x/api/v1//` through and produced double-slash request paths.
        let normalized = String(url.reversed().drop { $0 == "/" }.reversed()) + "/"
        guard dataStore.getBaseURL() != normalized else { return }
        dataStore.setBaseURL(normalized)
        dataStore.clearUser()
        dataStore.clearTraceModeWithTiming()
        apiClient.setBaseURL(normalized)
        stopTracking()
    }

    public func setMqttURL(_ url: String) { dataStore.setMqttURL(url) }

    /// Overrides the MQTT client-id prefix — see
    /// `TraceMqttClient.defaultClientIdPrefix`. Call before `startTracking`.
    public func setMqttClientIdPrefix(_ prefix: String) {
        mqttLock.lock()
        mqttClientIdPrefix = prefix
        // The prefix is part of the fingerprint, so a change already forces a
        // rebuild; clearing the rejection makes the retry immediate rather
        // than waiting for the next `startTracking`.
        rejectedFingerprint = nil
        mqttLock.unlock()
    }

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
        // `CLLocationManager` is configured once at `startUpdatingLocation()`,
        // so persisting alone left a mid-session mode change inert until the
        // next stop/start. Android has to bounce its foreground service to
        // achieve this (`LocTraceManager.refreshTracking()`); here it is just
        // a reconfigure.
        if dataStore.isSdkTracking() {
            backgroundCoordinator.refresh(mode: mode)
        }
    }

    /// Re-applies the stored `TraceMode` to a running session. Mirrors
    /// `LocTraceManager.refreshTracking()`. No-op when not tracking.
    public func refreshTracking() {
        guard dataStore.isSdkTracking() else { return }
        backgroundCoordinator.refresh(mode: dataStore.getTraceMode())
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

        // The monotonic floor belongs to a session, not to the process. A
        // clock correction (or simply a long gap) must not leave a stale
        // high-water mark rejecting every fix of the new session.
        lastLocationLock.lock()
        lastValidLocation = nil
        lastLocationLock.unlock()

        // Each session gets one fresh attempt at the broker. Brokers return
        // `notAuthorized` for a momentarily unreachable auth backend as well
        // as for genuinely wrong credentials, and without this a single such
        // CONNACK disabled publishing until the app was relaunched.
        mqttLock.lock()
        rejectedFingerprint = nil
        mqttLock.unlock()

        // Permit first, then the tracking flag. The reverse order let
        // `uploadOfflineData`'s cleanup — which decides by reading
        // `isSdkTracking()` — observe "tracking off" while this method was
        // already underway, and revoke the permit for a session that had just
        // started.
        grantMqttPermit()

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
        // Re-entrancy guard. `stop()` below drains the location engine's
        // batch, and those fixes run back through `handleLocation` — which
        // calls `stopTracking()` itself when the daily window has closed. That
        // is the path that put this method on its own stack twice.
        stopLock.lock()
        guard !isStopping else {
            stopLock.unlock()
            return
        }
        isStopping = true
        stopLock.unlock()
        defer {
            stopLock.lock()
            isStopping = false
            stopLock.unlock()
        }

        // Stop the engine *first*, so its held-back batch is delivered — and
        // published or queued — while tracking is still notionally on. Setting
        // the flag first made that final drain a no-op against
        // `handleLocation`'s `isSdkTracking()` guard, silently discarding up
        // to `pingSyncInterval` worth of fixes on every stop. Matches
        // `LocTraceForegroundService.onDestroy()`, which also tears the
        // location subscription down before its final publish.
        backgroundCoordinator.stop()

        // Best-effort final "completed" publish. If the process is killed
        // instead of calling stopTracking(), this never fires — same gap the
        // Kotlin SDK has in LocTraceForegroundService.onDestroy(), documented
        // rather than silently inherited (see the work plan's Phase 0).
        let client = currentMqttClient()
        if let tripId = dataStore.getLocalTripId(), client?.isConnectedNow() == true {
            lastLocationLock.lock()
            let location = lastValidLocation
            lastLocationLock.unlock()
            let user = dataStore.getUser()
            client?.publish(json: TraceLocationPayload.completedTripJson(
                tripId: tripId, location: location,
                userId: user?.userId, companyId: user?.companyId, userName: user?.name
            ))
        }
        dataStore.stopSdkTracking()
        dataStore.clearLocalTrip()

        lastLocationLock.lock()
        lastValidLocation = nil
        lastLocationLock.unlock()

        // Released, not just disconnected. A retained client is one
        // `connectMqttIfPossible()` away from reconnecting, and after a stop
        // the next start may well be for a different user anyway. The client
        // is re-read *inside* this hold rather than reusing the snapshot
        // above: a `connectMqttIfPossible()` running concurrently may have
        // installed a different one since, and destroying the stale snapshot
        // would leave that one connected and unreachable.
        let orphan = teardownMqtt()
        orphan?.destroy()
    }

    /// Grants the broker permit. Returns the grant's generation, for callers
    /// that need to know later whether theirs is still the current one.
    @discardableResult
    private func grantMqttPermit() -> UInt64 {
        mqttLock.lock()
        defer { mqttLock.unlock() }
        isMqttPermitted = true
        mqttPermitGeneration &+= 1
        return mqttPermitGeneration
    }

    /// Clears the broker permit and the current client, bumping
    /// `mqttTeardownGeneration` so any `connectMqttIfPossible()` in flight can
    /// see that its work has been superseded. Returns the client the caller
    /// must `destroy()` — outside the lock.
    private func teardownMqtt() -> TraceMqttClient? {
        mqttLock.lock()
        defer { mqttLock.unlock() }
        return teardownMqttLocked()
    }

    /// Tears down only if `generation` is still the current grant and tracking
    /// is off. Both conditions and the teardown itself happen in one hold —
    /// checking first and tearing down after would let a `startTracking()` slip
    /// between them and lose its permit.
    private func teardownMqttIfStillOwned(by generation: UInt64) -> TraceMqttClient? {
        mqttLock.lock()
        defer { mqttLock.unlock() }
        guard mqttPermitGeneration == generation, !dataStore.isSdkTracking() else { return nil }
        return teardownMqttLocked()
    }

    /// Caller must hold `mqttLock`.
    private func teardownMqttLocked() -> TraceMqttClient? {
        isMqttPermitted = false
        mqttTeardownGeneration &+= 1
        let client = mqttClient
        mqttClient = nil
        mqttClientFingerprint = nil
        return client
    }

    /// True only when the SDK both intends to track *and* has a live location
    /// subscription. The flag alone stayed `true` after, say, an authorization
    /// revocation that stopped the engine — Android answers this from the real
    /// service state, so this does too.
    public func isLocationTracking() -> Bool {
        dataStore.isSdkTracking() && backgroundCoordinator.isEngineRunning
    }
    public func setOfflineTracking(_ enabled: Bool) { dataStore.setOfflineTracking(enabled) }
    public func setLoggingEnabled(_ enabled: Bool) { dataStore.setLogging(enabled) }
    public func setBroadcastingEnabled(_ enabled: Bool) { dataStore.setBroadcasting(enabled) }

    // MARK: - Trips

    public func isOnTrip() -> Bool { dataStore.getLocalTripId() != nil }
    public func getTripId() -> String? { dataStore.getLocalTripId() }

    // MARK: - Location

    /// Prompts for location authorization. Routed through the one-shot engine
    /// rather than a throwaway `CLLocationManager` so the delegate that
    /// receives the authorization callback outlives the prompt.
    public func requestAuthorization(always: Bool) {
        oneShotLocationEngine.requestAuthorization(always: always)
    }

    public func updateCurrentLocation() async throws -> CLLocation {
        let location = try await oneShotLocationEngine.getCurrentLocation()
        persistOrPublish(location)
        return location
    }

    public func uploadOfflineData() {
        // An explicit upload is its own permission to connect — this is the
        // one entry point that legitimately wants a broker connection while
        // tracking is off, and it is the caller asking for it directly.
        let grant = grantMqttPermit()

        Task {
            await flushOfflineQueueAndReconnect()
            // A one-off upload owns the connection it opened. Left permitted,
            // the flag would stay on for the process and the client it built
            // would sit connected with no teardown path — `stopTracking()` is
            // the only other thing that clears either, and the caller may
            // never have been tracking at all.
            // Only if this upload's grant is still the live one: a
            // `startTracking()` during the flush issues a newer grant, and
            // revoking it here would leave tracking running with MQTT refused
            // for the rest of the process.
            teardownMqttIfStillOwned(by: grant)?.destroy()
        }
    }

    /// Explicit settings refresh — unlike the implicit one inside
    /// `setOrCreateUser`, this one throws on failure rather than swallowing
    /// it. See `setOrCreateUser`'s doc comment for why the two differ.
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
        // A fix can still arrive after `stopTracking()` — a CoreLocation
        // callback already in flight, a drained batch, or the background
        // task's one-shot. Without this guard those reached
        // `connectMqttIfPossible()` and reopened the broker connection after
        // the caller had stopped.
        guard dataStore.isSdkTracking() else { return }

        // Ordered exactly as `LocTraceForegroundService.onLocationReceived`:
        // the daily window is checked before the fix is validated, because
        // being outside it ends the session rather than skipping one fix.
        guard isWithinTrackingWindow() else {
            log(level: "INFO", tag: "TraceManager", message: "Outside the configured tracking window — stopping tracking")
            stopTracking()
            return
        }
        guard isValid(location) else { return }

        lastLocationLock.lock()
        lastValidLocation = location
        lastLocationLock.unlock()

        if dataStore.isBroadcasting() {
            locationBroadcast.yield(location)
        }

        persistOrPublish(location)
    }

    /// Mirrors `LocTraceForegroundService.kt`'s window check: a company can
    /// configure `tracking_start_time`/`tracking_end_time` via
    /// `/sdk/company/settings`, and outside that range the SDK stops tracking
    /// itself. iOS parsed and stored both ends but compared them to nothing,
    /// so company-configured windows were silently ignored on this platform.
    /// An end time of 23:59:59 (`TraceMode.dayEnd`) means "no window", the
    /// same sentinel role `LocalTime.MAX` plays on Android.
    private func isWithinTrackingWindow() -> Bool {
        let mode = dataStore.getTraceMode()
        guard mode.endTime != TraceMode.dayEnd else { return true }

        let calendar = Calendar.current
        let now = calendar.dateComponents([.hour, .minute, .second], from: Date())
        func seconds(_ components: DateComponents) -> Int {
            (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0)
        }
        let nowSeconds = seconds(now)
        let start = seconds(mode.startTime)
        let end = seconds(mode.endTime)

        // A window that wraps past midnight (start > end, e.g. 22:00–06:00) is
        // treated as the union of both sides. Android's `isBefore`/`isAfter`
        // pair rejects every instant in that case, which reads as a bug rather
        // than an intent worth reproducing.
        if start > end { return nowSeconds >= start || nowSeconds <= end }
        return nowSeconds >= start && nowSeconds <= end
    }

    public func flushOfflineQueueAndReconnect() async {
        await flushOfflineQueueAndReconnect(waitingForInFlight: false)
    }

    public func flushOfflineQueueAndReconnect(waitingForInFlight: Bool) async {
        // The whole connect → publish → drain sequence runs under one
        // background assertion. Without it iOS suspends the process partway —
        // typically before the CONNACK — and the queue this method exists to
        // empty just keeps growing across wakes.
        await BackgroundActivity.shared.withAssertion(name: "barikoi.trace.flush") {
            if waitingForInFlight { await waitForInFlightSync() }
            await performFlush()
        }
    }

    /// Polls until a flush claimed by someone else has finished. Only the
    /// background task uses this — it must not report completion while the
    /// work it was scheduled for is still running detached.
    private func waitForInFlightSync() async {
        let deadline = Date().addingTimeInterval(Self.connectWaitTimeout + 5)
        while dataStore.isDataSyncing(), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func performFlush() async {
        // Single compare-and-set: the old `if isDataSyncing() { return }`
        // followed by `setDataSyncing(true)` let two of the three concurrent
        // callers both pass the check, after which whichever finished first
        // cleared the flag out from under the other.
        guard dataStore.beginDataSyncIfIdle() else { return }
        defer { dataStore.setDataSyncing(false) }

        connectMqttIfPossible()
        guard let client = currentMqttClient() else { return }

        // Don't hold a background assertion waiting on a broker that is
        // already in backoff — `connect()` will refuse until the retry timer
        // fires, so the wait can only time out. Left unchecked, an unreachable
        // broker meant a fresh 12s assertion per fix, i.e. the SDK holding one
        // essentially continuously and burning the app's background budget.
        if !client.isConnectedNow(), client.isAwaitingReconnect {
            log(level: "INFO", tag: "TraceManager", message: "Flush deferred — broker reconnect already backing off")
            return
        }

        // Otherwise wait for the socket instead of giving up on it. Returning
        // the moment `isConnectedNow()` was false — which it always is right
        // after `connect()` — is what made background delivery fail: every
        // wake started a connection it then abandoned. The wait is bounded,
        // and the assertion above is what buys the time for it.
        guard await client.waitUntilConnected(timeout: Self.connectWaitTimeout) else {
            log(level: "INFO", tag: "TraceManager", message: "Flush deferred — broker not reachable within \(Int(Self.connectWaitTimeout))s")
            return
        }

        // Bounded. `while offlineStore.count() > 0` alone is an infinite loop
        // whenever the delete fails (locked or corrupt DB): the same rows get
        // republished forever, nothing yields, and — now that the syncing flag
        // is a process-wide static — the `defer` above never runs, blocking
        // every future flush for the lifetime of the process.
        var remaining = offlineStore.count()
        // `Task.isCancelled` is checked, not just yielded on: the background
        // task's expiration handler cancels this work, and a loop that ignores
        // cancellation runs past the window the OS granted it.
        while remaining > 0, !Task.isCancelled {
            let batch = offlineStore.batch(limit: 100)
            guard !batch.isEmpty else { break }
            // Android refuses to flush at all until a user id exists, because
            // an unattributed row is useless to the broker. Same rule, but the
            // rows stay queued rather than being dropped.
            guard let user = dataStore.getUser() else {
                log(level: "WARN", tag: "TraceManager", message: "Offline flush deferred — no authenticated user to attribute rows to")
                break
            }
            for row in batch {
                client.publish(json: TraceLocationPayload.backfilled(
                    json: row.json,
                    userId: user.userId, companyId: user.companyId, userName: user.name
                ))
            }
            // Checked *before* the delete: a link that dropped mid-batch means
            // those publishes went nowhere, and deleting first would discard
            // them. Still optimistic — `publish` is fire-and-forget QoS1 with
            // no PUBACK correlation back to these rows — but it no longer
            // throws away a batch it knows failed.
            guard client.isConnectedNow() else { break }
            guard offlineStore.deleteBatch(limit: 100) else {
                log(level: "ERROR", tag: "TraceManager", message: "Offline queue delete failed — stopping flush")
                break
            }
            let afterDelete = offlineStore.count()
            // Second stall guard: a delete that reports success but frees
            // nothing would otherwise loop just as tightly.
            guard afterDelete < remaining else { break }
            remaining = afterDelete
            await Task.yield()
        }
    }

    public func log(level: String, tag: String, message: String) {
        guard dataStore.isLogging() else { return }
        // Mirrored to the unified log as well as the listener. Android writes
        // to logcat unconditionally; here, with no listener registered, an
        // integrator previously got no diagnostics at all — which is exactly
        // the situation in which they most need them. Credentials never reach
        // this method, and the payloads that do are the SDK's own status
        // lines, so they are logged as `public`.
        switch level {
        case "ERROR": TraceManager.osLog.error("[\(tag, privacy: .public)] \(message, privacy: .public)")
        case "WARN": TraceManager.osLog.warning("[\(tag, privacy: .public)] \(message, privacy: .public)")
        case "DEBUG": TraceManager.osLog.debug("[\(tag, privacy: .public)] \(message, privacy: .public)")
        default: TraceManager.osLog.info("[\(tag, privacy: .public)] \(message, privacy: .public)")
        }
        logListener?.onLog(level: level, tag: tag, message: message)
    }

    private static let osLog = Logger(subsystem: "com.barikoi.trace", category: "BarikoiTrace")

    // MARK: - Private helpers

    private func isValid(_ location: CLLocation) -> Bool {
        // Staleness. Android's rule is a flat 10s (`LocTraceForegroundService`),
        // which is safe there because the fused provider delivers each fix as
        // it is produced to an always-running service. iOS batches and *defers*
        // delivery while the app is suspended, then hands over several fixes at
        // once on the next wake — routinely timestamped minutes earlier. Under
        // the flat rule those were all discarded, which is a large part of why
        // background tracking looked dead on this platform. The 10s rule still
        // applies in the foreground, where iOS behaves like Android and a stale
        // fix really does mean a stale fix.
        let maximumAge = AppState.isBackground ? Self.backgroundMaxFixAge : Self.foregroundMaxFixAge
        let age = -location.timestamp.timeIntervalSinceNow
        guard age < maximumAge else { return false }
        // Future-dated fixes are rejected outright rather than accepted as the
        // newest. A device clock running ahead (or one that NTP later corrects
        // backwards) would otherwise set the monotonic floor below into the
        // future and silently reject every genuine fix after it.
        guard age > -Self.maximumClockSkew else {
            log(level: "WARN", tag: "TraceManager", message: "Rejected a fix timestamped in the future — check the device clock")
            return false
        }

        // Strictly newer than the last accepted fix. The 10s rule used to
        // provide this incidentally; with the background window at ten minutes
        // it has to be explicit, because `requestLocation()` (the background
        // task's periodic fetch) and the cached fix CoreLocation emits right
        // after `startUpdatingLocation()` both hand back a fix that may
        // already have been published — and it would be republished with an
        // identical `gpx_time`.
        lastLocationLock.lock()
        let previousTimestamp = lastValidLocation?.timestamp
        lastLocationLock.unlock()
        if let previousTimestamp, location.timestamp <= previousTimestamp { return false }

        // Mock-location rejection, the counterpart to
        // `SystemSettingsManager.checkIfMockProvider` on Android. `TraceError`
        // has carried `mockAppError()` since the port began with nothing
        // producing it. `sourceInformation` is iOS 15+, which is this
        // package's deployment target.
        // `isSimulatedBySoftware` only — `checkIfMockProvider` maps to exactly
        // that. `isProducedByAccessory` would additionally reject every fix
        // from a legitimate external MFi/Bluetooth GPS receiver.
        if location.sourceInformation?.isSimulatedBySoftware == true {
            log(level: "WARN", tag: "TraceManager", message: TraceError.mockAppError().message)
            return false
        }

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

        // `connectMqttIfPossible()` is asynchronous — the CONNACK is at best
        // a round-trip away — so on the first fixes after start this check is
        // *expected* to be false, and the queue below is the normal path, not
        // an error path. It used to be reached only when `isOfflineTracking()`
        // was true, and `defaults.bool(forKey:)` returns false for a key no
        // one has written, so on a fresh install every one of those fixes was
        // dropped with no log and no retry. `TraceDataStore.isOfflineTracking()`
        // now defaults to true; only an explicit `setOfflineTracking(false)`
        // makes the drop below deliberate.
        let client = currentMqttClient()
        if let client, client.isConnectedNow() {
            client.publish(json: json)
            // Drain opportunistically after every successful live publish, the
            // way `LocTraceForegroundService` does. Waiting only for the
            // `.connected` delegate, the 15-minute background task, or an
            // explicit `uploadOfflineData()` left a backlog sitting while the
            // link was demonstrably up. `beginDataSyncIfIdle()` makes the
            // extra calls cheap when a flush is already running.
            Task { await flushOfflineQueueAndReconnect() }
        } else if dataStore.isOfflineTracking() {
            offlineStore.insert(json: json)
            // Then immediately try to get it out again. The flush now holds a
            // background assertion and waits for the CONNACK, so this is what
            // turns "queued during a wake window" into "sent during the same
            // wake window" — the behavior Android gets for free from a socket
            // that was already open.
            Task { await flushOfflineQueueAndReconnect() }
        } else {
            log(level: "WARN", tag: "TraceManager",
                message: "MQTT not connected and offline tracking is off — location discarded")
        }
    }

    /// Every prerequisite below is logged when missing. These were silent
    /// `guard` bails, which made "MQTT sends nothing" indistinguishable from
    /// "MQTT was never constructed" — the single most common cause being a
    /// host app that called `initialize(apiKey:)` without MQTT credentials,
    /// or an `authenticate` response whose `companies[0]` lacked `group_id`.
    private func connectMqttIfPossible() {
        mqttLock.lock()
        let permitted = isMqttPermitted
        mqttLock.unlock()
        guard permitted else { return }

        guard let user = dataStore.getUser() else {
            logMqttBlocked("user not authenticated — call setOrCreateUser first")
            return
        }
        guard let companyId = user.companyId, !companyId.isEmpty else {
            logMqttBlocked("user has no company_id (check authenticate() response)")
            return
        }
        guard let group = user.group, !group.isEmpty else {
            logMqttBlocked("user has no group_id (check authenticate() response)")
            return
        }
        guard let deviceToken = dataStore.getDeviceToken() else {
            logMqttBlocked("no device token — initialize(apiKey:) was not called")
            return
        }
        guard let mqttUsername = dataStore.getMqttUsername(), !mqttUsername.isEmpty,
              let mqttPassword = dataStore.getMqttPassword(), !mqttPassword.isEmpty else {
            logMqttBlocked("broker credentials missing — call BarikoiTrace.initialize(apiKey:mqttUsername:mqttPassword:)", level: "ERROR")
            return
        }
        let mqttURL = dataStore.getMqttURL() ?? TraceApiRoutes.mqttURL
        // Everything baked into `TraceMqttClient` at construction — the topic
        // is `company/{companyId}/{group}/{userId}/location` and the host/port
        // are `let`s. The old `if mqttClient == nil` never rebuilt, and nothing
        // ever nil'd it, so after `setOrCreateUser` returned a different user
        // (or `setMqttURL`/`setBaseURL`/`resetURLs` ran) the surviving client
        // kept publishing the new user's fixes to the previous user's topic on
        // the previous broker.
        // The password is included (hashed, so it never reaches a log or a
        // debugger description) because it too is baked in at construction —
        // a rotated password with an unchanged username would otherwise keep
        // authenticating with the stale one.
        mqttLock.lock()
        let clientIdPrefix = mqttClientIdPrefix
        mqttLock.unlock()

        let fingerprint = [
            user.userId, companyId, group, deviceToken, mqttURL, mqttUsername,
            String(mqttPassword.hashValue), clientIdPrefix
        ].joined(separator: "|")

        mqttLock.lock()
        // Re-checked inside the hold that actually builds the client. The
        // early check above only avoids the work; this one is the one that
        // matters, because `stopTracking()` can clear the permit during the
        // UserDefaults reads and fingerprint construction in between — and a
        // client built after that point is one nothing will ever tear down.
        guard isMqttPermitted else {
            mqttLock.unlock()
            return
        }
        // Already refused with exactly this identity + credentials. Retrying
        // produces the same CONNACK and nothing else.
        if rejectedFingerprint == fingerprint {
            mqttLock.unlock()
            return
        }
        lastMqttBlockReason = nil
        var retired: TraceMqttClient?
        if mqttClient != nil, mqttClientFingerprint != fingerprint {
            retired = mqttClient
            mqttClient = nil
        }
        if mqttClient == nil {
            let (host, port, useTLS) = TraceManager.parseMqttURL(mqttURL)
            let client = TraceMqttClient(
                host: host, port: port,
                userId: user.userId, companyId: companyId, groupId: group, deviceUUID: deviceToken,
                userName: user.name, mqttUsername: mqttUsername, mqttPassword: mqttPassword,
                // The local, not a fresh read: the fingerprint above was built
                // from it, and a `setMqttClientIdPrefix` landing in between
                // would otherwise record a fingerprint that doesn't describe
                // the client actually built.
                clientIdPrefix: clientIdPrefix,
                useTLS: useTLS
            )
            client.delegate = self
            mqttClient = client
            mqttClientFingerprint = fingerprint
        }
        let client = mqttClient
        let generation = mqttTeardownGeneration
        mqttLock.unlock()

        // Outside the lock — `destroy()` tears down the socket and can invoke
        // delegate callbacks that come back into this class.
        retired?.destroy()

        // Called outside the lock: `connect()` invokes delegate callbacks that
        // come back into this class.
        if client?.isConnectedNow() == false {
            client?.connect()
        }

        // A teardown that landed while the socket was opening wins. Without
        // this, `stopTracking()` could nil `mqttClient` a moment before the
        // line above connected it, leaving a live broker connection that no
        // one holds a reference to and nothing will ever close.
        mqttLock.lock()
        // Identity as well as generation: a concurrent
        // `connectMqttIfPossible()` can retire this client on a fingerprint
        // change without any teardown happening, and the generation alone
        // would not notice.
        let superseded = mqttTeardownGeneration != generation || mqttClient !== client
        if superseded, mqttClient === client {
            mqttClient = nil
            mqttClientFingerprint = nil
        }
        mqttLock.unlock()
        if superseded { client?.destroy() }
    }

    /// Snapshot accessor so callers don't read `mqttClient` unguarded.
    private func currentMqttClient() -> TraceMqttClient? {
        mqttLock.lock()
        defer { mqttLock.unlock() }
        return mqttClient
    }

    /// `connectMqttIfPossible()` runs on every fix, so an unconditional log
    /// would bury the console. Only state *changes* are worth a line.
    private func logMqttBlocked(_ reason: String, level: String = "WARN") {
        // Checked before the de-dup bookkeeping: `log()` drops everything
        // while logging is off, so recording the reason here would mean a host
        // that switches logging on later never sees the first (and only)
        // line for that reason.
        guard dataStore.isLogging() else { return }

        mqttLock.lock()
        let alreadyLogged = lastMqttBlockReason == reason
        if !alreadyLogged { lastMqttBlockReason = reason }
        mqttLock.unlock()

        guard !alreadyLogged else { return }
        log(level: level, tag: "TraceMqtt", message: "No MQTT: \(reason)")
    }

    /// Parses `tcp://host:port` / `ssl://host:port` the way Paho does on the
    /// Android side.
    ///
    /// The scheme used to be parsed and then thrown away, so `setMqttURL`
    /// with an `ssl://` URL opened a *plaintext* socket to the TLS port —
    /// which shows up as a connection that never completes rather than as an
    /// error. Android gets TLS from the scheme automatically; so does this now.
    private static func parseMqttURL(_ url: String) -> (host: String, port: UInt16, useTLS: Bool) {
        guard let components = URLComponents(string: url), let host = components.host else {
            return ("broker.trace.bmapsbd.com", 1883, false)
        }
        let scheme = components.scheme?.lowercased()
        let useTLS = scheme == "ssl" || scheme == "mqtts" || scheme == "tls" || scheme == "wss"
        return (host, UInt16(components.port ?? (useTLS ? 8883 : 1883)), useTLS)
    }

}

extension TraceManager: TraceMqttStatusDelegate {
    public func mqttConnectionStatusChanged(client: TraceMqttClient, state: TraceMqttState, message: String) {
        if state == .rejected {
            // Recorded against the fingerprint that was refused, so the SDK
            // stops re-attempting on every location fix. A credential, user or
            // broker-URL change produces a different fingerprint and clears
            // the block on its own.
            mqttLock.lock()
            // Identity check: these callbacks are asynchronous, so a refusal
            // for a client that has since been retired can land after a
            // *different* one — with different credentials — has been
            // installed. Acting on it would blacklist the new configuration
            // and destroy a healthy connection. That window is exactly the
            // user-switch/credential-rotation case.
            guard client === mqttClient else {
                mqttLock.unlock()
                return
            }
            let fingerprint = mqttClientFingerprint
            let alreadyReported = fingerprint != nil && rejectedFingerprint == fingerprint
            rejectedFingerprint = fingerprint
            // The refused client is also dropped. Leaving it installed meant
            // `performFlush` still found a client, and — since a permanent
            // refusal deliberately schedules no retry — sailed past the
            // `isAwaitingReconnect` short-circuit into a full 12s
            // `waitUntilConnected` under a background assertion, once per fix.
            let refused = mqttClient
            mqttClient = nil
            mqttClientFingerprint = nil
            mqttTeardownGeneration &+= 1
            mqttLock.unlock()

            refused?.destroy()
            if !alreadyReported {
                log(level: "ERROR", tag: "TraceMqtt", message: message)
            }
            return
        }

        log(level: "INFO", tag: "TraceMqtt", message: "\(state): \(message)")
        if state == .connected {
            Task { await flushOfflineQueueAndReconnect() }
        }
    }

    public func mqttMessageDelivered(topic: String) {
        log(level: "DEBUG", tag: "TraceMqtt", message: "Published to \(topic)")
    }

    public func mqttMessageReceived(topic: String, message: String) {
        // `LocTraceForegroundService` branches on a `/command` suffix here.
        // Neither SDK subscribes to anything today, so both branches are
        // unreachable — kept symmetric so the hook is in the same place on
        // both platforms when inbound commands are wired up.
        if topic.hasSuffix("/command") {
            log(level: "INFO", tag: "TraceMqtt", message: "Command received on \(topic): \(message)")
            return
        }
        log(level: "DEBUG", tag: "TraceMqtt", message: "Received on \(topic): \(message)")
    }
}
