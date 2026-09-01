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
        // Values live in `Secrets.swift`, which is git-ignored — copy
        // `Secrets.example.swift` to create it. Same arrangement as the
        // Android sample's `local.properties` → `BuildConfig.*`. Broker
        // credentials are issued by your backend per app and per environment;
        // see docs/WORK_PLAN.md §2 (Phase 0) for why the Kotlin SDK's
        // hardcoded-constant pattern isn't carried over here.
        BarikoiTrace.initialize(
            apiKey: Secrets.barikoiApiKey,
            mqttUsername: Secrets.mqttUsername,
            mqttPassword: Secrets.mqttPassword
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
