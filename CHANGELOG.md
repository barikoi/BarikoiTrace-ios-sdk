## 0.1.0 (unreleased)

* Initial scaffold: Swift Package mirroring the Android `barikoitrace` (dev-v3) SDK.
* `TraceMode`, `TraceUser`, `TraceError` — field-for-field parity with the Kotlin models.
* `TraceApiClient` — `/sdk/authenticate` and `/sdk/company/settings`, async/await.
* `TraceLocationEngine` — CLLocationManager wrapper, continuous + one-shot fetch.
* `OfflineLocationStore` — SQLite3-backed durable offline queue (batch-of-100), fixes the in-memory-buffer gap found in the Flutter package review.
* `TraceMqttClient` — CocoaMQTT wrapper, same topic/LWT/QoS/backoff policy as `MqttManager.kt`.
* `TraceBackgroundCoordinator` — true background tracking trigger stack: CLLocationManager background delivery, significant-location-change monitoring (+ relaunch-after-kill handling), BGTaskScheduler periodic flush (actually scheduled, unlike the Kotlin SDK's dormant `LocTraceDataService`).
* `BarikoiTrace` public facade + `TraceManager` orchestrator.
* Unit tests: `TraceModeTests`, `TraceErrorTests`, `DateTimeUtilsTests`, `OfflineLocationStoreTests`.
* Not yet compiled/verified — see `docs/STATUS.md`.
