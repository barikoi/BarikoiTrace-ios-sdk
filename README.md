# BarikoiTrace (iOS)

Native iOS library for background location tracing, mirroring the Android
`barikoitrace` (Kotlin, `dev-v3`) SDK's feature set and public API shape.
Distributed as a Swift Package — add it to any iOS app directly, no Flutter/
Dart layer involved.

See [`docs/WORK_PLAN.md`](docs/WORK_PLAN.md) for the full design rationale
(why iOS needs a different background-execution strategy than Android) and
[`docs/STATUS.md`](docs/STATUS.md) for exactly what's implemented vs. still
open.

---

## Installation (Swift Package Manager)

**Xcode:** File → Add Package Dependencies… → enter this repo's URL → select
the `BarikoiTrace` product.

**Package.swift:**
```swift
dependencies: [
    .package(url: "https://github.com/barikoi/BarikoiTrace-ios-sdk.git", from: "0.1.0")
]
```

Versions are git tags on this repo — see [`docs/RELEASING.md`](docs/RELEASING.md).
Below `1.0.0`, SPM treats a minor bump as breaking, so `from: "0.1.0"` will
pick up `0.1.x` but not `0.2.0`.

---

## Required app setup

These are the host app's responsibility — a library can't set its own
capabilities/entitlements.

### 1. `Info.plist`

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs your location to provide location-based features.</string>

<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>This app tracks your location in the background so [specific, real, reviewable feature] keeps working when the app isn't open.</string>

<key>UIBackgroundModes</key>
<array>
  <string>location</string>
  <string>processing</string>
</array>

<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>com.barikoi.trace.offlineflush</string>
</array>
```

The `NSLocationAlwaysAndWhenInUseUsageDescription` copy matters more than it
looks — Apple's App Review guidance for background-location apps expects a
concrete, user-visible reason. Generic copy ("for tracing purposes") is a
common rejection cause. Check current guidance before submitting, this shifts
over time.

### 2. Capabilities (Xcode → Signing & Capabilities)

- **Background Modes**: enable "Location updates" and "Background processing".
- **Push Notifications**: not required by this library.

### 3. `AppDelegate`

```swift
import BarikoiTrace

func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    BarikoiTrace.initialize(
        apiKey: "YOUR_BARIKOI_API_KEY",
        mqttUsername: "YOUR_MQTT_USERNAME",   // from your backend, never hardcoded — see docs/WORK_PLAN.md
        mqttPassword: "YOUR_MQTT_PASSWORD"
    )

    // Required: detects a significant-location-change relaunch after the
    // process was previously killed, and resumes tracking. Without this call,
    // a killed-and-relaunched app will not resume background tracking.
    BarikoiTrace.handleLaunch(options: launchOptions)

    return true
}
```

---

## Usage

```swift
import BarikoiTrace

// 1. Authenticate
let user = try await BarikoiTrace.setOrCreateUser(name: "Jane", email: nil, phone: "+8801700000000")

// 2. Permissions
if !BarikoiTrace.isLocationPermissionsGranted() {
    // request When In Use first via CLLocationManager in your own UI flow,
    // then Always — the two-step order matters, see docs/WORK_PLAN.md §Phase 1
}

// 3. Start tracking
BarikoiTrace.startTracking(.active)                 // preset
BarikoiTrace.startTracking(.active, withTrip: true)  // + local trip UUID

// 4. Live updates (multi-consumer — collect from as many places as needed)
Task {
    for await location in BarikoiTrace.locationUpdates {
        print(location.coordinate)
    }
}

// 5. Stop
BarikoiTrace.stopTracking()

// 6. Degraded-capability check (no Android equivalent)
if BarikoiTrace.isBackgroundTrackingDegraded {
    // show the user a banner: Low Power Mode, revoked Always permission,
    // or Background App Refresh disabled is limiting background delivery
}
```

---

## Example

[`Examples/BasicUsage`](Examples/BasicUsage) — copy-paste-ready SwiftUI
source covering the full common flow: `AppDelegate` wiring (including the
easy-to-forget `handleLaunch(options:)` call), permission requests, sign-in,
start/stop tracking with a trip, live location updates, and the
`isBackgroundTrackingDegraded` signal. Not a runnable `.xcodeproj` — see
that folder's own README for why and how to drop it into a fresh project.

---

## Platform differences from the Android SDK (by design, not oversight)

| Behavior | Android | iOS |
|---|---|---|
| Background execution | Persistent foreground `Service` | Bounded wake windows: location delivery, significant-location-change, `BGProcessingTask` — see `TraceBackgroundCoordinator` |
| Resume after force-kill | `BOOT_COMPLETED` receiver, any reboot | Only via significant-location-change (~500m movement) — a stationary killed app does not silently resume |
| Mock-location detection | `Location.isMock` | No direct equivalent — omitted, not approximated |
| Battery-optimization exemption | Requestable via `SystemSettingsManager` | No iOS equivalent — omitted |
| Degraded-capability signal | Not needed | `BarikoiTrace.isBackgroundTrackingDegraded` — new, iOS-only |

---

## Building & verifying

This package was authored without access to Xcode/the iOS SDK toolchain — it
has **not** been compiled or run yet. Before relying on it:

1. Open in Xcode, resolve packages, build for a real device (background
   execution and `BGTaskScheduler` are not fully testable in the Simulator).
2. Verify the `CocoaMQTT` API calls in `Sources/BarikoiTrace/Mqtt/TraceMqttClient.swift`
   against whatever version `Package.swift` resolves — delegate method names
   and a couple of initializers were written from memory of the 2.x API shape
   and should be checked on first build.
3. Run `swift test` / the Xcode test plan for the unit suite in `Tests/`.
4. Work through the on-device test matrix in `docs/WORK_PLAN.md` (Phase 6)
   before shipping: active movement, stationary for hours, Low Power Mode,
   Background App Refresh disabled, force-kill → relaunch.

---

## License

MIT — see [LICENSE](LICENSE).
