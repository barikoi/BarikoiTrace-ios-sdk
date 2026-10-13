import Foundation

/// Decides which trace-mode config the SDK uses when tracking starts.
/// Mirrors Kotlin's `TraceModeSource`.
public enum TraceModeSource: String, Sendable, Codable {
    /// The `TraceMode` passed to startTracking is stored and used.
    case local = "LOCAL"

    /// Company settings fetched from the remote API win; the passed mode is only a fallback.
    case remote = "REMOTE"
}
