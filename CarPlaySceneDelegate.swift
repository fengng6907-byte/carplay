import AVKit
import AVFoundation
@preconcurrency import CarPlay
import Combine
import CoreLocation
import CoreMotion
import UIKit

/// A standards-compliant CarPlay scene. Audio/Now Playing controls use templates;
/// video is rendered only in a normal external-display UIWindow or on the phone.
@MainActor
final class CarPlaySceneDelegate: UIResponder, @preconcurrency CPTemplateApplicationSceneDelegate, CPSessionConfigurationDelegate {
    private var interfaceController: CPInterfaceController?
    private var sessionConfiguration: CPSessionConfiguration?
    private var observations = Set<AnyCancellable>()
    private let player = PlayerManager.shared

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        self.sessionConfiguration = CPSessionConfiguration(delegate: self)
        CarPlaySessionCoordinator.shared.connect()
        installRootTemplate(on: interfaceController)

        player.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRootTemplate() }
            .store(in: &observations)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        observations.removeAll()
        self.interfaceController = nil
        self.sessionConfiguration = nil
        CarPlaySessionCoordinator.shared.disconnect()
    }

    private func installRootTemplate(on controller: CPInterfaceController) {
        controller.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
    }

    private func refreshRootTemplate() {
        guard let interfaceController else { return }
        interfaceController.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
    }

    private func makeRootTemplate() -> CPListTemplate {
        let nowPlaying = CPListItem(text: player.title, detailText: playbackDetail)
        configurePlaybackPresentation(for: nowPlaying)
        nowPlaying.handler = { [weak self] _, completion in
            guard let self, let interfaceController = self.interfaceController else {
                completion()
                return
            }
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            completion()
        }

        let toggleTitle = player.state == .playing ? "Pause" : "Play"
        let toggle = CPListItem(text: toggleTitle, detailText: "Control current media")
        toggle.handler = { [weak self] _, completion in
            self?.player.togglePlayback()
            completion()
        }

        let skipBack = CPListItem(text: "Back 10 seconds", detailText: nil)
        skipBack.handler = { [weak self] _, completion in
            self?.player.skip(by: -10)
            completion()
        }

        let skipForward = CPListItem(text: "Forward 10 seconds", detailText: nil)
        skipForward.handler = { [weak self] _, completion in
            self?.player.skip(by: 10)
            completion()
        }

        let receiver = CPListItem(
            text: "Receiver active",
            detailText: ReceiverController.shared.statusText
        )
        receiver.isEnabled = false

        let savedItems = MediaLibraryStore.shared.savedEntries.prefix(12).map { entry in
            let item = CPListItem(text: entry.title, detailText: entry.url.host)
            item.handler = { _, completion in
                PlayerManager.shared.load(
                    entry.url,
                    title: entry.title,
                    mimeType: entry.mimeType,
                    allowsLocalNetworkSource: UserDefaults.standard.bool(forKey: "OmniCast.AllowLocalSources")
                )
                completion()
            }
            return item
        }

        let template = CPListTemplate(
            title: "OmniCast",
            sections: [
                CPListSection(items: [nowPlaying, toggle, skipBack, skipForward], header: "Playback", sectionIndexTitle: nil),
                CPListSection(
                    items: savedItems.isEmpty
                        ? [CPListItem(text: "No saved media", detailText: "Save items from the iPhone app")]
                        : Array(savedItems),
                    header: "Library",
                    sectionIndexTitle: nil
                ),
                CPListSection(items: [receiver], header: "Local receiver", sectionIndexTitle: nil)
            ]
        )
        template.tabTitle = "OmniCast"
        return template
    }

    private var playbackDetail: String {
        switch player.state {
        case .idle: return "No media selected"
        case .loading: return "Loading"
        case .buffering: return "Buffering"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .ended: return "Ended"
        case let .reconnecting(attempt): return "Reconnecting (\(attempt))"
        case let .failed(message, _): return message
        }
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration, contentStyleChanged contentStyle: CPContentStyle) {
        refreshRootTemplate()
    }

    func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        refreshRootTemplate()
    }

    private func configurePlaybackPresentation(for item: CPListItem) {
        #if compiler(>=6.3)
        if #available(iOS 27.0, *) {
            let supportsVideo = sessionConfiguration?.supportsVideoPlayback == true
            let presentation: CPPlaybackConfiguration.Presentation = supportsVideo && currentItemPrefersVideo
                ? .video
                : .audio
            let action: CPPlaybackConfiguration.Action
            switch player.state {
            case .playing: action = .pause
            case .ended: action = .replay
            default: action = .play
            }
            item.playbackConfiguration = CPPlaybackConfiguration(
                preferredPresentation: presentation,
                playbackAction: action,
                elapsedTime: CMTime(seconds: player.elapsed, preferredTimescale: 600),
                duration: CMTime(seconds: player.duration, preferredTimescale: 600)
            )
        }
        #endif
    }

    private var currentItemPrefersVideo: Bool {
        let url: URL?
        switch player.route {
        case let .native(value), let .web(value): url = value
        case .idle: url = nil
        }
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return !["mp3", "m4a", "aac", "wav", "aiff", "flac"].contains(ext)
    }
}

