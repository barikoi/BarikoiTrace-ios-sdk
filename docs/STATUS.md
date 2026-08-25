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
- **Phase 6 — Unit tests**: `TraceModeTests`, `TraceErrorTests`,
  `DateTimeUtilsTests`, `OfflineLocationStoreTests`, `TraceDataStoreTests`
  (isolated Keychain/UserDefaults suite name, cleans up in `tearDown`).
- **Phase 7 — App Store readiness draft**: `docs/APP_STORE_READINESS.md` —
  purpose-string templates, review-notes guidance, common rejection patterns.
  Still a draft to adapt with the host app's real feature copy, and still
  needs checking against Apple's guidance at submission time, not this
  commit's date.
- **Phase 8 — CI**: `.github/workflows/ci.yml` — `xcodebuild build`/`test`
  against an iOS Simulator destination on every push/PR (plain macOS `swift
  test` doesn't work here since `BackgroundTasks` isn't available outside
  iOS/iPadOS/tvOS/watchOS). Not yet run for real — the workflow itself is
  unverified for the same reason everything else is (no toolchain in the
  authoring environment). First actual run on GitHub will be the first real
  build signal for this whole package.

## Not done — required before this is production-ready

- **Never compiled, including this CI workflow.** First priority: push to
  GitHub (or open locally in Xcode) and let the Actions run / build locally.
  Expect small fixes — the CocoaMQTT delegate API in particular was written
  from memory and needs checking against the resolved package version, and
  the CI workflow's exact xcodebuild invocation (scheme name resolution for
  a bare SPM package, simulator name/OS availability on the `macos-15`
  runner image) is a first-guess, not a verified-working config.
  Package **resolution** is no longer a guess, though: `Package.resolved`
  and `.swiftpm/xcode/...` artifacts showing up in this repo confirm the
  package was opened in Xcode and SPM resolved it cleanly —
  `CocoaMQTT 2.4.0` + its transitive deps (`MqttCocoaAsyncSocket 1.0.8`,
  `Starscream 4.0.8`). That only proves the dependency graph and
  `Package.swift` are valid, not that the source compiles — the delegate
  API surface in `TraceMqttClient.swift` still needs a real build to
  confirm.
- **No on-device background-execution testing at all** — active movement,
  stationary-for-hours, Low Power Mode, Background App Refresh disabled,
  force-kill → relaunch-via-significant-location-change. None of this is
  simulator-testable, so CI passing does **not** mean true background
  tracking works — it only means the code compiles and the logic unit tests
  pass. This is still the highest-risk open item: only the device-test
  matrix in the work plan's Phase 6 can confirm the actual thing this
  library exists to do.
- **No consumer example app** — the README's AppDelegate/usage snippets and
  `docs/APP_STORE_READINESS.md`'s review-notes guidance both assume a real
  app to point at; neither has been exercised end-to-end.
- **`getSettingsFromRemote`/`setOrCreateUser` best-effort settings refresh
  swallows its own errors into a log line** (mirrors `LocTraceManager.kt`
  intentionally) — worth deciding if that's the right behavior for iOS too,
  or if callers should see it.

## Next concrete step

Push this to GitHub (or open locally in Xcode) and see what the CI workflow
/ a local build actually says. That's the first real signal on whether the
CocoaMQTT API assumptions and the xcodebuild CI invocation were correct.
