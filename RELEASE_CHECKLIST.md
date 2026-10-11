# Entitlement, signing, and device checklist

## Apple account and identifiers

- [ ] Replace `com.example.OmniCast` with the registered bundle identifier.
- [ ] Select the owning Apple Developer team in the app and test targets.
- [ ] Create development, Ad Hoc/TestFlight, and App Store provisioning as appropriate.
- [ ] Keep certificates, `.p12` files, provisioning profiles, API keys, and passwords out
      of source control and GitHub logs.

## Capabilities and approvals

- [ ] Request the correct public CarPlay app-category entitlement from Apple. Start with
      audio only unless Apple approves the video category.
- [ ] For iOS 27 video, obtain Apple's video-app approval; do not hand-edit or spoof the
      entitlement. Confirm the generated provisioning profile contains the capability.
- [ ] Request `com.apple.developer.networking.multicast` only if user-enabled DLNA SSDP
      remains a product feature.
- [ ] Keep the Audio background mode only while the app performs qualifying playback.
- [ ] Verify `NSLocalNetworkUsageDescription`, `NSLocationWhenInUseUsageDescription`,
      `NSMotionUsageDescription`, and the privacy manifest against shipped behavior.
- [ ] Do not add private CarPlay APIs, custom media windows, driving-state overrides, or
      DRM-bypass behavior.

## Build and archive

- [ ] Run Debug simulator build and unit tests from `README.md`.
- [ ] Run Release generic-device build with signing disabled to catch configuration errors.
- [ ] Set marketing/build versions and create a signed Archive in Xcode Organizer.
- [ ] Validate the archive and inspect its final entitlements with `codesign -d --entitlements :-`.
- [ ] Run Analyze and address warnings, concurrency diagnostics, privacy warnings, and
      deprecated API reports.
- [x] Add a complete 1024×1024 AppIcon asset.

## Manual iPhone playback plan

- [ ] HLS VOD/live, MP4, audio-only, redirecting CDN, expired URL, offline recovery.
- [ ] Buffering, seek, end/replay, interruption by call/Siri, Bluetooth/AirPlay route
      changes, headphones removed, app background/foreground, lock/unlock.
- [ ] Verify only one audio engine plays while switching AVPlayer/WebKit routes.
- [ ] VoiceOver, Dynamic Type, Reduce Motion, dark mode, landscape, and iPad layout.
- [ ] Confirm unsupported DRM/websites fail honestly with accessible errors.

## Manual network and DLNA plan

- [ ] Verify LAN receiver defaults off and requires explicit informed consent after Phase 5.
- [ ] Test denied/revoked local-network permission and listener recreation.
- [ ] Test loopback-only mode without Wi-Fi.
- [ ] Validate SSDP discovery on physical hardware with the multicast entitlement.
- [ ] Fuzz request line, headers, content length, SOAP XML, DIDL-Lite metadata, and body
      limits; test authentication replay and per-client rate limiting.
- [ ] Test redirects to loopback, link-local, RFC1918, IPv6 ULA, metadata-service, and
      scheme-changing destinations.

## Manual CarPlay and external-display plan

- [ ] Test CarPlay connect/disconnect while idle, loading, playing, buffering, and paused.
- [ ] Verify browse, Now Playing, remote commands, steering-wheel controls, and audio-only
      fallback on a non-video vehicle.
- [ ] Test CarPlay Simulator at 800×480, 1024×600, 1920×720, and ultrawide sizes.
- [ ] With iOS 27 approval, confirm `supportsVideoPlayback` before advertising video and
      verify the system blocks/transitions video when unavailable.
- [ ] Test AirPlay video selection, parked/moving transitions, phone lock, route loss, and
      reconnection on a supported vehicle.
- [ ] Test ordinary external-display scene resize/disconnect independently of CarPlay.

## TestFlight

- [ ] Upload only after archive validation and entitlement inspection.
- [ ] Provide App Review with accurate feature descriptions, receiver setup, hardware
      requirements, test media, and entitlement context.
- [ ] Add internal testers first; collect MetricKit, crash, stall, route, and receiver
      diagnostics without logging URLs containing secrets.
- [ ] Complete export-compliance, privacy nutrition labels, age rating, and content rights.
- [ ] Do not use remote configuration to conceal browser, video, or receiver behavior.
