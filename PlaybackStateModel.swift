import Foundation

enum PlaybackRoute: Equatable, Sendable {
    case idle
    case native(URL)
    case web(URL)
}

enum PlaybackPhase: Equatable, Sendable {
    case idle
    case loading
    case buffering
    case playing
    case paused
    case ended
    case reconnecting(attempt: Int)
    case failed(message: String, retryable: Bool)
}

enum PlaybackDestination: Equatable, Sendable {
    case device
    case carPlay
    case externalDisplay
    case airPlay(name: String?)

    var displayName: String {
        switch self {
        case .device: return "This iPhone"
        case .carPlay: return "CarPlay"
        case .externalDisplay: return "External Display"
        case let .airPlay(name): return name ?? "AirPlay"
        }
    }
}

struct PlaybackSnapshot: Equatable, Sendable {
    var route: PlaybackRoute = .idle
    var phase: PlaybackPhase = .idle
    var title = "OmniCast"
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var destination: PlaybackDestination = .device
    var canRetry = false

    static let initial = PlaybackSnapshot()
}

enum PlaybackEvent: Equatable, Sendable {
    case loadStarted(route: PlaybackRoute, title: String)
    case ready(duration: TimeInterval)
    case buffering
    case started
    case paused
    case progress(elapsed: TimeInterval, duration: TimeInterval)
    case ended
    case reconnecting(attempt: Int)
    case destinationChanged(PlaybackDestination)
    case failed(message: String, retryable: Bool)
    case stopped
}

/// A pure reducer makes playback transitions deterministic and independently testable.
struct PlaybackReducer: Sendable {
    func reduce(_ snapshot: PlaybackSnapshot, event: PlaybackEvent) -> PlaybackSnapshot {
        var next = snapshot
        switch event {
        case let .loadStarted(route, title):
            next.route = route
            next.phase = .loading
            next.title = title
            next.elapsed = 0
            next.duration = 0
            next.canRetry = false
        case let .ready(duration):
            next.duration = duration.finiteOrZero
            if next.phase == .loading || next.phase == .buffering { next.phase = .paused }
        case .buffering:
            guard next.route != .idle else { return snapshot }
            next.phase = .buffering
        case .started:
            guard next.route != .idle else { return snapshot }
            next.phase = .playing
            next.canRetry = false
        case .paused:
            guard next.route != .idle, next.phase != .ended else { return snapshot }
            next.phase = .paused
        case let .progress(elapsed, duration):
            guard next.route != .idle else { return snapshot }
            next.elapsed = max(0, elapsed.finiteOrZero)
            next.duration = max(0, duration.finiteOrZero)
        case .ended:
            guard next.route != .idle else { return snapshot }
            next.phase = .ended
            if next.duration > 0 { next.elapsed = next.duration }
        case let .reconnecting(attempt):
            guard next.route != .idle else { return snapshot }
            next.phase = .reconnecting(attempt: max(1, attempt))
            next.canRetry = false
        case let .destinationChanged(destination):
            next.destination = destination
        case let .failed(message, retryable):
            guard next.route != .idle else { return snapshot }
            next.phase = .failed(message: message, retryable: retryable)
            next.canRetry = retryable
        case .stopped:
            let destination = next.destination
            next = .initial
            next.destination = destination
        }
        return next
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}
