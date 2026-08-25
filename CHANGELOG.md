## 0.1.0 (unreleased)

* Initial scaffold: Swift Package mirroring the Android `barikoitrace` (dev-v3) SDK.
* `TraceMode`, `TraceUser`, `TraceError` — field-for-field parity with the Kotlin models.
* `TraceApiClient` — `/sdk/authenticate` and `/sdk/company/settings`, async/await.
* `TraceLocationEngine` — CLLocationManager wrapper, continuous + one-shot fetch.
* `OfflineLocationStore` — SQLite3-backed durable offline queue (batch-of-100), fixes the in-memory-buffer gap found in the Flutter package review.
* `TraceMqttClient` — CocoaMQTT wrapper, same topic/LWT/QoS/backoff policy as `MqttManager.kt`.
* `TraceBackgroundCoordinator` — true background tracking trigger stack: CLLocationManager background delivery, significant-location-change monitoring (+ relaunch-after-kill handling), BGTaskScheduler periodic flush (actually scheduled, unlike the Kotlin SDK's dormant `LocTraceDataService`).
* `BarikoiTrace` public facade + `TraceManager` orchestrator.
* Unit tests: `TraceModeTests`, `TraceErrorTests`, `DateTimeUtilsTests`, `OfflineLocationStoreTests`, `TraceDataStoreTests`, `MqttPayloadContractTests`.
* `TraceLocationPayload` — MQTT payload builder extracted out of `TraceManager` for testability; now includes `user_name` on every path (a real gap vs. the Kotlin live-publish path, closed rather than ported) and `TraceMqttClient.lwtTopic` exposed for the same reason.
* `Examples/BasicUsage` — copy-paste SwiftUI integration example (AppDelegate wiring, permissions, auth, tracking, live updates, degraded status).
* Resolved and documented the `setOrCreateUser`/`getSettingsFromRemote` error-swallowing question directly in `TraceManager.swift` (implicit refresh swallows, explicit call throws — deliberate, not inconsistent).
* CI: `.github/workflows/ci.yml` — xcodebuild build/test against an iOS Simulator destination.
* `docs/APP_STORE_READINESS.md` — purpose-string drafts, review-notes guidance, common rejection patterns to check before submitting.
* Not yet compiled/verified — see `docs/STATUS.md`.
