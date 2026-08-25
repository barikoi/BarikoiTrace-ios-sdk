import CoreLocation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Mirrors `SystemSettingsManager.kt` where a direct equivalent exists.
/// Battery-optimization exemption has no iOS analog and is intentionally
/// omitted rather than stubbed — see the work plan for the platform
/// differences this SDK does and doesn't paper over.
public enum SystemSettingsManager {
    public static func checkPermissions() -> Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    public static func hasAlwaysAuthorization() -> Bool {
        CLLocationManager().authorizationStatus == .authorizedAlways
    }

    public static func checkLocationSettings() -> Bool {
        CLLocationManager.locationServicesEnabled()
    }

    public static func isLowPowerModeEnabled() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    public static func isBackgroundRefreshAvailable() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.backgroundRefreshStatus == .available
        #else
        return true
        #endif
    }
}
