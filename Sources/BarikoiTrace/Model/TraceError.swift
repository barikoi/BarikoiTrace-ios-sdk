import Foundation

/// Mirrors `TraceError.kt` — same string codes, same factory names (translated
/// to Swift naming conventions), so error handling reads the same cross-platform.
public struct TraceError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static func noUserError() -> TraceError {
        TraceError(code: "NO_USER", message: "No user found. Create a user first.")
    }

    public static func noKeyError() -> TraceError {
        TraceError(code: "NO_KEY", message: "API key not set. Call initialize() first.")
    }

    public static func noDataError() -> TraceError {
        TraceError(code: "NO_DATA", message: "Required data is missing.")
    }

    public static func networkError() -> TraceError {
        TraceError(code: "NETWORK", message: "No network connection available.")
    }

    public static func locationPermissionError() -> TraceError {
        TraceError(code: "PERMISSION", message: "Location permission not granted.")
    }

    public static func locationNotFoundError() -> TraceError {
        TraceError(code: "LOCATION", message: "Could not determine location.")
    }

    public static func serverError() -> TraceError {
        TraceError(code: "SERVER", message: "Server error occurred.")
    }

    public static func tripStateError() -> TraceError {
        TraceError(code: "TRIP", message: "Not currently on a trip.")
    }

    public static func mockAppError() -> TraceError {
        TraceError(code: "MOCK", message: "Mock location detected. Please disable mock location.")
    }

    public static func jsonError(_ detail: String) -> TraceError {
        TraceError(code: "JSON", message: "JSON parsing error: \(detail)")
    }

    public static func noCompanyError() -> TraceError {
        // iOS-only addition vs. the Kotlin enum: TraceApiClient.kt throws a raw
        // Exception("Company not found") rather than a typed TraceError for this
        // case — giving it a real code here instead of copying that inconsistency.
        TraceError(code: "NO_COMPANY", message: "User is not associated with any company.")
    }
}

extension TraceError: LocalizedError {
    public var errorDescription: String? { message }
}
