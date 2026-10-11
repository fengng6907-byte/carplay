# Build status and phase gate

Updated: 2026-10-11

## Status

| Area | Status | Evidence |
|---|---|---|
| Phase 1 audit | Complete | `AUDIT.md` |
| Xcode project and app/test targets | Generated, not Xcode-verified | `OmniCast.xcodeproj` |
| SwiftUI entry and scene manifest | Implemented, not runtime-verified | `OmniCastApp.swift`, `Info.plist` |
| Unified playback reducer | Implemented and statically reviewed | `PlaybackStateModel.swift` |
| AVPlayer/WebKit coordination | Implemented, not device-tested | `PlayerManager.swift`, `CarWebViewController.swift` |
| MIME-aware routing | Implemented with unit tests, tests not executed | `MediaSourceResolver.swift`, `OmniCastTests` |
| macOS CI | Configured, not executed in this directory | `.github/workflows/ios.yml` |
| Phases 4–7 | Blocked by build gate | A successful Apple-SDK build/test run is required first. |

## Checks actually performed

- Audited all baseline source and documentation files.
- Confirmed every custom type referenced by the baseline is defined.
- Added explicit source/resource membership for the app and test targets.
- Checked that every 24-character project-object reference has a matching definition.
- Parsed `Info.plist`, `PrivacyInfo.xcprivacy`, and the shared scheme as XML.
- Parsed all asset catalog `Contents.json` files as JSON.
- Checked Swift source brace balance and stale publisher/call-site references.

These checks are not a substitute for Swift compilation.

## Required gate

Before Phase 4 implementation, run the workflow or the README `xcodebuild` commands and
record:

1. Xcode and Swift versions.
2. Simulator OS and destination.
3. Full compiler diagnostics, if any.
4. Unit-test count and failures.
5. The commit SHA that was tested.

Do not mark the foundation green until both the app build and unit-test action succeed.

## Known blockers and follow-up work

- This environment is Windows and has no `xcodebuild`, iOS SDK, CarPlay Simulator, code
  signing identities, provisioning profiles, or physical iPhone/head unit.
- The bundle identifier `com.example.OmniCast` is a placeholder.
- An App Store-quality app icon is not yet supplied.
- CarPlay audio/video and multicast capabilities require approval and provisioning.
- The Phase 4 tabbed phone experience, library persistence, and mini-player are not yet
  implemented.
- Phase 5 must decouple the receiver from CarPlay, default LAN exposure off, add
  authenticated proprietary APIs, redirect/private-address policy, rate limits, and
  malformed-request tests.
- Phase 6 iOS 27 video metadata/capability code requires the iOS 27 SDK and approved video
  entitlement.
- Phase 7 archive, signing, TestFlight, CarPlay Simulator, physical network, and vehicle
  tests remain pending.

