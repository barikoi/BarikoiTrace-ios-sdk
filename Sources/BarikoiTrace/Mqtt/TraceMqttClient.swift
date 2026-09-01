import Foundation
import CocoaMQTT

public protocol TraceMqttStatusDelegate: AnyObject {
    /// - Parameter client: the client reporting the change. Callbacks are
    ///   delivered asynchronously, so a status can arrive after its client
    ///   has been retired and replaced; the delegate needs the identity to
    ///   tell whose news this is.
    func mqttConnectionStatusChanged(client: TraceMqttClient, state: TraceMqttState, message: String)
    func mqttMessageDelivered(topic: String)
    func mqttMessageReceived(topic: String, message: String)
}

/// Mirrors `MqttManager.kt`: same topic pattern, same LWT, same exponential
/// backoff policy (5s base, doubling, capped at 60s, bounded attempt count).
///
/// Behavioral difference from the Kotlin client, deliberate: this class does
/// **not** assume it should hold a connection open indefinitely. In the
/// background-execution model (`TraceBackgroundCoordinator`), each wake window
/// connects, publishes/flushes, and disconnects — a persistent socket is not
/// reliable in iOS background execution the way it is under Android's
/// foreground service. `connect()`/`disconnect()` are cheap and idempotent by
/// design so both usage patterns (held-open while foregrounded, or
/// connect-per-window while backgrounded) work through the same API.
///
/// NOTE: verify the exact CocoaMQTT API surface (delegate method names,
/// `CocoaMQTTMessage` initializer, `connState`) against whatever version
/// Package.swift resolves — this was written against the 2.x API shape from
/// memory and should be checked on first build.
public final class TraceMqttClient {
    private let serverHost: String
    private let serverPort: UInt16
    private let userId: String
    private let companyId: String
    private let groupId: String
    private let deviceUUID: String
    private let userName: String?
    private let mqttUsername: String
    private let mqttPassword: String
    private let clientIdPrefix: String
    /// Set from the broker URL's scheme (`ssl://`, `mqtts://`), matching how
    /// Paho decides on the Android side.
    private let useTLS: Bool

    /// Client id is `"\(prefix)\(userId)-\(deviceUUID)"`, matching
    /// `MqttManager.kt`'s `"AndroidClient-$userId-$uuid"` in shape.
    ///
    /// Configurable because brokers commonly gate authorization on a client-id
    /// pattern as well as on username/password: an ACL written when only the
    /// Android SDK existed may allow `AndroidClient-*` and refuse anything
    /// else, which surfaces as `notAuthorized` on a CONNECT whose credentials
    /// are perfectly correct. Set it to `"AndroidClient-"` to test that, and
    /// prefer widening the ACL over disguising the platform.
    public static let defaultClientIdPrefix = "iOSClient-"

    public weak var delegate: TraceMqttStatusDelegate?
    public let topic: String
    /// Last-will-and-testament topic — mirrors `MqttManager.kt`'s
    /// `device/{deviceId}/status`. Exposed (rather than inlined only in
    /// `connect()`) so the contract test can assert it against the Kotlin
    /// pattern from the same source `connect()` actually uses.
    public let lwtTopic: String

    private var mqtt: CocoaMQTT?
    private var isConnected = false
    private var isConnecting = false
    private var reconnectAttempts = 0
    /// Bumped on every connect attempt so a watchdog armed for an earlier
    /// attempt can tell it is stale and do nothing.
    private var connectGeneration: UInt64 = 0
    /// A backoff retry is already queued on `stateQueue`; suppresses the
    /// per-location-fix connect attempts that would otherwise race it. At most
    /// one retry is ever queued.
    private var isReconnectScheduled = false
    /// Bumped only by `disconnect()`/`destroy()`. A pending retry compares
    /// this — not `connectGeneration`, which every attempt bumps — so it can
    /// distinguish "the caller tore this client down" from "another attempt
    /// happened in the meantime".
    private var teardownGeneration: UInt64 = 0
    /// Identifies the pending retry, so a timer that has been superseded
    /// retracts nothing.
    private var reconnectScheduleId: UInt64 = 0
    private let maxReconnectAttempts = 10
    private let baseReconnectDelay: TimeInterval = 5
    private let maxReconnectDelay: TimeInterval = 60
    private let connectTimeout: TimeInterval = 15

