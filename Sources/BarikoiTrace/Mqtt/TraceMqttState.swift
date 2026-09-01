/// Mirrors the Kotlin SDK's connection-state shape — and actually emits
/// `.reconnecting` (the Dart package's equivalent enum value was dead code;
/// don't repeat that here).
public enum TraceMqttState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    /// The broker refused the credentials or the client id. Distinct from
    /// `.disconnected` because retrying cannot fix it — something in the host
    /// app's configuration has to change first — so the SDK stops the backoff
    /// ladder here instead of burning ten attempts and a background assertion
    /// on a guaranteed refusal.
    case rejected
}
