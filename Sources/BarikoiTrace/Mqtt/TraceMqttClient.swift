import Foundation
import CocoaMQTT

public protocol TraceMqttStatusDelegate: AnyObject {
    func mqttConnectionStatusChanged(state: TraceMqttState, message: String)
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

    public weak var delegate: TraceMqttStatusDelegate?
    public let topic: String

    private var mqtt: CocoaMQTT?
    private var isConnected = false
    private var isConnecting = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private let baseReconnectDelay: TimeInterval = 5
    private let maxReconnectDelay: TimeInterval = 60

    public init(
        host: String,
        port: UInt16 = 1883,
        userId: String,
        companyId: String,
        groupId: String,
        deviceUUID: String,
        userName: String? = nil,
        mqttUsername: String,
        mqttPassword: String
    ) {
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
    }

    public func connect() {
        guard !isConnecting else { return }

        let clientId = "iOSClient-\(userId)-\(deviceUUID)"
        let client = mqtt ?? CocoaMQTT(clientID: clientId, host: serverHost, port: serverPort)
        mqtt = client

        if client.connState == .connected {
            isConnected = true
            delegate?.mqttConnectionStatusChanged(state: .connected, message: "already connected")
            return
        }

        client.username = mqttUsername
        client.password = mqttPassword
        client.keepAlive = 60
        client.cleanSession = false
        client.autoReconnect = false // backoff is owned explicitly below, matching MqttManager.kt
        client.willMessage = CocoaMQTTMessage(
            topic: "device/\(userId)/status", string: "offline", qos: .qos1, retained: true
        )
        client.delegate = self

        isConnecting = true
        delegate?.mqttConnectionStatusChanged(state: .connecting, message: "Connecting...")
        _ = client.connect()
    }

    public func publish(json: String) {
        guard let mqtt, isConnected else { return }
        mqtt.publish(topic, withString: json, qos: .qos1)
    }

    public func isConnectedNow() -> Bool { isConnected && mqtt?.connState == .connected }

    public func disconnect() {
        mqtt?.disconnect()
        isConnected = false
    }

    public func destroy() {
        reconnectAttempts = 0
        isConnecting = false
        mqtt?.delegate = nil
        mqtt?.disconnect()
        mqtt = nil
        isConnected = false
    }

    private func scheduleReconnect() {
        guard !isConnecting else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            reconnectAttempts = 0
            return
        }
        let delay = min(baseReconnectDelay * pow(2, Double(reconnectAttempts)), maxReconnectDelay)
        reconnectAttempts += 1
        delegate?.mqttConnectionStatusChanged(state: .reconnecting, message: "retry in \(delay)s (attempt \(reconnectAttempts))")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isConnected else { return }
            self.connect()
        }
    }
}

extension TraceMqttClient: CocoaMQTTDelegate {
    public func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        isConnecting = false
        if ack == .accept {
            isConnected = true
            reconnectAttempts = 0
            delegate?.mqttConnectionStatusChanged(state: .connected, message: "Connected")
        } else {
            isConnected = false
            delegate?.mqttConnectionStatusChanged(state: .disconnected, message: "Connect refused: \(ack)")
            scheduleReconnect()
        }
    }

    public func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        isConnected = false
        isConnecting = false
        delegate?.mqttConnectionStatusChanged(
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
