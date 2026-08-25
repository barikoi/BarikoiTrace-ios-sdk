import BarikoiTrace
import UIKit

/// The two calls every host app needs before anything else, in order.
/// See this repo's root README ("Required app setup" → step 3) for the
/// `Info.plist` keys and Background Modes capabilities this assumes are
/// already configured on the app target — this file only covers code.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BarikoiTrace.initialize(
            apiKey: "YOUR_BARIKOI_API_KEY",
            // Issued by your backend per-app/per-environment — never hardcode
            // broker credentials in the shipped binary. See docs/WORK_PLAN.md
            // §2 (Phase 0) for why the Kotlin SDK's hardcoded-constant
            // pattern isn't carried over here.
            mqttUsername: "YOUR_MQTT_USERNAME",
            mqttPassword: "YOUR_MQTT_PASSWORD"
        )

        // Required. Detects a significant-location-change relaunch after the
        // OS previously killed this process, and resumes tracking from the
        // state persisted in TraceDataStore. Skipping this call means a
        // killed-and-relaunched app silently stops tracking — see
        // docs/WORK_PLAN.md §3 ("State restoration on relaunch").
        BarikoiTrace.handleLaunch(options: launchOptions)

        return true
    }
}
