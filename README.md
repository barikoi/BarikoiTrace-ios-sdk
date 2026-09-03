# BarikoiTrace (iOS)

Native iOS SDK for background location tracing. Authenticates a user against
the Barikoi Trace backend, streams their location to an MQTT broker while the
app runs — foreground *or* background — and queues fixes to disk when the
network is gone, flushing them when it returns.

Distributed as a Swift Package. Mirrors the Android `barikoitrace` (Kotlin,
`dev-v3`) SDK's feature set and public API shape, so call sites read the same
on both platforms.

- **Requirements:** iOS 15+, Swift 5.9+, Xcode 16
- **Dependency:** [CocoaMQTT](https://github.com/emqx/CocoaMQTT) 2.1.6+ (resolved automatically)
- **License:** MIT

---

## Table of contents

- [Installation](#installation)
- [How it works](#how-it-works)
- [Required app setup](#required-app-setup)
- [Where to put your API key](#where-to-put-your-api-key)
- [Quick start](#quick-start)
- [API reference](#api-reference)
- [Tracking modes](#tracking-modes)
- [Offline behavior](#offline-behavior)
- [MQTT contract](#mqtt-contract)
- [Error handling](#error-handling)
- [Background execution — read this before shipping](#background-execution--read-this-before-shipping)
- [Platform differences from the Android SDK](#platform-differences-from-the-android-sdk)
- [Example app](#example-app)
- [Building and testing](#building-and-testing)
- [Releasing](#releasing)

---

## Installation

Versions are git tags on this repository — there is no registry step.

**Xcode:** File → Add Package Dependencies… → paste
`https://github.com/barikoi/BarikoiTrace-ios-sdk.git` → Dependency Rule "Up to
Next Minor" → select the `BarikoiTrace` product.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/barikoi/BarikoiTrace-ios-sdk.git", from: "0.4.0")
]
```

Then add the product to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [.product(name: "BarikoiTrace", package: "BarikoiTrace-ios-sdk")]
)
```

Below `1.0.0`, SPM treats a **minor** bump as breaking: `from: "0.4.0"` picks up
`0.4.x` but not `0.5.0`. See [`docs/RELEASING.md`](docs/RELEASING.md).

The iOS and Android SDKs are released **in lockstep on the same version
number** — `0.4.0` here pairs with `com.github.barikoi:barikoitrace:0.4.0` on
[Android](https://github.com/barikoi/BarikoiTrace-android-sdk). One number
identifies a matched pair, which is what makes a shared Flutter/React Native
wrapper tractable.

---

## How it works

```
CLLocationManager ──▶ TraceLocationEngine ──▶ TraceManager ──┬──▶ TraceMqttClient ──▶ broker
                                                             │
                                                             └──▶ OfflineLocationStore (SQLite)
                                                                        │  network back
                                                                        └──▶ flush, batch of 100
```

| Component | Responsibility |
|---|---|
| `TraceApiClient` | `POST /sdk/authenticate`, `GET /sdk/company/settings`. async/await. |
| `TraceLocationEngine` | `CLLocationManager` wrapper — continuous updates and one-shot fetch. Applies the accuracy filter. |
| `TraceMqttClient` | CocoaMQTT wrapper. Topic resolution, LWT, QoS 1, exponential-backoff reconnect. |
| `OfflineLocationStore` | SQLite-backed durable queue. Survives process death — not an in-memory buffer. |
| `TraceBackgroundCoordinator` | The background wake stack: background location delivery, significant-location-change monitoring (including relaunch-after-kill), `BGTaskScheduler` periodic flush. |
| `TraceManager` | Orchestrator. Auth state, mode, trip state, routing a fix to MQTT or to disk. |
| `BarikoiTrace` | The public facade. The only type you import against. |

Credentials live in the Keychain (`KeychainStore`); non-secret state in
`UserDefaults` (`TraceDataStore`).

---

## Required app setup

A library cannot grant its own entitlements. These four steps are the host
app's job, and tracking will silently underperform without them.

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
looks. App Review expects a concrete, user-visible reason for background
location; generic copy ("for tracing purposes") is a common rejection cause.
See [`docs/APP_STORE_READINESS.md`](docs/APP_STORE_READINESS.md), and check
Apple's current guidance at submission time — it shifts.

### 2. Capabilities (Xcode → Signing & Capabilities → Background Modes)

Enable **Location updates** and **Background processing**. Push Notifications
is not required.

### 3. `AppDelegate`

```swift
import BarikoiTrace

func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    BarikoiTrace.initialize(
        TraceConfig(
            apiKey: Secrets.barikoiApiKey,
            mqttUsername: Secrets.mqttUsername,
            mqttPassword: Secrets.mqttPassword
        )
    )

    // Required. Detects a significant-location-change relaunch after the
    // process was killed and resumes tracking. Omit this and a killed app
    // never comes back.
    BarikoiTrace.handleLaunch(options: launchOptions)

    return true
}
```

Using SwiftUI without an `AppDelegate`? Attach one with
`@UIApplicationDelegateAdaptor` — `launchOptions` is not reachable any other
way, and the relaunch path depends on it.

### 4. Credentials

See [Where to put your API key](#where-to-put-your-api-key) — it is the
question every integrator hits first, so it has its own section.

---

## Where to put your API key

The SDK reads no config file, no `Info.plist` key and no environment
variable. You hand it a `TraceConfig`, and that is the entire contract:

```swift
BarikoiTrace.initialize(
    TraceConfig(
        apiKey: "…",          // Barikoi dashboard
        mqttUsername: "…",    // issued separately, per company
        mqttPassword: "…"
    )
)
```

Endpoints default to production and are overridable for staging or a
self-hosted deployment:

```swift
var config = TraceConfig(apiKey: "…", mqttUsername: "…", mqttPassword: "…")
config.baseURL            = "https://api.staging.example.com/api/v1/"
config.mqttURL            = "ssl://broker.staging.example.com:8883"
config.mqttClientIdPrefix = "fleet-ios-"     // only if the broker ACL matches on client id

assert(config.warnings.isEmpty, "\(config.warnings)")   // plaintext broker, non-HTTPS API, empty key…
BarikoiTrace.initialize(config)
```

Configure through `TraceConfig` rather than calling `setBaseURL`/`setMqttURL`
after `initialize`. `initialize` resumes tracking if the previous process was
tracking, and a resumed session builds its MQTT client immediately — endpoints
set afterwards arrive too late for that first client.

| Field | Default | |
|---|---|---|
| `apiKey` | — | required |
| `mqttUsername` / `mqttPassword` | — | required |
| `baseURL` | `https://api.trace.bmapsbd.com/api/v1/` | trailing slash normalized |
| `mqttURL` | `tcp://broker.trace.bmapsbd.com:1883` | **plaintext** — see below |
| `mqttClientIdPrefix` | `iOSClient-` | Android uses `AndroidClient-` |

`mqttURL` accepts `tcp`/`mqtt`/`ws` (plaintext) and `ssl`/`mqtts`/`tls`/`wss`
(TLS); port defaults to 1883 or 8883 by scheme. `config.isMqttTransportEncrypted`
tells you which you got — the SDK default is plaintext, meaning both broker
credentials and every location fix travel unencrypted. Point it at a TLS
listener for anything carrying real user locations.

Where the credential *values* come from is your app's decision. Three options,
in increasing order of safety.

### Option A — git-ignored Swift file (local development)

Fastest, and what [`Examples/BasicUsage`](Examples/BasicUsage) uses.

```sh
cp Examples/BasicUsage/Secrets.example.swift Examples/BasicUsage/Secrets.swift
# fill in the real values
```

```swift
enum Secrets {
    static let barikoiApiKey = "…"
    static let mqttUsername  = "…"
    static let mqttPassword  = "…"
}
```

`Secrets.swift` and `*.xcconfig` are already in this repo's `.gitignore`. Add
the same two lines to yours. Development only — the values are still compiled
into the binary.

### Option B — xcconfig → Info.plist → runtime (per-environment builds)

Keeps the values out of source control and lets Debug/Staging/Release differ
without a code change.

```
// Config/Debug.xcconfig — git-ignored
BARIKOI_API_KEY = your_key_here
```

```xml
<!-- Info.plist -->
<key>BarikoiAPIKey</key>
<string>$(BARIKOI_API_KEY)</string>
```

```swift
guard let key = Bundle.main.object(forInfoDictionaryKey: "BarikoiAPIKey") as? String else {
    fatalError("BarikoiAPIKey missing — check the xcconfig is assigned to this configuration")
}
BarikoiTrace.initialize(TraceConfig(apiKey: key, mqttUsername: u, mqttPassword: p))
```

**This still ships the value inside the app bundle.** Anyone can unzip an
`.ipa` and read `Info.plist`. Acceptable for the Barikoi API key, which is
scoped and rotatable. **Not** acceptable for the MQTT password.

### Option C — issued by your own backend (production)

Your app authenticates its user against *your* service; your service returns
the broker credentials; you pass them to `initialize`. Nothing sensitive ships
in the binary, and revoking a customer is a server-side change rather than a
forced app update.

```swift
let creds = try await MyBackend.fetchTraceCredentials()   // your API, your auth
BarikoiTrace.initialize(
    TraceConfig(
        apiKey: creds.barikoiApiKey,
        mqttUsername: creds.mqttUsername,
        mqttPassword: creds.mqttPassword,
        mqttURL: creds.brokerURL          // server decides the broker too
    )
)
```

### If you are integrating this SDK as a third party

Your Barikoi API key comes from the Barikoi dashboard. The **MQTT username and
password are issued to you separately** — they are per-company broker
credentials, not derivable from the API key, and they must match what the
broker's ACL expects. A mismatch surfaces as
`Broker refused the connection (notAuthorized)` rather than as an auth error.

Treat the broker password as a server secret: fetch it at runtime (Option C),
do not commit it, and do not ship it in a public app if you can avoid it.

### Rules regardless of option

- Never commit real credentials. `git log` keeps them forever, and a public
  repo means immediate compromise — rotate rather than rewrite history.
- Never reuse one broker account across customers.
- The MQTT client id defaults to `iOSClient-{userId}-{deviceUUID}`. If the
  broker ACL authorizes by client-id pattern, set the prefix with
  `setMqttClientIdPrefix(_:)` *before* `startTracking`.

---

## Quick start

```swift
import BarikoiTrace
import CoreLocation

// 1. Permissions — When In Use first, then Always. iOS refuses Always
//    unless When In Use was granted, so the order is not optional.
if !BarikoiTrace.isLocationPermissionsGranted() {
    BarikoiTrace.requestLocationPermissions()
}
if !BarikoiTrace.hasBackgroundPermission() {
    BarikoiTrace.requestBackgroundLocationPermission()
}

// 2. Authenticate. Returns the user, and pulls the company's remote
//    TraceMode settings as a best-effort side effect.
let user = try await BarikoiTrace.setOrCreateUser(
    name: "Jane",
    email: nil,
    phone: "+8801700000000"
)

// 3. Track
BarikoiTrace.startTracking(.active)                  // preset
BarikoiTrace.startTracking(.active, withTrip: true)  // + a local trip UUID

// 4. Consume live updates. Multi-consumer — collect from as many
//    places as you need.
Task {
    for await location in BarikoiTrace.locationUpdates {
        print(location.coordinate)
    }
}

// 5. Warn the user when iOS is throttling you
if BarikoiTrace.isBackgroundTrackingDegraded {
    // Low Power Mode, Always downgraded to When In Use, or Background
    // App Refresh off. Show a banner — background delivery is unreliable.
}

// 6. Stop
BarikoiTrace.stopTracking()
```

---

## API reference

Everything public is a static member of the `BarikoiTrace` enum.

### Lifecycle

| Method | Notes |
|---|---|
| `initialize(_ config: TraceConfig)` | Call once, first, before anything else. |
| `initialize(apiKey:mqttUsername:mqttPassword:)` | **Deprecated** — cannot carry the broker URL. Forwards to the above. |
| `handleLaunch(options:)` | Call from `didFinishLaunchingWithOptions`, after `initialize`. Required for relaunch-after-kill. |
| `setLogListener(_:)` | Conform to `TraceLogListener` to pipe SDK logs into your own debug console. |

### Endpoints

Set these through `TraceConfig` at `initialize`. The setters below exist for
changing endpoints mid-session — switching a running app between staging and
production, say — and re-point the MQTT client on the next fix.

| Method | Notes |
|---|---|
| `setBaseURL(_:)` | |
| `setMqttURL(_:)` | |
| `setMqttClientIdPrefix(_:)` | Call before `startTracking`. |
| `resetURLs()` | Back to the SDK defaults. |

### User

| Method | Notes |
|---|---|
| `setOrCreateUser(name:email:phone:) async throws -> TraceUser` | Authenticates or creates. Throws `TraceError`. Also refreshes remote settings — that refresh swallows its own failure by design (a secondary step should not fail the primary auth call). |
| `getUser() -> TraceUser?` | Cached user, no network. |
| `getUserId() -> String?` | |

`TraceUser` carries `userId`, `name`, `email`, `phone`, `companyId`, `group`,
`lastLat`, `lastLon`, `updatedAt` (epoch ms). `companyId` and `group` are
required — MQTT topic resolution needs them, so authentication throws
`noCompanyError()` rather than returning a user that cannot publish.

### Permissions

| Method | Notes |
|---|---|
| `isLocationPermissionsGranted() -> Bool` | |
| `isLocationSettingsOn() -> Bool` | Device-level Location Services. |
| `hasBackgroundPermission() -> Bool` | Specifically `Always`. |
| `requestLocationPermissions()` | Prompts for When In Use. |
| `requestBackgroundLocationPermission()` | Prompts for Always. When In Use must already be granted. |
| `openAppSettings() -> Bool` | iOS exposes no deep link to the Location Services toggle, so this opens the app's own settings page, which carries its Location row. |

### Tracking

| Method | Notes |
|---|---|
| `startTracking(_ mode: TraceMode, withTrip: Bool = false)` | `withTrip` attaches a locally generated trip UUID. |
| `stopTracking()` | If a trip was open, publishes the completed-trip payload. |
| `setTraceMode(_:)` | Applies live if already tracking. |
| `refreshTracking()` | Re-applies the stored mode. Only needed if the mode changed through some path other than `setTraceMode`. |
| `isLocationTracking() -> Bool` | |
| `setOfflineTracking(_:)` | Toggles the SQLite queue. |
| `setBroadcastingEnabled(_:)` | Gates `locationUpdates`. |
| `setLoggingEnabled(_:)` | |
| `setLocationDisabledNotificationEnabled(_:)` | On by default; posts a local notification when Location Services go off, and the first post triggers the notification-authorization prompt. Set `false` **before** `startTracking` to suppress both. |

### Trips

`isOnTrip() -> Bool`, `getTripId() -> String?`. Trip IDs are generated on
device, not issued by the server.

### Location and sync

| Method | Notes |
|---|---|
| `updateCurrentLocation() async throws -> CLLocation` | One-shot fix. |
| `uploadOfflineData()` | Forces a flush of the queue. |
| `getSettingsFromRemote() async throws -> TraceMode` | Explicit fetch — unlike the implicit refresh inside `setOrCreateUser`, this **throws** on failure. |
| `locationUpdates: AsyncStream<CLLocation>` | Multi-consumer live stream. Requires `setBroadcastingEnabled(true)`. |
| `isBackgroundTrackingDegraded: Bool` | See below. |

---

## Tracking modes

`TraceMode` is a value type with three presets, numerically identical to the
Kotlin SDK's:

| Preset | Accuracy | Interval | Distance filter | Accuracy filter | Ping sync |
|---|---|---|---|---|---|
| `.active` | high | 5s | — | 50m | — |
| `.reactive` | high | — | 100m | 100m | 30s |
| `.passive` | medium | — | 100m | 300m | 120s |

`updateInterval` and `distanceFilter` are mutually exclusive: whichever is
non-zero decides whether tracking is time-based or movement-based.
`accuracyFilter` rejects any fix with worse horizontal accuracy than the given
metres.

Custom modes go through the builder, which enforces the same floors as
Android (interval ≥ 5s, distance ≥ 10m, accuracy ≥ 20m):

```swift
let mode = TraceMode.Builder()
    .setDesiredAccuracy(.high)
    .setDistanceFilter(50)      // metres
    .setAccuracyFilter(30)
    .setPingSyncInterval(60)
    .setOfflineSync(true)
    .setStartTime(DateComponents(hour: 8))   // daily tracking window
    .setEndTime(DateComponents(hour: 20))
    .build()

BarikoiTrace.startTracking(mode)
```

`startTime`/`endTime` define a daily window; outside it, tracking stays idle.
Defaults to the full day.

---

## Offline behavior

When the network is unavailable — or the MQTT connection is down — fixes go to
a SQLite table rather than a memory buffer, so they survive the app being
killed or the device rebooting. On reconnect they flush in batches of 100,
oldest first, and are deleted only after the broker acknowledges them (QoS 1).

Disable with `setOfflineTracking(false)` or `TraceMode.Builder().setOfflineSync(false)`.
Force a flush with `uploadOfflineData()`. A `BGProcessingTask` registered under
`com.barikoi.trace.offlineflush` also flushes periodically when iOS grants the
window — which is why that identifier must be in your `Info.plist`.

---

## MQTT contract

**Location topic:** `company/{companyId}/{groupId}/{userId}/location`
**LWT topic:** `device/{userId}/status`, retained, payload `offline`
**Client ID:** `{prefix}{userId}-{deviceUUID}` — QoS 1 throughout.

Payload:

```json
{
  "latitude": 23.8103,
  "longitude": 90.4125,
  "altitude": 4.0,
  "speed": 1.4,
  "bearing": 275.0,
  "accuracy": 12.0,
  "gpx_time": "2026-09-02 11:04:38",
  "user_id": "…",
  "company_id": "…",
  "user_name": "Jane",
  "trip_id": "…",
  "trip_status": "active"
}
```

`trip_id`/`trip_status` appear only while on a trip; stopping publishes a final
full payload with `trip_status: "completed"`. `gpx_time` uses one UTC string
format on every path — live publish, offline insert and offline flush alike.
Negative `speed`/`bearing` (what Core Location reports when it has no value)
are clamped to zero. The shape is locked down by
`Tests/BarikoiTraceTests/MqttPayloadContractTests.swift`; change the payload
and that test fails first.

---

## Error handling

Async methods throw `TraceError`, a struct with a stable string `code` and a
`message`. It conforms to `LocalizedError`, so `error.localizedDescription`
works.

```swift
do {
    let user = try await BarikoiTrace.setOrCreateUser(name: "Jane", email: nil, phone: phone)
} catch let error as TraceError {
    switch error.code {
    case "NO_KEY":      // initialize() was never called
    case "NO_COMPANY":  // user has no company — cannot resolve an MQTT topic
    case "NETWORK":     // no connectivity
    case "PERMISSION":  // location permission not granted
    case "SERVER":      // backend 5xx
    default: break
    }
}
```

Codes: `NO_USER`, `NO_KEY`, `NO_DATA`, `NETWORK`, `PERMISSION`, `LOCATION`,
`SERVER`, `TRIP`, `MOCK`, `JSON`, `NO_COMPANY`. Same codes as the Kotlin SDK,
plus `NO_COMPANY` (Kotlin throws a raw exception there).

---

## Background execution — read this before shipping

iOS gives no persistent background service. This SDK stacks the three
mechanisms that exist:

1. **Background location delivery** — `allowsBackgroundLocationUpdates`, active
   while the app is backgrounded and `Always` is granted.
2. **Significant-location-change monitoring** — survives app termination and
   relaunches the process on roughly 500m of movement. This is the only path
   back from a force-kill, and it needs `handleLaunch(options:)`.
3. **`BGProcessingTask`** — periodic offline-queue flush, scheduled at the
   system's discretion. Not a timer; iOS decides when.

Consequences to design around, and to tell your users about:

- A **stationary, force-killed** app does not resume. Nothing on iOS can make it.
- **Low Power Mode** suspends background refresh outright.
- `Always` can be **silently downgraded** to When In Use by the user at any time.
- `BGTaskScheduler` may not fire for hours.

`BarikoiTrace.isBackgroundTrackingDegraded` reports whether any of these is
currently in effect. Surface it — a fleet operator who thinks tracking is
running when it is not is worse off than one who is told it stopped.

---

## Platform differences from the Android SDK

By design, not oversight.

| Behavior | Android | iOS |
|---|---|---|
| Background execution | Persistent foreground `Service` | Bounded wake windows — see above |
| Resume after force-kill | `BOOT_COMPLETED` receiver, any reboot | Significant-location-change only (~500m); a stationary killed app stays dead |
| Mock-location detection | `Location.isMock` | No equivalent — omitted, not approximated |
| Battery-optimization exemption | Requestable | No equivalent — omitted |
| Autostart / OEM process-kill workarounds | Six vendor-specific methods | Not applicable |
| Degraded-capability signal | Not needed | `isBackgroundTrackingDegraded` — iOS-only addition |
| Async style | `suspend` + a callback API for Java interop | `async`/`await` only |
| MQTT credentials | Hardcoded broker constants | Passed into `initialize` |

---

## Example app

[`Examples/BasicUsage`](Examples/BasicUsage) — SwiftUI source covering the full
flow: `AppDelegate` wiring (including the easy-to-forget `handleLaunch`),
permission requests in the correct order, sign-in, start/stop with a trip, live
updates, and the degraded-capability banner. Generated with XcodeGen from
`project.yml`; see that folder's README.

---

## Building and testing

`CoreLocation` and `BackgroundTasks` are unavailable to a plain `swift build`,
so build against an iOS destination:

```bash
xcodebuild build -scheme BarikoiTrace \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'

xcodebuild test -scheme BarikoiTrace \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

CI runs both on every push and PR (`.github/workflows/ci.yml`).

**The Simulator cannot validate background execution.** Before shipping a host
app, work through the on-device matrix in `docs/WORK_PLAN.md` (Phase 6) on real
hardware: sustained movement, stationary for hours, Low Power Mode on,
Background App Refresh off, force-kill then move 500m.

---

## Releasing

Tag-based SPM distribution. Full rules and checklist in
[`docs/RELEASING.md`](docs/RELEASING.md); short version:

```bash
git tag -a 0.4.0 -m "0.4.0" && git push origin 0.4.0
```

`.github/workflows/release.yml` then rebuilds and tests the tagged commit,
resolves it from a throwaway consumer package, and drafts the GitHub Release.
Tags are immutable to consumers — never move one, ship a patch instead.

---

## Further reading

- [`docs/WORK_PLAN.md`](docs/WORK_PLAN.md) — design rationale, phase by phase
- [`docs/STATUS.md`](docs/STATUS.md) — what is implemented vs. still open
- [`docs/APP_STORE_READINESS.md`](docs/APP_STORE_READINESS.md) — purpose strings, review notes, rejection patterns
- [`CHANGELOG.md`](CHANGELOG.md)
