/// Mirrors the Kotlin SDK's connection-state shape — and actually emits
/// `.reconnecting` (the Dart package's equivalent enum value was dead code;
/// don't repeat that here).
public enum TraceMqttState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}
