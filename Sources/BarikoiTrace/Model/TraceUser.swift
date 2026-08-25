import Foundation

/// Mirrors `TraceUser.kt`. `companyId`/`group` are required for MQTT topic
/// resolution — `authenticate()` throws before ever producing a `TraceUser`
/// without them (mirrors `TraceApiClient.kt`'s `companies[0]` requirement).
public struct TraceUser: Equatable, Sendable, Codable {
    public let userId: String
    public let name: String?
    public let email: String?
    public let phone: String?
    public let companyId: String?
    public let group: String?
    public let lastLat: Double
    public let lastLon: Double
    /// Epoch milliseconds — matches the Kotlin model's `Long updatedAt`.
    public let updatedAt: Double

    public init(
        userId: String,
        name: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        companyId: String? = nil,
        group: String? = nil,
        lastLat: Double = 0,
        lastLon: Double = 0,
        updatedAt: Double = Date().timeIntervalSince1970 * 1000
    ) {
        self.userId = userId
        self.name = name
        self.email = email
        self.phone = phone
        self.companyId = companyId
        self.group = group
        self.lastLat = lastLat
        self.lastLon = lastLon
        self.updatedAt = updatedAt
    }
}
