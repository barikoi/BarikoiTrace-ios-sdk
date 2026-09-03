# Releasing

Distribution is **SPM from the public GitHub repo**. A release is a git tag —
there is no registry, no review queue, nothing to submit. Consumers resolve
`https://github.com/barikoi/BarikoiTrace-ios-sdk.git` directly.

## Rules

- **Tags are immutable.** Once pushed, someone's `Package.resolved` may pin
  it. Never move or delete a tag; ship `0.1.1` instead.
- **SemVer.** Below `1.0.0`, SPM treats *minor* bumps as breaking (`from:
  "0.1.0"` will not auto-adopt `0.2.0`). So: bugfix → patch, anything else →
  minor, until the API is committed at `1.0.0`.
- **No `v` prefix.** Tags are `0.1.0`, not `v0.1.0` — matches what
  `README.md` and the release workflow's tag filter expect. Stay consistent.
- **Pre-releases** (`0.4.1-rc.1`) are ignored by `from:`/`upTo` rules unless
  the consumer opts in explicitly. Use them for internal trials.
- **Version in lockstep with Android.** Both SDKs ship the same number, so
  `0.4.0` here and `com.github.barikoi:barikoitrace:0.4.0` there are a matched
  pair. Cut them together, or the pairing stops meaning anything. A
  platform-specific fix still bumps both — a gap in one series is cheaper than
  two numbering schemes to reason about.

## Checklist

1. `master` is green in CI and matches what you intend to ship.
2. `CHANGELOG.md` — the top section is the version being cut, dated, no
   "unreleased".
3. `docs/STATUS.md` — reflects reality, not aspiration.
4. `README.md` install snippet references a version `<=` the one being cut.
5. No secrets tracked:
   ```bash
   git ls-files | grep -iE 'secret|\.env|\.p12|\.mobileprovision'
   # Secrets.example.swift is the only expected hit
   ```
6. Tag and push:
   ```bash
   git tag -a 0.1.0 -m "0.1.0"
   git push origin master
   git push origin 0.1.0
   ```
7. `.github/workflows/release.yml` then rebuilds the tagged commit, does a
   fresh-checkout consumer resolve, and drafts the GitHub Release. If verify
   fails, the release is not created — fix forward on a new patch tag.

## Verifying as a consumer

```bash
mkdir /tmp/probe && cd /tmp/probe
swift package init
# add the dependency to Package.swift, then:
swift package resolve
```
Or in Xcode: File → Add Package Dependencies… → paste the repo URL → confirm
the version picker offers the new tag (may need "Reset Package Caches").

## Not doing

- **CocoaPods** — only if a customer on a legacy project demands it. Second
  manifest to keep in sync; CocoaPods is in maintenance mode.
- **Binary XCFramework** — `CocoaMQTT` is a source dependency, so a
  `binaryTarget` needs a wrapper target to carry it, plus
  `BUILD_LIBRARY_FOR_DISTRIBUTION` and a rebuild on every Swift ABI shift.
  Only worth it if IP concerns force closed source.
