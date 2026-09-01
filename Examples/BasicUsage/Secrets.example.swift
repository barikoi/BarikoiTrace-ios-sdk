import Foundation

/// Template. Copy to `Secrets.swift` (which is git-ignored) and fill in the
/// real values:
///
///     cp Examples/BasicUsage/Secrets.example.swift Examples/BasicUsage/Secrets.swift
///
/// The Android SDK does the same thing through `local.properties` →
/// `BuildConfig.API_KEY` / `BuildConfig.MQTT_USERNAME` /
/// `BuildConfig.MQTT_PASSWORD`; this is the iOS equivalent, kept out of the
/// repository for the same reason.
enum Secrets {
    /// Barikoi API key — the one used for `POST /sdk/authenticate`.
    static let barikoiApiKey = "YOUR_BARIKOI_API_KEY"

    /// Broker credentials. Per app and per environment, issued by your
    /// backend. These must match what the MQTT broker's ACL expects — a
    /// mismatch surfaces as `Broker refused the connection (notAuthorized)`.
    static let mqttUsername = "YOUR_MQTT_USERNAME"
    static let mqttPassword = "YOUR_MQTT_PASSWORD"
}
