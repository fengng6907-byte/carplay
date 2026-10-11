# OmniCast Phase 1 audit

Audit date: 2026-10-11. Baseline: the four Swift files and README originally in
this directory. The audit was performed on Windows without Xcode or an Apple SDK;
therefore all build findings are static until macOS CI or a developer Mac runs
`xcodebuild`.

## Executive gap report

The baseline is an architectural prototype, not yet an application project. It has
useful implementations for a shared player, a WebKit controller, a compact UPnP
receiver, and public CarPlay templates, but it has no Xcode project, app entry point,
phone UI, tests, assets, entitlements, signing configuration, or CI workflow.

### Implemented in the baseline

- One process-wide `PlayerManager` coordinating `AVPlayer`, MediaPlayer remote commands,
  Now Playing metadata, and a WebKit command protocol.
- A `WKWebView` controller with inline/AirPlay playback configuration, injected viewport
  and accessibility-oriented controls, media-state messages, and cross-frame commands.
- A compact HTTP/SOAP receiver with loopback support, SSDP multicast, UPnP device
  description, DIDL-Lite metadata parsing, and AVTransport handoff.
- Public `CPTemplateApplicationSceneDelegate` integration with list and Now Playing
  templates; no custom CarPlay window.
- A noninteractive external-display scene and optional GPS/Core Motion safety monitor.

### Missing or incomplete

- No `.xcodeproj`, target membership, bundle resources, asset catalog, `Info.plist`,
  entitlements file, app icon, launch screen, or SwiftUI `@main` entry point.
- No Home, Cast, Library, Settings, persistent mini-player, persistence model, URL
  validation UI, receiver opt-in, or user-visible retry/error flow.
- No test seam around `AVPlayer`; state is mutated optimistically rather than derived
  from `timeControlStatus`, item status, buffering, completion, interruptions, and route
  changes.
- Playback states do not include buffering, ended, or reconnecting. Web playback can
  report only playing/paused.
- Routing relies mainly on filename extensions. It does not inspect response MIME type,
  HLS content type, redirects, content disposition, or server policy.
- DLNA is tied to `CarPlaySessionCoordinator`, enabled on the LAN automatically, and has
  no explicit user consent state.
- OmniCast `/cast` APIs have no authentication, rate limiting, redirect validation,
  private-target protection, or per-client quotas. DLNA compatibility and proprietary
  OmniCast APIs are not separated.
- The UPnP implementation is intentionally partial: minimal SCPD, no ConnectionManager
  or RenderingControl service, no event notifications, and limited SSDP target handling.
- No iOS 27 `CPSessionConfiguration.supportsVideoPlayback` capability check or
  `CPPlaybackConfiguration` integration exists. The baseline remains a legitimate audio
  CarPlay app plus ordinary external/AirPlay video output.
- No automated tests, simulator builds, CI, device plan, TestFlight instructions, or
  build-status record exists.

## Referenced types and protocols

All custom symbols referenced by the four Swift files are defined in those files:
`PlayerManager`, `WebVideoControlling`, `WebMediaCommand`, `CarWebViewController`,
`DLNAReceiverService`, `CarPlaySessionCoordinator`, and `DrivingSafetyMonitor`.
There are no missing custom type definitions. The missing pieces are application-level
composition and target configuration.

## Static compile and behavior risks

1. The source cannot compile as an app because there is no target or entry point.
2. `PlayerManager.play()` sets `.playing` before AVPlayer actually starts; failures and
   buffering can therefore produce incorrect UI and Now Playing state.
3. `loadWeb` can request playback before a WebKit host exists. Attachment recovers this,
   but there is no explicit route/readiness state.
4. Notification and remote-command targets are installed for process lifetime and are
   not injectable, which blocks deterministic unit tests.
5. HTTP parsing has a total buffer cap but lacks separate header/body limits and rate
   limiting. LAN `/cast` requests accept arbitrary HTTP(S) targets.
6. `@unchecked Sendable` on the receiver is justified only by consistent queue isolation;
   this must be preserved during edits.
7. The SSDP group requires Apple's multicast entitlement on physical iOS devices.
8. WebKit cannot promise compatibility with arbitrary sites, MPEG-DASH pages, embedded
   cross-origin players, DRM providers, or background execution.

## API availability, iOS 16 through iOS 27

| API area | Baseline availability assessment |
|---|---|
| `CPTemplateApplicationScene`, list templates, Now Playing | Available throughout the supported iOS 16+ range with the correct CarPlay entitlement. |
| `CPWindow` custom content | Not valid for this media app; public access is navigation-only and map-only. |
| `UIWindowSceneSessionRoleExternalDisplayNonInteractive` | Valid scene role for ordinary external displays; independent of CarPlay templates. |
| `NWListener`, `NWConnectionGroup`, `NWMulticastGroup` | Available before iOS 16; multicast still requires entitlement and user-approved local-network access. |
| Current WKWebView media configuration | Available on iOS 16+; site policy and WebKit media support still apply. |
| `CPPlaybackConfiguration` and `supportsVideoPlayback` | iOS 27 SDK capability. Must be compiled and executed behind availability checks and only with Apple's video entitlement/approved vehicle path. |

The deployment target should remain iOS 16.0. iOS 27-only source must use both SDK-aware
conditional compilation where necessary and `if #available(iOS 27.0, *)` runtime guards.
An Xcode version containing the iOS 27 SDK is required to compile those symbols.

## Phase gate

Phase 2 may proceed after adding a real project, app composition, injectable playback
state reducer, tests, and CI. Phase 3 may proceed once the app target and test target can
be built by macOS CI. Local build success remains unverified on this host.