    /// Connect/publish can be driven from a background `Task`
    /// (`TraceManager.flushOfflineQueueAndReconnect`) while CocoaMQTT's
    /// delegate callbacks arrive on its own `delegateQueue`, so the
    /// connection-state flags need a lock rather than bare reads.
    private let lock = NSLock()
    /// Reconnect/watchdog timers used to hop through `DispatchQueue.main`,
    /// which is the worst place for them in a background wake window.
    private let stateQueue = DispatchQueue(label: "com.barikoi.trace.mqtt.state")

    public init(
        host: String,
        port: UInt16 = 1883,
        userId: String,
        companyId: String,
        groupId: String,
        deviceUUID: String,
        userName: String? = nil,
        mqttUsername: String,
        mqttPassword: String,
        clientIdPrefix: String = TraceMqttClient.defaultClientIdPrefix,
        useTLS: Bool = false
    ) {
        self.clientIdPrefix = clientIdPrefix
        self.useTLS = useTLS
        self.serverHost = host
        self.serverPort = port
        self.userId = userId
        self.companyId = companyId
        self.groupId = groupId
        self.deviceUUID = deviceUUID
        self.userName = userName
        self.mqttUsername = mqttUsername
        self.mqttPassword = mqttPassword
        self.topic = "company/\(companyId)/\(groupId)/\(userId)/location"
        self.lwtTopic = "device/\(userId)/status"
    }

    public func connect() { connect(expectedTeardown: nil) }

