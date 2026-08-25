# BasicUsage example

Not a runnable Xcode project — this repo was authored without access to an
Xcode/macOS toolchain (see the root `README.md`'s "Building & verifying"
section), and hand-forging a `.xcodeproj`/`project.pbxproj` without being
able to open or build it would risk shipping something that looks real but
doesn't actually work. Instead, this is copy-paste-ready source for wiring
`BarikoiTrace` into a real iOS app, verified by inspection against the
library's actual public API (`Sources/BarikoiTrace/BarikoiTrace.swift`), not
executed.

## Set up

1. Xcode → File → New → Project → iOS → App. SwiftUI interface, Swift
   language. Uncheck "Use Core Data".
2. File → Add Package Dependencies… → this repo's URL → add `BarikoiTrace`.
3. Copy `AppDelegate.swift` and `ContentView.swift` from this folder into
   the new project, replacing its generated `ContentView.swift` and
   `<YourApp>App.swift` content (see `BasicUsageApp.swift` here for the
   `@main` entry point wiring the two together).
4. Add the `Info.plist` keys and Background Modes capabilities from the
   root `README.md`'s "Required app setup" section — this example doesn't
   duplicate that list.
5. Replace the placeholder API key / MQTT credentials in `AppDelegate.swift`
   with real ones from your backend.

## What this example exercises

`AppDelegate.swift` — the two calls every host app needs at launch:
`BarikoiTrace.initialize(...)` and, just as important and easy to forget,
`BarikoiTrace.handleLaunch(options:)` — without the second call, an app
relaunched by iOS via significant-location-change after being killed will
not resume tracking (see `docs/WORK_PLAN.md` §3).

`ContentView.swift` — the full common flow: authenticate a user, request
permission, start/stop tracking with an optional trip, subscribe to the
live `AsyncStream<CLLocation>`, and surface `isBackgroundTrackingDegraded`
(an iOS-only concept — Android's SDK doesn't need it, see the root
README's platform-differences table) as user-visible state rather than
letting background delivery silently under-perform with no signal.
