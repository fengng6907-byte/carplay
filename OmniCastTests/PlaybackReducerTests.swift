import XCTest
@testable import OmniCast

final class PlaybackReducerTests: XCTestCase {
    private let reducer = PlaybackReducer()
    private let mediaURL = URL(string: "https://example.com/live.m3u8")!

    func testNativePlaybackLifecycle() {
        var state = PlaybackSnapshot.initial
        state = reducer.reduce(state, event: .loadStarted(route: .native(mediaURL), title: "Live"))
        XCTAssertEqual(state.phase, .loading)
        XCTAssertEqual(state.route, .native(mediaURL))

        state = reducer.reduce(state, event: .ready(duration: 120))
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.duration, 120)

        state = reducer.reduce(state, event: .started)
        XCTAssertEqual(state.phase, .playing)

        state = reducer.reduce(state, event: .buffering)
        XCTAssertEqual(state.phase, .buffering)

        state = reducer.reduce(state, event: .progress(elapsed: 30, duration: 120))
        XCTAssertEqual(state.elapsed, 30)

        state = reducer.reduce(state, event: .ended)
        XCTAssertEqual(state.phase, .ended)
        XCTAssertEqual(state.elapsed, 120)
    }

    func testFailureAndRetryState() {
        var state = reducer.reduce(
            .initial,
            event: .loadStarted(route: .web(mediaURL), title: "Page")
        )
        state = reducer.reduce(state, event: .failed(message: "Offline", retryable: true))
        XCTAssertEqual(state.phase, .failed(message: "Offline", retryable: true))
        XCTAssertTrue(state.canRetry)

        state = reducer.reduce(state, event: .reconnecting(attempt: 2))
        XCTAssertEqual(state.phase, .reconnecting(attempt: 2))
        XCTAssertFalse(state.canRetry)
    }

    func testStopPreservesDestinationButClearsMedia() {
        var state = PlaybackSnapshot.initial
        state = reducer.reduce(state, event: .destinationChanged(.airPlay(name: "Living Room")))
        state = reducer.reduce(state, event: .loadStarted(route: .native(mediaURL), title: "Movie"))
        state = reducer.reduce(state, event: .started)
        state = reducer.reduce(state, event: .stopped)

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.route, .idle)
        XCTAssertEqual(state.destination, .airPlay(name: "Living Room"))
        XCTAssertEqual(state.elapsed, 0)
    }

    func testInvalidEventsDoNotStartIdlePlayback() {
        XCTAssertEqual(reducer.reduce(.initial, event: .started), .initial)
        XCTAssertEqual(reducer.reduce(.initial, event: .buffering), .initial)
        XCTAssertEqual(reducer.reduce(.initial, event: .ended), .initial)
    }

    func testNonFiniteProgressIsSanitized() {
        var state = reducer.reduce(
            .initial,
            event: .loadStarted(route: .native(mediaURL), title: "Media")
        )
        state = reducer.reduce(state, event: .progress(elapsed: .infinity, duration: .nan))
        XCTAssertEqual(state.elapsed, 0)
        XCTAssertEqual(state.duration, 0)
    }
}
