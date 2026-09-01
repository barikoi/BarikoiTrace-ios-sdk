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

    /// Whether Location Services is switched on device-wide.
    ///
    /// `CLLocationManager.locationServicesEnabled()` blocks on a daemon round
    /// trip and logs "This method can cause UI unresponsiveness if invoked on
    /// the main thread" every time it is called from the main queue — which is
    /// where CoreLocation delegates and the SDK's own entry points run. The
    /// answer changes only when the user toggles a Settings switch, so it is
    /// read off the main queue and cached, with the cached value refreshed
    /// from `locationManagerDidChangeAuthorization`.
    public static func checkLocationSettings() -> Bool {
        lock.lock()
        let cached = servicesEnabled
        lock.unlock()

        if cached == nil { refreshLocationServicesState() }
        // Optimistic until the first answer arrives: reporting "off" would
        // make the SDK post its location-disabled notification on launch.
        return cached ?? true
    }

    /// Re-reads the device-wide switch off the main queue and updates the
    /// cache. Cheap, and safe to call from anywhere.
    public static func refreshLocationServicesState(completion: ((Bool) -> Void)? = nil) {
        // Serial, not a concurrent global queue: two rapid authorization
        // changes could otherwise complete out of order and leave both the
        // cache and the caller looking at the older answer — which for the
        // location-disabled notification means posting it after services came
        // back, or taking it down while they are still off.
        refreshQueue.async {
            let enabled = CLLocationManager.locationServicesEnabled()
            lock.lock()
            servicesEnabled = enabled
            lock.unlock()
            completion?(enabled)
        }
    }

    private static let lock = NSLock()
    private static var servicesEnabled: Bool?
    private static let refreshQueue = DispatchQueue(label: "com.barikoi.trace.locationsettings")

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

    /// Opens this app's page in Settings. The closest iOS gets to
    /// `requestLocationSettings(activity)`: Android can deep-link to the
    /// system Location Services toggle, iOS exposes no such URL, so the app's
    /// own settings page — which carries its Location row — is the
    /// destination. Previously `isLocationSettingsOn()` could report false
    /// with nowhere for the host app to send the user.
    @discardableResult
    public static func openAppSettings() -> Bool {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
        #else
        return false
        #endif
    }
}
