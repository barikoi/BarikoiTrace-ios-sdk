import Foundation

/// Everything the SDK needs to start, in one value.
///
/// Replaces the old `initialize(apiKey:mqttUsername:mqttPassword:)` plus a
/// scatter of `setBaseURL`/`setMqttURL`/`setMqttClientIdPrefix` calls that had
/// to happen in the right order relative to it — an ordering the type system
/// did nothing to enforce, and which silently produced a client pointed at the
/// wrong broker when a host app got it wrong.
///
/// ```swift
/// BarikoiTrace.initialize(
///     TraceConfig(
///         apiKey: "…",
///         mqttUsername: "…",
///         mqttPassword: "…"
///     )
/// )
/// ```
///
/// Self-hosted or staging deployments override the endpoints:
///
/// ```swift
/// var config = TraceConfig(apiKey: "…", mqttUsername: "…", mqttPassword: "…")
/// config.baseURL = "https://api.staging.example.com/api/v1/"
/// config.mqttURL = "ssl://broker.staging.example.com:8883"
/// config.mqttClientIdPrefix = "fleet-ios-"
/// BarikoiTrace.initialize(config)
/// ```
public struct TraceConfig: Sendable {

    // MARK: - Required

    /// Barikoi API key, from the Barikoi dashboard. Used for
    /// `POST /sdk/authenticate` and `GET /sdk/company/settings`.
    public var apiKey: String

    /// MQTT broker username. Issued per company, separately from `apiKey` —
    /// it is not derivable from it. Must match the broker ACL, or CONNECT is
    /// refused with `notAuthorized`.
    public var mqttUsername: String

    /// MQTT broker password. Treat as a server secret: fetch it at runtime
    /// rather than compiling it in. See the README's credentials section.
    public var mqttPassword: String

    // MARK: - Endpoints (defaulted)

    /// REST base URL. Trailing slash is normalized for you.
    public var baseURL: String = TraceApiRoutes.baseURL

    /// Broker URL, `scheme://host[:port]`.
    ///
    /// Recognized schemes: `tcp`, `mqtt`, `ws` (plaintext) and `ssl`, `mqtts`,
    /// `tls`, `wss` (TLS). Port defaults to 1883 plaintext / 8883 TLS when the
    /// URL omits it.
    ///
    /// The SDK default is **plaintext** — every fix and both broker
    /// credentials cross the network unencrypted. Point this at a TLS
    /// endpoint for anything carrying real user locations.
    public var mqttURL: String = TraceApiRoutes.mqttURL

    /// Client-id prefix. Full client id is
    /// `{prefix}{userId}-{deviceUUID}` (Android uses `AndroidClient-`).
    /// Only worth changing when the broker ACL authorizes by client-id
    /// pattern — the symptom is `notAuthorized` on a CONNECT whose username
    /// and password are correct.
    public var mqttClientIdPrefix: String = TraceMqttClient.defaultClientIdPrefix

    // MARK: - Init

    public init(
        apiKey: String,
        mqttUsername: String,
        mqttPassword: String,
        baseURL: String = TraceApiRoutes.baseURL,
        mqttURL: String = TraceApiRoutes.mqttURL,
        mqttClientIdPrefix: String = TraceMqttClient.defaultClientIdPrefix
    ) {
        self.apiKey = apiKey
        self.mqttUsername = mqttUsername
        self.mqttPassword = mqttPassword
        self.baseURL = baseURL
        self.mqttURL = mqttURL
        self.mqttClientIdPrefix = mqttClientIdPrefix
    }

    // MARK: - Introspection

    /// Whether `mqttURL` names a TLS scheme. Surfaced so a host app can
    /// assert on it in a release build rather than discovering plaintext
    /// transport in production.
    public var isMqttTransportEncrypted: Bool {
        guard let scheme = URLComponents(string: mqttURL)?.scheme?.lowercased() else { return false }
        return ["ssl", "mqtts", "tls", "wss"].contains(scheme)
    }

    /// Non-fatal configuration problems, in the order they should be fixed.
    /// The SDK logs these at `initialize`; check them yourself if you want to
    /// fail a release build instead.
    public var warnings: [String] {
        var found: [String] = []
        if apiKey.isEmpty { found.append("apiKey is empty — /sdk/authenticate will fail with NO_KEY.") }
        if mqttUsername.isEmpty || mqttPassword.isEmpty {
            found.append("MQTT credentials are empty — the broker will refuse CONNECT with notAuthorized.")
        }
        if !isMqttTransportEncrypted {
            found.append("mqttURL '\(mqttURL)' is plaintext — credentials and location data are sent unencrypted. Use ssl:// (port 8883).")
        }
        if !baseURL.hasPrefix("https://") {
            found.append("baseURL '\(baseURL)' is not HTTPS.")
        }
        return found
    }
}