    /// - Parameter expectedTeardown: the `teardownGeneration` the caller
    ///   observed. A queued retry passes the value it captured, so a
    ///   `disconnect()`/`destroy()` that lands between the timer's check and
    ///   this call is caught here rather than reopening a socket the caller
    ///   believes is closed. `nil` means "caller-initiated, no expectation".
    private func connect(expectedTeardown: UInt64?) {
        lock.lock()

        if let expectedTeardown, teardownGeneration != expectedTeardown {
            lock.unlock()
            return
        }

        // `isConnecting` used to be a one-way latch: it was set right before
        // `client.connect()` and only ever cleared by a delegate callback, so
        // a connect attempt that never produced one (socket refused
        // synchronously, or TCP up but no CONNACK) wedged this client shut for
        // the rest of the process — every later `connect()` returned here and
        // nothing was ever published again. It is now cleared on every exit
        // path below and by `armConnectWatchdog`.
        guard !isConnecting else {
            lock.unlock()
            return
        }
        // `TraceManager.persistOrPublish` calls in here on *every* location
        // fix. Without this second guard, each fix would fire a fresh attempt
        // in parallel with the pending backoff and burn through
        // `maxReconnectAttempts` in seconds instead of over ~7 minutes.
        guard !isReconnectScheduled else {
            lock.unlock()
            return
        }

        if let existing = mqtt, existing.connState == .connected {
            isConnected = true
            reconnectAttempts = 0
            lock.unlock()
            delegate?.mqttConnectionStatusChanged(client: self, state: .connected, message: "already connected")
            return
        }

        // Claim the attempt before building anything, so a concurrent caller
        // hits the `isConnecting` guard above.
        isConnecting = true
        // Must be cleared here too: `publish()` gates on this flag alone, and
        // the old client is about to be replaced by an unconnected one.
        isConnected = false
        connectGeneration &+= 1
        let generation = connectGeneration
        let stale = mqtt
        // Dropped now, not when the replacement is ready: while `mqtt` still
        // pointed at the retired client, a callback that beat the
        // `delegate = nil` below passed `isCurrent(_:)` and could set
        // `isConnected = true` for a client already being torn down.
        mqtt = nil
        lock.unlock()

        // A *fresh* CocoaMQTT per attempt, deliberately. Reusing one instance
        // means a late `mqttDidDisconnect` belonging to attempt N lands during
        // attempt N+1 and clobbers its state; with one instance per attempt,
        // `isCurrent(_:)` below can reject stale callbacks by identity. The
        // broker-side session is keyed on `clientID`, which is unchanged, so
        // `cleanSession = false` still resumes the same session.
        stale?.delegate = nil
        stale?.disconnect()

        let clientId = "\(clientIdPrefix)\(userId)-\(deviceUUID)"
        let client = CocoaMQTT(clientID: clientId, host: serverHost, port: serverPort)
        client.enableSSL = useTLS
        client.username = mqttUsername
        client.password = mqttPassword
        client.keepAlive = 60
        // `MqttManager.kt` hands Paho an explicit `MqttDefaultFilePersistence`
        // so unacked QoS 1 publishes survive process death. CocoaMQTT does the
        // same thing implicitly whenever `cleanSession` is false: it persists
        // in-flight frames through `CocoaMQTTStorage` (keyed on the client id,
        // which is stable here) and replays them from `didConnectAck`. Setting
        // this flag *is* the port — there is no separate persistence object to
        // install, and turning clean sessions on would silently discard the
        // queue.
        client.cleanSession = false
        client.autoReconnect = false // backoff is owned explicitly below, matching MqttManager.kt
        client.willMessage = CocoaMQTTMessage(
            topic: lwtTopic, string: "offline", qos: .qos1, retained: true
        )
        // Default is `DispatchQueue.main`; keep connection bookkeeping and the
        // offline-queue flush it triggers off the main queue, which may not be
        // drained promptly in a background wake window.
        client.delegateQueue = stateQueue
        client.delegate = self

        delegate?.mqttConnectionStatusChanged(client: self, state: .connecting, message: "Connecting...")

        // Publishing `mqtt` and opening the socket happen under one lock hold.
        // Splitting them left a window where a concurrent `destroy()` nil'd
        // `mqtt` and *then* this method opened a socket on a client nobody
        // referenced any more: an orphan kept alive for the rest of the
        // process by its own reader and keepAlive timer. CocoaMQTT dispatches
        // every delegate callback asynchronously onto `delegateQueue`, so
        // `connect(timeout:)` cannot re-enter this lock.
        lock.lock()
        // `destroy()`/`disconnect()` may have run while the lock was released
        // for construction above.
        guard connectGeneration == generation else {
            // `isConnecting` is deliberately left alone: this attempt no longer
            // owns it. Whoever bumped the generation (a teardown, or a newer
            // attempt started after that teardown cleared the flag) owns the
            // flag now, and clearing it here would release their claim.
            lock.unlock()
            client.delegate = nil
            return // never connected — nothing to tear down
        }
        mqtt = client
        // The Bool matters: CocoaMQTT returns false when the socket never even
        // started (bad host, no route), and in that case no delegate method
        // fires at all.
        let started = client.connect(timeout: connectTimeout)
        if !started {
            isConnecting = false
            mqtt = nil
        }
        lock.unlock()

        guard started else {
            client.delegate = nil
            delegate?.mqttConnectionStatusChanged(client: self, state: .disconnected, message: "socket connect did not start")
            scheduleReconnect()
            return
        }

        armConnectWatchdog(generation: generation)
    }

    /// Covers the other half of the wedge: TCP connected but CONNACK never
    /// arrived, so neither `didConnectAck` nor `mqttDidDisconnect` fires.
    /// Without this the client stays `isConnecting == true` indefinitely.
    private func armConnectWatchdog(generation: UInt64) {
        stateQueue.asyncAfter(deadline: .now() + connectTimeout + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stuck = self.isConnecting && self.connectGeneration == generation
            var client: CocoaMQTT?
            if stuck {
                self.isConnecting = false
                self.isConnected = false
                // Retire the attempt outright: bump the generation and drop
                // the instance, so a CONNACK that shows up after the deadline
                // fails `isCurrent(_:)` instead of marking a client this
                // watchdog already declared dead as connected.
                self.connectGeneration &+= 1
                client = self.mqtt
                client?.delegate = nil
                self.mqtt = nil
            }
            self.lock.unlock()

            guard stuck else { return }
            client?.disconnect()
            self.delegate?.mqttConnectionStatusChanged(client: self, state: .disconnected, message: "connect timed out (no CONNACK)")
            self.scheduleReconnect()
        }
    }

