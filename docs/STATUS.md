# Implementation status

Honest accounting of what exists vs. what's still open, against
`docs/WORK_PLAN.md`'s phases. Written and never compiled — there is no
macOS/Xcode toolchain in the environment this was authored in, so "written"
here means "structurally complete and reviewed by inspection against the
Kotlin source," not "verified to build."

## Done (structurally — needs a build pass to confirm)

- **Phase 0 — Contract**: models, error codes, REST shapes, MQTT topic/payload
  fields defined in `TraceMode`/`TraceUser`/`TraceError`/`TraceApiClient`,
  matched field-for-field against the Kotlin source. `gpx_time` uses one
  consistent format on every path (live publish, offline insert, offline
  flush) — the Kotlin SDK's live-vs-offline format inconsistency is not
  reproduced here.
- **Phase 1 — Scaffold, models, permissions**: `Package.swift`, full model
  layer, `SystemSettingsManager`.
- **Phase 2 — Location engine**: `TraceLocationEngine` (continuous +
  one-shot fetch, background-delivery flags set).
- **Phase 3 — Offline queue**: `OfflineLocationStore` (SQLite3, batch-of-100,
  survives process death by construction — this is the fix for the Flutter
  package's in-memory-buffer gap).
- **Phase 4 — MQTT client**: `TraceMqttClient` (CocoaMQTT wrapper, same
  topic/LWT/QoS as Kotlin, same exponential backoff policy).
- **Phase 5 — Background orchestration**: `TraceBackgroundCoordinator`
  (`CLLocationManager` background delivery + significant-location-change +
  `BGTaskScheduler`, actually scheduled — unlike the Kotlin SDK's unscheduled
  `LocTraceDataService`), `TraceManager` (orchestrator), public `BarikoiTrace`
  facade.
- **Phase 6 (partial) — Unit tests**: `TraceModeTests`, `TraceErrorTests`,
  `DateTimeUtilsTests`, `OfflineLocationStoreTests`.

## Not done — required before this is production-ready

- **Never compiled.** First priority: open in Xcode, resolve `CocoaMQTT`,
  build for a device. Expect small fixes — the CocoaMQTT delegate API in
  particular was written from memory and needs checking against the resolved
  package version.
- **No `TraceDataStoreTests` equivalent.** Keychain-backed storage is harder
  to unit test cleanly (real Keychain access in test targets needs
  entitlements); worth a pass once building.
- **No on-device background-execution testing at all** — active movement,
  stationary-for-hours, Low Power Mode, Background App Refresh disabled,
  force-kill → relaunch-via-significant-location-change. None of this is
  simulator-testable. This is the highest-risk gap: the background trigger
  stack is implemented per the documented design, but "implemented per
  design" and "reliably delivers true background tracking on real devices
  across iOS versions" are different claims, and only the device-test matrix
  in the work plan's Phase 6 can close that gap.
- **No CI** (Phase 8 in the work plan) — nothing gates PRs yet.
- **No App Store readiness pass** (Phase 7) — purpose-string copy, Background
  Modes justification, review-notes demo flow all still need writing and
  should be checked against Apple's *current* guidance, not this document,
  before submission.
- **No consumer example app** — the README's AppDelegate/usage snippets are
  illustrative, not a tested integration.
- **`getSettingsFromRemote`/`setOrCreateUser` best-effort settings refresh
  swallows its own errors into a log line** (mirrors `LocTraceManager.kt`
  intentionally) — worth deciding if that's the right behavior for iOS too,
  or if callers should see it.

## Next concrete step

Open the package in Xcode on a Mac, add it to a throwaway test app, and work
through the build errors — there will be some. That pass will also surface
whether the CocoaMQTT API assumptions above were correct.
