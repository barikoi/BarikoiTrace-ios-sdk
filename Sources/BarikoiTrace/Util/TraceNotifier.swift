import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local-notification sink for conditions the user has to fix themselves.
///
/// Ports `LocTraceForegroundService.showLocationDisabledNotification()` — its
/// notification id 2, posted when the location provider goes away and
/// cancelled when it comes back. iOS had only a log line for that, so a user
/// who switched Location Services off silently stopped being tracked with
/// nothing to tell them.
///
/// Differences from the Android original, both forced by the platform:
///   - Android's foreground-service notification means it already holds
///     notification permission; here the SDK has to ask, so the first post
///     triggers an authorization request. A denial is respected silently and
///     never re-prompts — that is the OS's rule, not a policy choice.
///   - There is no equivalent of `setContentIntent(launchIntent)`; tapping an
///     iOS local notification always opens the app.
public enum TraceNotifier {

    /// Set `false` to suppress these notifications entirely (and with them the
    /// authorization prompt). Defaults to `true`, matching Android, where the
    /// notification is unconditional.
    public static var isEnabled = true

    /// Matches Android's notification id 2 — one slot, replaced rather than
    /// stacked, and removable when the condition clears.
    private static let locationDisabledId = "com.barikoi.trace.location-disabled"

    public static func showLocationDisabled() {
        #if canImport(UserNotifications)
        guard isEnabled else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    post(center)
                }
            case .denied:
                return // the user's answer; do not nag
            default:
                post(center)
            }
        }
        #endif
    }

    public static func clearLocationDisabled() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [locationDisabledId])
        center.removePendingNotificationRequests(withIdentifiers: [locationDisabledId])
        #endif
    }

    #if canImport(UserNotifications)
    private static func post(_ center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Location is off"
        content.body = "Need to turn on location service" // same copy as the Kotlin SDK
        content.sound = .default
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }

        // No trigger — delivered immediately, the way `notify()` posts at once.
        let request = UNNotificationRequest(
            identifier: locationDisabledId, content: content, trigger: nil
        )
        center.add(request)
    }
    #endif
}
