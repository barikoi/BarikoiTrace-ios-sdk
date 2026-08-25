import Foundation

/// Mirrors `ApiRoutes.kt`. Keep these two in sync manually until the contract
/// lives in one shared schema (see the work plan's Phase 0).
public enum TraceApiRoutes {
    public static let baseURL = "https://api.trace.bmapsbd.com/api/v1/"
    public static let mqttURL = "tcp://broker.trace.bmapsbd.com:1883"

    public static let authenticate = "sdk/authenticate"
    public static let companySettings = "sdk/company/settings"
}
