# App Store readiness — draft, review before submitting

Drafts to work from, not final copy — check against Apple's *current* App
Review guidance before submitting (their bar for background-location apps
has tightened over time and this document will drift out of date). This
covers the work plan's Phase 7.

## Purpose-string copy (`Info.plist`)

The generic version ("this app tracks your location in the background")
correlates with rejections. Reviewers want to see a concrete, user-visible
reason the tracking has to keep running when the app isn't open. Replace the
bracketed part with the host app's actual feature — don't ship the bracket.

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>[App name] uses your location to [specific in-app feature, e.g. "show nearby drivers on the map"].</string>

<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>[App name] continues tracking your location in the background so [specific, ongoing, user-visible reason — e.g. "your delivery partner can see your live location until the trip ends" / "your team can track the vehicle's route while the app is closed"]. Background tracking stops when [the trip ends / you sign out / you turn it off in Settings].</string>
```

The last sentence matters: reviewers specifically look for the tracking
having a bounded, user-controllable lifecycle, not "runs forever with no
stated end."

## Background Modes justification (review notes)

When submitting, the App Review notes field should state, in plain language:

- What background location is used for (one sentence, matching the purpose string).
- How a reviewer can see it working — a test account/flow that visibly demonstrates the feature without requiring them to physically move the test device (e.g. a demo mode, a pre-seeded trip, or a web dashboard showing the location updating).
- That `processing` (BGProcessingTask) is used only to flush a local offline queue and reconnect to the telemetry backend — not to run arbitrary background work.

## Common rejection patterns to check against before submitting

- Purpose string doesn't match what the app actually does, or is vague enough that a reviewer can't tell what feature depends on it.
- No way for the reviewer to observe the background-location feature without owning two devices or driving around — provide a demo path.
- Background modes declared but one of them (`processing`, `fetch`, etc.) isn't actually used for anything a reviewer can identify — remove modes you're not using.
- `Always` requested immediately on first launch rather than after the user has engaged with the feature that needs it (Apple's HIG asks for "just in time" requests) — request `WhenInUse` first, then `Always` only once the user starts the flow that needs background tracking (e.g. tapping "Start Trip").

## Budget for the process, not just the code

- 1–2 rejection/resubmission cycles is common for background-location apps, even with good-faith compliant submissions — communicate this as a scheduling risk to whoever owns the release date, before the first submission, not after the first rejection.
- Keep the demo account/flow from the review notes working and current for every subsequent submission — a stale demo path is its own rejection reason.