/// Owns services for the whole connected CarPlay session, not for a cast screen.
@MainActor
final class CarPlaySessionCoordinator {
    static let shared = CarPlaySessionCoordinator()
    private var connectionCount = 0

    private init() {}

    func connect() {
        connectionCount += 1
        guard connectionCount == 1 else { return }
        PlayerManager.shared.setDestination(.carPlay)
    }

    func disconnect() {
        connectionCount = max(0, connectionCount - 1)
        guard connectionCount == 0 else { return }
        PlayerManager.shared.refreshPlaybackDestination()
    }
}

/// Register this delegate for UIWindowSceneSessionRoleExternalDisplayNonInteractive.
/// UIKit binds the UIWindowScene to the actual external UIScreen and updates its
/// coordinate space as the head unit changes resolution or aspect ratio.
@MainActor
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var playerHost: AdaptivePlayerHostViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let host = AdaptivePlayerHostViewController(player: .shared)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.playerHost = host
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window?.isHidden = true
        window = nil
        playerHost = nil
    }
}

@MainActor
private final class AdaptivePlayerHostViewController: UIViewController {
    private let player: PlayerManager
    private let nativeController: AVPlayerViewController
    private let webController = CarWebViewController()
    private var observations = Set<AnyCancellable>()

    init(player: PlayerManager) {
        self.player = player
        self.nativeController = player.makePlayerViewController()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        embed(nativeController)
        embed(webController)
        webController.interactionAllowed = false // noninteractive external scene

        player.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.show(snapshot.route) }
            .store(in: &observations)
        show(player.route)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        nativeController.view.frame = view.bounds
        webController.view.frame = view.bounds
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    private func show(_ route: PlayerManager.Route) {
        let webIsVisible: Bool
        if case .web = route { webIsVisible = true } else { webIsVisible = false }
        webController.view.isHidden = !webIsVisible
        nativeController.view.isHidden = webIsVisible
        view.bringSubviewToFront(webIsVisible ? webController.view : nativeController.view)
    }
}

/// Optional safety policy for the phone UI. CarPlay's template framework already
/// enforces its own interaction model. GPS supplies speed; Core Motion supplies a
/// conservative automotive activity signal when GPS is temporarily unavailable.
@MainActor
final class DrivingSafetyMonitor: NSObject, ObservableObject {
    @Published private(set) var restrictsTouchInput = false
    var speedThreshold: CLLocationSpeed = 2.25 // about 8 km/h

    private let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private var latestSpeed: CLLocationSpeed = -1
    private var automotiveMotion = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .automotiveNavigation
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                Task { @MainActor in
                    self?.automotiveMotion = activity?.automotive == true && activity?.confidence != .low
                    self?.recalculate()
                }
            }
        }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        activityManager.stopActivityUpdates()
    }

    private func recalculate() {
        restrictsTouchInput = latestSpeed >= speedThreshold || (latestSpeed < 0 && automotiveMotion)
    }
}

extension DrivingSafetyMonitor: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let speed = locations.last?.speed else { return }
        Task { @MainActor in
            self.latestSpeed = speed
            self.recalculate()
        }
    }
}
