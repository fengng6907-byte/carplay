import AVFoundation
import AVKit
import Combine
import MediaPlayer
import UIKit

/// Process-wide playback orchestrator shared by phone, CarPlay, and external-display scenes.
@MainActor
final class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    typealias Route = PlaybackRoute
    typealias PlaybackState = PlaybackPhase

    @Published private(set) var snapshot = PlaybackSnapshot.initial

    var route: Route { snapshot.route }
    var state: PlaybackState { snapshot.phase }
    var title: String { snapshot.title }
    var elapsed: TimeInterval { snapshot.elapsed }
    var duration: TimeInterval { snapshot.duration }

    let player: AVPlayer

    private let resolver: any MediaSourceResolving
    private let reducer = PlaybackReducer()
    private weak var webController: WebVideoControlling?
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var loadTask: Task<Void, Never>?
    private var currentRequestID = UUID()
    private var requestedURL: URL?
    private var requestedMIMEType: String?
    private var requestedAllowsLocalNetworkSource = false
    private var shouldAutoplay = false
    private var shouldResumeAfterInterruption = false
    private var reconnectAttempt = 0

    init(
        player: AVPlayer = AVPlayer(),
        resolver: any MediaSourceResolving = MediaSourceResolver(),
        installsSystemIntegrations: Bool = true
    ) {
        self.player = player
        self.resolver = resolver
        super.init()

        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.automaticallyWaitsToMinimizeStalling = true
        installPlayerObservers()

        if installsSystemIntegrations {
            configureAudioSession()
            configureRemoteCommands()
            installSystemNotifications()
        }
    }

    deinit {
        loadTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func attach(webController: WebVideoControlling) {
        self.webController = webController
        guard case let .web(url) = route else { return }
        webController.loadMediaPage(url)
        if shouldAutoplay { webController.sendMediaCommand(.play) }
    }

    func detach(webController: WebVideoControlling) {
        guard self.webController === webController else { return }
        self.webController = nil
    }

    /// Resolves MIME type and redirects before selecting the native or WebKit engine.
    func load(
        _ url: URL,
        title: String? = nil,
        mimeType: String? = nil,
        allowsLocalNetworkSource: Bool = false,
        autoplay: Bool = true
    ) {
        loadTask?.cancel()
        currentRequestID = UUID()
        let requestID = currentRequestID
        requestedURL = url
        requestedMIMEType = mimeType
        requestedAllowsLocalNetworkSource = allowsLocalNetworkSource
        shouldAutoplay = autoplay
        reconnectAttempt = 0

        let displayTitle = title?.trimmedNonempty ?? url.lastPathComponent.trimmedNonempty ?? url.host ?? "OmniCast"
        let provisionalKind = MediaSourceResolver.classify(url: url, mimeType: mimeType)
        let provisionalRoute = ResolvedMediaSource(
            originalURL: url,
            resolvedURL: url,
            kind: provisionalKind,
            mimeType: mimeType
        ).playbackRoute
        apply(.loadStarted(route: provisionalRoute, title: displayTitle))

        let resolver = self.resolver
        let policy: NetworkSecurityPolicy = allowsLocalNetworkSource
            ? .userApprovedLocalNetwork
            : .publicInternet
        loadTask = Task { [weak self, resolver] in
            do {
                let source = try await resolver.resolve(url, suppliedMIMEType: mimeType, policy: policy)
                try Task.checkCancellation()
                guard let self, self.currentRequestID == requestID else { return }
                self.loadResolved(source, title: displayTitle, autoplay: autoplay)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentRequestID == requestID else { return }
                self.apply(.failed(message: error.localizedDescription, retryable: true))
            }
        }
    }

    func retry() {
        guard let requestedURL else { return }
        reconnectAttempt += 1
        apply(.reconnecting(attempt: reconnectAttempt))
        load(
            requestedURL,
            title: title,
            mimeType: requestedMIMEType,
            allowsLocalNetworkSource: requestedAllowsLocalNetworkSource,
            autoplay: true
        )
    }

    func play() {
        shouldAutoplay = true
        switch route {
        case .native:
            activateAudioSession()
            if state == .ended { player.seek(to: .zero) }
            player.play()
        case .web:
            webController?.sendMediaCommand(.play)
        case .idle:
            return
        }
    }

    func pause() {
        shouldAutoplay = false
        switch route {
        case .native:
            player.pause()
        case .web:
            webController?.sendMediaCommand(.pause)
            apply(.paused)
        case .idle:
            return
        }
    }

    func togglePlayback() {
        state == .playing ? pause() : play()
    }

    func stop() {
        loadTask?.cancel()
        shouldAutoplay = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        webController?.sendMediaCommand(.stop)
        requestedURL = nil
        requestedMIMEType = nil
        requestedAllowsLocalNetworkSource = false
        apply(.stopped)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func skip(by seconds: TimeInterval) {
        switch route {
        case .native:
            let current = player.currentTime().seconds.finiteOrZero
            seek(to: max(0, current + seconds))
        case .web:
            webController?.sendMediaCommand(.seekRelative(seconds))
        case .idle:
            break
        }
    }

    func seek(to seconds: TimeInterval) {
        let safeSeconds = max(0, seconds.finiteOrZero)
        switch route {
        case .native:
            player.seek(
                to: CMTime(seconds: safeSeconds, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
            )
        case .web:
            webController?.sendMediaCommand(.seekAbsolute(safeSeconds))
        case .idle:
            break
        }
    }

    func receiveWebState(
        isPlaying: Bool,
        isBuffering: Bool,
        hasEnded: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        title: String?
    ) {
        guard case .web = route else { return }
        apply(.progress(elapsed: currentTime, duration: duration))
        if let title = title?.trimmedNonempty, title != snapshot.title {
            var updated = snapshot
            updated.title = title
            snapshot = updated
        }
        if hasEnded {
            apply(.ended)
        } else if isBuffering {
            apply(.buffering)
        } else {
            apply(isPlaying ? .started : .paused)
        }
    }

    func setDestination(_ destination: PlaybackDestination) {
        apply(.destinationChanged(destination))
    }

    func refreshPlaybackDestination() {
        refreshDestinationFromAudioRoute()
    }

    func makePlayerViewController() -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    private func loadResolved(_ source: ResolvedMediaSource, title: String, autoplay: Bool) {
        apply(.loadStarted(route: source.playbackRoute, title: title))
        switch source.playbackRoute {
        case let .native(url):
            loadNative(url, autoplay: autoplay)
        case let .web(url):
            loadWeb(url, autoplay: autoplay)
        case .idle:
            break
        }
    }

    private func loadNative(_ url: URL, autoplay: Bool) {
        webController?.sendMediaCommand(.stop)
        let item = AVPlayerItem(url: url)
        observe(item)
        player.replaceCurrentItem(with: item)
        if autoplay { play() }
    }

    private func loadWeb(_ url: URL, autoplay: Bool) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        webController?.loadMediaPage(url)
        if autoplay { webController?.sendMediaCommand(.play) }
    }

    private func observe(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                switch item.status {
                case .readyToPlay:
                    self.apply(.ready(duration: item.duration.seconds.finiteOrZero))
                    if self.shouldAutoplay { self.player.play() }
                case .failed:
                    self.apply(.failed(
                        message: item.error?.localizedDescription ?? "The media could not be played.",
                        retryable: true
                    ))
                default:
                    break
                }
            }
        }
    }

    private func installPlayerObservers() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, case .native = self.route else { return }
                switch player.timeControlStatus {
                case .playing: self.apply(.started)
                case .waitingToPlayAtSpecifiedRate: self.apply(.buffering)
                case .paused:
                    if self.state != .loading && self.state != .ended { self.apply(.paused) }
                @unknown default: break
                }
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, case .native = self.route else { return }
                self.apply(.progress(
                    elapsed: time.seconds.finiteOrZero,
                    duration: self.player.currentItem?.duration.seconds.finiteOrZero ?? 0
                ))
            }
        }
    }

    private func installSystemNotifications() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let item = notification.object as? AVPlayerItem,
                      item === self.player.currentItem else { return }
                self.apply(.ended)
            }
        })
        notifications.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let item = notification.object as? AVPlayerItem,
                      item === self.player.currentItem else { return }
                self.apply(.buffering)
            }
        })
        notifications.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main,
            using: { [weak self] notification in
                Task { @MainActor in self?.handleInterruption(notification) }
            }
        ))
        notifications.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main,
            using: { [weak self] _ in
                Task { @MainActor in self?.refreshDestinationFromAudioRoute() }
            }
        ))
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            shouldResumeAfterInterruption = state == .playing || state == .buffering
            pause()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if shouldResumeAfterInterruption && options.contains(.shouldResume) { play() }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                policy: .longFormVideo,
                options: []
            )
            refreshDestinationFromAudioRoute()
        } catch {
            apply(.failed(message: "Audio session: \(error.localizedDescription)", retryable: false))
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            apply(.failed(message: "Audio output is unavailable: \(error.localizedDescription)", retryable: true))
        }
    }

    private func refreshDestinationFromAudioRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let destination: PlaybackDestination
        if let carPlay = outputs.first(where: { $0.portType == .carAudio }) {
            destination = .carPlay
            _ = carPlay
        } else if let airPlay = outputs.first(where: { $0.portType == .airPlay }) {
            destination = .airPlay(name: airPlay.portName)
        } else {
            destination = .device
        }
        apply(.destinationChanged(destination))
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in self?.skip(by: interval) }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in self?.skip(by: -interval) }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func apply(_ event: PlaybackEvent) {
        snapshot = reducer.reduce(snapshot, event: event)
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        guard route != .idle else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

enum WebMediaCommand {
    case play
    case pause
    case stop
    case seekRelative(TimeInterval)
    case seekAbsolute(TimeInterval)
}

@MainActor
protocol WebVideoControlling: AnyObject {
    func loadMediaPage(_ url: URL)
    func sendMediaCommand(_ command: WebMediaCommand)
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}
