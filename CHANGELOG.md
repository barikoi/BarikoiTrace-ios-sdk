## 0.4.0 — 2026-09-03

Version aligned with the Android SDK: both platforms ship `0.4.0`, so a single
number identifies a matched pair of SDKs and a cross-platform wrapper does not
have to track two version lines.

`0.2.0` was cut from this same tree before that decision and stays where it is
— tags are immutable once pushed. Consume `0.4.0`.

Contents (unchanged from the `0.2.0` tag):


* **`TraceConfig`** — one value carrying `apiKey`, the broker credentials, and
  the endpoints (`baseURL`, `mqttURL`, `mqttClientIdPrefix`). New
  `BarikoiTrace.initialize(_ config:)` applies endpoints *before* the manager
  starts, which the old sequence could not: `initialize` resumes a previous
  tracking session and that session builds its MQTT client immediately, so a
  `setMqttURL` afterwards pointed the first client at the wrong broker.
* `initialize(apiKey:mqttUsername:mqttPassword:)` is **deprecated**, forwarding
  to the config overload. No behavior change for existing call sites.
* `TraceConfig.isMqttTransportEncrypted` and `TraceConfig.warnings` — surface
  plaintext broker transport, a non-HTTPS API base URL, and empty credentials
  at `initialize` (logged) or at build time (assert on `warnings`). The shipped
  broker default is still plaintext `tcp://…:1883`.
* `TraceConfigTests` — scheme classification, fail-closed on a malformed URL,
  warning coverage.
* `Examples/BasicUsage` and the README use the config API; `Secrets.example.swift`
  gains `mqttURL`.

## 0.1.0 — 2026-09-02

First tagged release. Consume via SPM:

```swift
.package(url: "https://github.com/barikoi/BarikoiTrace-ios-sdk.git", from: "0.1.0")
```


* Initial scaffold: Swift Package mirroring the Android `barikoitrace` (dev-v3) SDK.
* `TraceMode`, `TraceUser`, `TraceError` — field-for-field parity with the Kotlin models.
* `TraceApiClient` — `/sdk/authenticate` and `/sdk/company/settings`, async/await.
* `TraceLocationEngine` — CLLocationManager wrapper, continuous + one-shot fetch.
* `OfflineLocationStore` — SQLite3-backed durable offline queue (batch-of-100). Survives process death by construction, rather than buffering in memory.
* `TraceMqttClient` — CocoaMQTT wrapper, same topic/LWT/QoS/backoff policy as `MqttManager.kt`.
* `TraceBackgroundCoordinator` — true background tracking trigger stack: CLLocationManager background delivery, significant-location-change monitoring (+ relaunch-after-kill handling), BGTaskScheduler periodic flush (actually scheduled, unlike the Kotlin SDK's dormant `LocTraceDataService`).
* `BarikoiTrace` public facade + `TraceManager` orchestrator.
* Unit tests: `TraceModeTests`, `TraceErrorTests`, `DateTimeUtilsTests`, `OfflineLocationStoreTests`, `TraceDataStoreTests`, `MqttPayloadContractTests`.
* `TraceLocationPayload` — MQTT payload builder extracted out of `TraceManager` for testability; now includes `user_name` on every path (a real gap vs. the Kotlin live-publish path, closed rather than ported) and `TraceMqttClient.lwtTopic` exposed for the same reason.
* `Examples/BasicUsage` — copy-paste SwiftUI integration example (AppDelegate wiring, permissions, auth, tracking, live updates, degraded status).
* Resolved and documented the `setOrCreateUser`/`getSettingsFromRemote` error-swallowing question directly in `TraceManager.swift` (implicit refresh swallows, explicit call throws — deliberate, not inconsistent).
* CI: `.github/workflows/ci.yml` — xcodebuild build/test against an iOS Simulator destination.
* `docs/APP_STORE_READINESS.md` — purpose-string drafts, review-notes guidance, common rejection patterns to check before submitting.
* Builds and unit tests pass against an iOS Simulator destination. On-device
  background-execution matrix (see `docs/WORK_PLAN.md`) is still manual and
  not covered by CI.
