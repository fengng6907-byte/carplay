# OmniCast

OmniCast is a native iOS 16+ media-player foundation built with SwiftUI, UIKit,
AVFoundation, WebKit, Network, MediaPlayer, and public CarPlay templates.

> Build status: the project and tests have been generated and statically audited, but
> have **not** been compiled on this Windows host. Do not treat the project as build-
> verified until the included macOS workflow or a local Mac completes `xcodebuild`.

## Open the project

Open `OmniCast.xcodeproj` in the current stable Xcode. The app target is `OmniCast`, the
unit-test target is `OmniCastTests`, and the shared scheme is `OmniCast`.

Command-line validation on macOS:

```sh
xcodebuild \
  -project OmniCast.xcodeproj \
  -scheme OmniCast \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  clean build

xcodebuild \
  -project OmniCast.xcodeproj \
  -scheme OmniCast \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The GitHub Actions workflow performs the same unsigned simulator build and chooses an
available iPhone simulator for unit tests.

## Current architecture

```
SwiftUI phone scene ───────┐
CarPlay CPTemplate scene ──┼── PlayerManager ── AVPlayer
External display scene ────┘         │
                                     └── WKWebView media bridge
                                              ▲
                                              │
                                    DLNAReceiverService
```

- `OmniCastApp.swift` is the SwiftUI entry point.
- `PhoneRootView.swift` is the Phase 2 phone shell with validated URL entry, playback
  state, destination, controls, and retry UI.
- `PlaybackStateModel.swift` contains a pure reducer for loading, buffering, playing,
  paused, ended, reconnecting, and failure transitions.
- `PlayerManager.swift` owns one `AVPlayer`, one unified snapshot, Now Playing metadata,
  remote commands, interruptions, route changes, and WebKit coordination.
- `MediaSourceResolver.swift` combines MIME and extension classification. It sends a
  bounded HEAD request and safely falls back when a CDN rejects HEAD.
- `CarWebViewController.swift` is a phone/external-display WebKit host. It is not
  installed as arbitrary CarPlay content.
- `DLNAReceiverService.swift` is the existing compact UPnP receiver. Its security and
  lifecycle hardening remain a Phase 5 item and it must not be exposed on a LAN in a
  release build yet.
- `CarPlaySceneDelegate.swift` provides public list and Now Playing templates and an
  ordinary noninteractive external-display window.

## Playback behavior

Native HLS, MP4/MOV/M4V, and common audio formats route to AVPlayer. HTML pages,
MPEG-DASH manifests, and other browser-oriented sources route to WebKit. Actual DASH
playback requires a WebKit-compatible page/player; a raw manifest alone is not a
universal player. WebRTC requires a valid signaling/application page.

Switching engines pauses the previous engine to avoid duplicate audio. AVPlayer state is
derived from item status and `timeControlStatus`; WebKit reports playing, buffering,
ended, time, duration, and title through the script bridge. Audio interruptions and
route changes update the shared state and Now Playing metadata.

FairPlay content must use the content owner's supported key-delivery integration.
Widevine, capture-based DRM relays, arbitrary website playback, and universal background
execution are not claimed or implemented.

## Scene configuration

`Info.plist` declares:

- the `CPTemplateApplicationSceneSessionRoleApplication` CarPlay scene;
- the `UIWindowSceneSessionRoleExternalDisplayNonInteractive` external-display scene;
- local-network, location, and motion usage descriptions; and
- the audio background mode.

The CarPlay scene uses templates only. Apple restricts custom `CPWindow` content to
navigation map rendering. On iOS 27, approved video apps must use Apple's video
entitlement, AirPlay support, `CPSessionConfiguration.supportsVideoPlayback`, and
`CPPlaybackConfiguration`; CarPlay remains responsible for parked-state availability.
Those SDK-only additions are intentionally gated until the project is built with an
iOS 27 SDK and the entitlement is approved.

## Tests

`OmniCastTests` currently covers:

- native playback state transitions;
- buffering, completion, failure, retry, and stop behavior;
- destination preservation;
- invalid idle transitions and non-finite time sanitization;
- MIME precedence and extension fallback; and
- rejection of unsafe URL schemes and missing hosts.

Network parser, authentication, rate-limit, redirect, and private-target tests belong to
Phase 5 and are listed as blocked in `BUILD_STATUS.md` until the Phase 2/3 build gate is
green.

## Repository documents

- `AUDIT.md` — Phase 1 implementation and gap audit.
- `BUILD_STATUS.md` — completed checks, unverified claims, and phase gate.
- `RELEASE_CHECKLIST.md` — entitlements, signing, TestFlight, CarPlay, and physical-
  device testing.

## Distribution policy

Use transparent Store and Internal configurations. Internal builds may add diagnostics
or test endpoints, but must not contain concealed remotely activated features. Sideloading
does not grant CarPlay or multicast entitlements and does not make private APIs acceptable.

