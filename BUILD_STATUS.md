# Build status and remaining blockers

Updated: 2026-10-12

## Verified status

| Area | Status | Evidence |
|---|---|---|
| Phase 1 repository audit | Complete | `AUDIT.md` |
| Phase 2 app/project foundation | Complete | App and test targets, shared scheme, CI |
| Phase 3 player engine | Complete for supported public APIs | Reducer, AVPlayer/WebKit coordination, remote controls |
| Phase 4 iPhone experience | Complete | Four tabs, mini player, persisted library, receiver/destination status |
| Phase 5 network hardening | Complete for the embedded receiver | Explicit LAN/DLNA opt-in, Keychain token, limits, URL/redirect policy, tests |
| Phase 6 public CarPlay audio | Implemented; device approval/testing pending | Templates, library, Now Playing, controls |
| Phase 6 iOS 27 video metadata | Source complete; SDK/approval blocked | Compiler/runtime guards and capability check |
| Phase 7 build/test automation | Passing | GitHub Actions run 38154005936 |
| Phase 7 signing/TestFlight/device validation | Pending owner hardware/account | `RELEASE_CHECKLIST.md` |

## Build evidence

- Repository: `fengng6907-byte/carplay`
- Verified source commit: `3f65e3af209a78052d9f4d17686610236fc0e8a8`
- Workflow run: `38154005936`
- Runner: GitHub-hosted macOS 15.7.9, arm64
- Toolchain: Xcode 26.3 (17C529), iPhoneSimulator 26.2 SDK
- Clean Debug generic simulator build: **succeeded**
- Unsigned Release generic iOS device build: **succeeded**
- Unit tests: **15 executed, 0 failures, 0 unexpected**

The first run (`38153360104`) also proved the app compiled, then correctly failed the
test gate because the generated Debug target lacked `ENABLE_TESTABILITY`. Commit
`11c1c6d` fixed that project setting; the next run passed. This record does not claim a
signed device archive or an iOS 27 SDK build.

## Implemented safeguards and scope limits

- The LAN receiver defaults off; loopback does not require Wi-Fi.
- Proprietary LAN APIs require a per-install bearer token held in Keychain.
- HTTP headers/bodies and client request rates are bounded.
- Unsafe schemes, embedded credentials, private public-mode targets, and unsafe
  redirects are rejected.
- DLNA SSDP/AVTransport is available only in explicit compatibility mode.
- WebKit and AVPlayer are coordinated to avoid simultaneous playback.
- The app does not claim Widevine/HDCP bypass, universal websites, raw-DASH support,
  capture-based DRM relay, or indefinite background service execution.
- CarPlay uses public templates only; no entitlement spoofing, private API, custom media
  window, or driving-state bypass exists.

## Remaining release blockers

1. Replace placeholder bundle identifiers and select the owner's Apple Developer team.
2. Obtain Apple's applicable CarPlay app-category approval and provisioning. Obtain
   multicast networking approval only if LAN DLNA discovery will ship.
3. Build the guarded video branch with an iOS 27 SDK and obtain Apple's video-app
   approval before representing video playback as supported in CarPlay.
4. Run a signed archive, Organizer validation, TestFlight review, and entitlement
   inspection on the owner's Mac/account.
5. Complete physical iPhone, AirPlay/external display, LAN-permission, CarPlay Simulator,
   supported head-unit, interruption, and parked/moving transition tests.
These blockers require Apple credentials, approvals, an SDK not present in the verified
runner, or physical hardware and therefore cannot be truthfully completed in CI alone.