    /// True only for callbacks from the CocoaMQTT instance of the *current*
    /// attempt. After `destroy()` (which nils `mqtt`) this is always false, so
    /// a queued callback can no longer resurrect the client.
    private func isCurrent(_ candidate: CocoaMQTT) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mqtt === candidate
    }

    public func publish(json: String) {
        lock.lock()
        let client = mqtt
        let connected = isConnected
        lock.unlock()
        guard let client, connected else { return }
        client.publish(topic, withString: json, qos: .qos1)
    }

    /// True while a backoff retry is queued, i.e. the broker has already
    /// refused or dropped this client recently. Callers use it to skip a wait
    /// that is certain to time out.
    public var isAwaitingReconnect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReconnectScheduled
    }

    /// Waits for the connection to come up, up to `timeout`.
    ///
    /// Callers used to check `isConnectedNow()` immediately after `connect()`
    /// and, finding it false — as it always is, a CONNACK being a round trip
    /// away — give up and leave the work for later. On iOS "later" means the
    /// next background wake, which repeats the same failure. Waiting inside the
    /// wake window (under a `BackgroundActivity` assertion) is what lets a
    /// publish actually happen while backgrounded.
    ///
    /// Polled rather than continuation-based on purpose: the connection state
    /// is driven by delegate callbacks on the client's own queue, and a
    /// continuation resolved from there would need to be reconciled with the
    /// reconnect/watchdog paths that already manage that state. A 100 ms poll
    /// over a few seconds costs nothing next to the socket work it is waiting
    /// on, and it is cancellation-aware for free.
    public func waitUntilConnected(timeout: TimeInterval) async -> Bool {
        if isConnectedNow() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if isConnectedNow() { return true }
        }
        return isConnectedNow()
    }

    public func isConnectedNow() -> Bool {
        lock.lock()
        let connected = isConnected
        let state = mqtt?.connState
        lock.unlock()
        return connected && state == .connected
    }

    public func disconnect() {
        lock.lock()
        let client = mqtt
        isConnected = false
        isConnecting = false
        // Invalidates the in-flight watchdog *and* any pending reconnect —
        // both compare generations before acting, so an explicit disconnect
        // is no longer undone by a timer scheduled seconds earlier.
        connectGeneration &+= 1
        teardownGeneration &+= 1
        isReconnectScheduled = false
        // Detached the same way `destroy()` does. Leaving the delegate
        // installed meant the resulting `mqttDidDisconnect` was treated as an
        // unexpected drop and scheduled a reconnect — an explicit disconnect
        // that quietly reconnected itself ~5s later.
        client?.delegate = nil
        mqtt = nil
        lock.unlock()
        client?.disconnect()
    }

    public func destroy() {
        lock.lock()
        let client = mqtt
        reconnectAttempts = 0
        isConnecting = false
        isConnected = false
        connectGeneration &+= 1
        teardownGeneration &+= 1
        isReconnectScheduled = false
        // Cleared before `mqtt` is nil'd: `isCurrent(_:)` then rejects any
        // callback already queued on the delegate queue, so `destroy()` is
        // permanent rather than something a stale callback can undo by
        // scheduling a reconnect.
        client?.delegate = nil
        mqtt = nil
        lock.unlock()
        client?.disconnect()
    }

    private func scheduleReconnect() {
        lock.lock()
        guard !isConnecting else {
            lock.unlock()
            return
        }
        // At most one pending retry at a time. This is what lets the timer
        // block below clear `isReconnectScheduled` unconditionally — an
        // earlier version cleared it only when the generation still matched,
        // and since the watchdog and the CONNACK-refused path both bump the
        // generation *after* scheduling, the flag stuck `true` and wedged
        // `connect()` shut for the life of the object.
        guard !isReconnectScheduled else {
            lock.unlock()
            return
        }

        // Exhausting the ladder does not mean giving up — it means settling at
        // the ceiling. Returning without a queued retry (the original
        // behavior) handed reconnection back to the per-fix `connect()` calls,
        // i.e. a ~20s hot loop with no backoff at all; resetting the counter
        // to zero (the first attempt at this) restarted the ladder, so an
        // unreachable broker got a fresh 5s retry every ~7 minutes forever.
        // Clamping pins the delay at `maxReconnectDelay` instead.
        if reconnectAttempts >= maxReconnectAttempts { reconnectAttempts = maxReconnectAttempts - 1 }
        let delay = min(baseReconnectDelay * pow(2, Double(reconnectAttempts)), maxReconnectDelay)
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        let deliberateTeardown = teardownGeneration
        isReconnectScheduled = true
        reconnectScheduleId &+= 1
        let scheduleId = reconnectScheduleId
        lock.unlock()

        delegate?.mqttConnectionStatusChanged(client: self, state: .reconnecting, message: "retry in \(delay)s (attempt \(attempt))")

        stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // Only retract *this* schedule's claim: `disconnect()` clears the
            // flag mid-flight, after which a newer `scheduleReconnect()` can
            // set it again — clearing unconditionally would release that newer
            // claim and allow two pending retries.
            if self.reconnectScheduleId == scheduleId { self.isReconnectScheduled = false }
            // Tracked separately from `connectGeneration`, which every attempt
            // bumps: only `disconnect()`/`destroy()` move this one, so the
            // check means "was the client deliberately torn down", not merely
            // "did another attempt happen".
            let skip = self.teardownGeneration != deliberateTeardown
                || self.isConnected
                || self.isConnecting
            self.lock.unlock()

            guard !skip else { return }
            // Re-verified inside `connect()`'s own lock hold: the check above
            // released the lock before this call, and a teardown landing in
            // that window would otherwise reopen the connection.
            self.connect(expectedTeardown: deliberateTeardown)
        }
    }
}

