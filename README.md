# OmniCast

[![iOS build and tests](https://github.com/fengng6907-byte/carplay/actions/workflows/ios.yml/badge.svg)](https://github.com/fengng6907-byte/carplay/actions/workflows/ios.yml)

OmniCast is a native iOS 16+ media player built with SwiftUI, UIKit,
AVFoundation, WebKit, Network, MediaPlayer, and public CarPlay templates. It offers
phone playback, an explicit opt-in local receiver, a persistent media library, public
CarPlay audio browsing/Now Playing, and ordinary AirPlay/external-display playback.

The app does not bypass DRM, expose arbitrary WebKit content as a custom CarPlay window,
spoof entitlements, conceal features behind remote configuration, or promise unsupported
background execution.

## Verified build

GitHub Actions commit `3f65e3a` completed clean Debug simulator and unsigned Release
generic-device builds plus all 15 unit tests with Xcode 26.3 / iPhoneSimulator 26.2.
See `BUILD_STATUS.md` for the exact verification record and outstanding device-only
gates.

Open `OmniCast.xcodeproj` in Xcode. The shared scheme is `OmniCast`; the targets are
`OmniCast` and `OmniCastTests`.

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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Architecture

```text
SwiftUI phone UI ──────────┐
CarPlay template scene ────┼── PlayerManager ── AVPlayer
External display scene ────┘         │
                                     └── WKWebView media bridge
                                              ▲
                                              │
ReceiverController ── DLNAReceiverService ────┘
        │
        └── Keychain token + explicit LAN/DLNA consent
```

- `OmniCastApp.swift` composes the process-wide player, library, and receiver models.
- `PhoneRootView.swift` provides Home, Cast, Library, and Settings tabs, accessible
  progress/error/retry states, and a persistent mini player.
- `PlaybackStateModel.swift` is a pure reducer for idle, loading, buffering, playing,
  paused, ended, reconnecting, and failed states.
- `PlayerManager.swift` coordinates one AVPlayer and the active WebKit controller,
  prevents duplicate playback, handles interruptions/routes, and maintains Now Playing
  metadata and remote commands.
- `MediaSourceResolver.swift` classifies MIME types and extensions, validates every URL
  and redirect, and selects native or web playback.
- `MediaLibraryStore.swift` persists recent and saved entries in UserDefaults.
- `CarWebViewController.swift` enables inline/AirPlay media, uses a desktop Safari user
  agent, enlarges controls, removes generic app/cookie banners, and bridges HTML5 state
  and play/pause/seek commands. Site login and paywall UI is intentionally preserved.
- `DLNAReceiverService.swift` implements a bounded HTTP/SOAP receiver and an explicit
  compatibility-mode SSDP/AVTransport subset. `ReceiverController.swift` owns its
  process lifecycle independently of CarPlay.
- `CarPlaySceneDelegate.swift` uses public list and Now Playing templates. It also owns
  the ordinary, noninteractive external-display scene; it never creates a custom media
  window inside the CarPlay template scene.

## Playback and security behavior

Native HLS, MP4/MOV/M4V, and common audio formats route to AVPlayer. HTML pages,
MPEG-DASH manifests, and other browser-oriented sources route to WebKit. Raw DASH and
WebRTC work only when a compatible web application supplies the needed JavaScript,
media, and signaling. Arbitrary websites are not guaranteed.

Public URLs require HTTPS, contain no embedded credentials, and may not resolve to
loopback, link-local, carrier-grade NAT, RFC1918, IPv6 ULA, or multicast targets. The
same policy is applied to redirects. A separate, explicit setting permits local HTTP
sources. This validation reduces SSRF exposure but does not replace server-side URL
controls for a future cloud relay.

The loopback receiver starts independently of the UI. LAN exposure is off by default.
When enabled, `/cast` and `/health` require a per-install 256-bit bearer token stored in
the Keychain. Requests have independent header/body caps and a per-client rate limit.
Unauthenticated standards-compatible UPnP endpoints exist only when the user separately
enables DLNA compatibility mode. Denied local-network access remains visible as a waiting
state and the listener can recover or be recreated from Settings.

FairPlay content must use the content owner's supported key-delivery integration.
Widevine, HDCP circumvention, capture-based DRM relays, and universal website playback
are not implemented.

## CarPlay and iOS 27

The iOS 16+ path is a legitimate audio CarPlay app: library browsing, Now Playing, and
remote playback controls use `CPTemplateApplicationScene`. Apple's public custom
`CPWindow` path is navigation/map-specific and is not used here.

iOS 27 playback metadata is source-gated by both compiler and runtime availability. With
an iOS 27 SDK and Apple's video-app approval, OmniCast checks
`CPSessionConfiguration.supportsVideoPlayback` and assigns a
`CPPlaybackConfiguration`; otherwise it advertises audio presentation. The system and
vehicle remain authoritative for video availability and parked/moving transitions.
AirPlay and ordinary external displays use AVPlayer/WebKit public pathways.

The iOS 27 branch was not compiled by the recorded Xcode 26.3 run. It remains an SDK and
Apple-approval gate, not a claimed verified feature.

## Automated tests

`OmniCastTests` contains 15 tests covering:

- reducer transitions, retry, completion, destination preservation, and invalid values;
- MIME precedence, extension fallback, and base URL rejection;
- public/private URL policy, local HTTP opt-in, parser/body limits, bearer
  authentication, and rate limiting; and
- media-library deduplication, persistence, saved entries, and recent-entry cleanup.

## Release preparation

- `AUDIT.md` records the original Phase 1 audit.
- `BUILD_STATUS.md` separates completed work from device/approval blockers.
- `RELEASE_CHECKLIST.md` covers identifiers, signing, Apple approvals, TestFlight,
  CarPlay, network, external-display, accessibility, and physical-device testing.

Before distribution, replace `com.example.OmniCast`, select the owning development team,
request the appropriate CarPlay and multicast capabilities from Apple, generate profiles
through the developer portal, and complete the manual checklist. Never commit signing
certificates, private keys, profiles, API keys, or receiver tokens.

## Distribution policy

Use transparent Store and Internal configurations. Internal builds may add diagnostics
or developer endpoints, but must not conceal remotely activated browser/video behavior.
Sideloading does not grant CarPlay or multicast entitlements and does not make private
APIs or driving-state bypasses acceptable.