extension TraceMqttClient: CocoaMQTTDelegate {
    public func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard isCurrent(mqtt) else { return }
        lock.lock()
        isConnecting = false
        connectGeneration &+= 1 // CONNACK landed — stand the watchdog down
        let accepted = ack == .accept
        isConnected = accepted
        if accepted { reconnectAttempts = 0 }
        lock.unlock()

        if accepted {
            delegate?.mqttConnectionStatusChanged(client: self, state: .connected, message: "Connected")
        } else if TraceMqttClient.isPermanentRefusal(ack) {
            // No backoff. These three CONNACK codes mean the broker examined
            // what we sent and rejected it; the same CONNECT packet will be
            // rejected every time. Retrying ten times only delays the one
            // message the integrator actually needs to see.
            delegate?.mqttConnectionStatusChanged(
                client: self,
                state: .rejected,
                message: "Broker refused the connection (\(ack)) — check the mqttUsername/mqttPassword passed to BarikoiTrace.initialize"
            )
        } else {
            delegate?.mqttConnectionStatusChanged(client: self, state: .disconnected, message: "Connect refused: \(ack)")
            scheduleReconnect()
        }
    }

    /// CONNACK codes that no amount of retrying will change.
    private static func isPermanentRefusal(_ ack: CocoaMQTTConnAck) -> Bool {
        switch ack {
        case .notAuthorized, .badUsernameOrPassword, .identifierRejected: return true
        default: return false
        }
    }

    public func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        // Identity-gated: a disconnect belonging to a superseded attempt (or
        // one arriving after `destroy()`) must not clear `isConnecting` for
        // the attempt currently in flight.
        guard isCurrent(mqtt) else { return }
        lock.lock()
        isConnected = false
        isConnecting = false
        connectGeneration &+= 1
        lock.unlock()

        delegate?.mqttConnectionStatusChanged(
            client: self,
            state: .disconnected,
            message: "Disconnected: \(err?.localizedDescription ?? "clean")"
        )
        if err != nil { scheduleReconnect() }
    }

    public func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}

    public func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        delegate?.mqttMessageDelivered(topic: topic)
    }

    public func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        delegate?.mqttMessageReceived(topic: message.topic, message: message.string ?? "")
    }

    public func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    public func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    public func mqttDidPing(_ mqtt: CocoaMQTT) {}
    public func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}
