import XCTest
@testable import OmniCast

final class MediaSourceResolverTests: XCTestCase {
    func testMIMETypeTakesPrecedenceOverExtension() {
        let url = URL(string: "https://example.com/media.php?id=1")!
        XCTAssertEqual(
            MediaSourceResolver.classify(url: url, mimeType: "application/vnd.apple.mpegurl; charset=utf-8"),
            .nativeHLS
        )
        XCTAssertEqual(
            MediaSourceResolver.classify(url: url, mimeType: "application/dash+xml"),
            .dashManifest
        )
        XCTAssertEqual(MediaSourceResolver.classify(url: url, mimeType: "video/mp4"), .nativeFile)
        XCTAssertEqual(MediaSourceResolver.classify(url: url, mimeType: "text/html"), .webPage)
    }

    func testExtensionFallback() {
        XCTAssertEqual(kind("https://example.com/live.m3u8"), .nativeHLS)
        XCTAssertEqual(kind("https://example.com/movie.mp4?token=abc"), .nativeFile)
        XCTAssertEqual(kind("https://example.com/audio.m4a"), .nativeAudio)
        XCTAssertEqual(kind("https://example.com/manifest.mpd"), .dashManifest)
        XCTAssertEqual(kind("https://example.com/watch/123"), .webPage)
    }

    func testURLValidationRejectsUnsafeSchemesAndMissingHosts() {
        XCTAssertThrowsError(try MediaSourceResolver.validateBasicURL(URL(string: "file:///tmp/movie.mp4")!)) {
            XCTAssertEqual($0 as? MediaSourceError, .unsupportedScheme)
        }
        XCTAssertThrowsError(try MediaSourceResolver.validateBasicURL(URL(string: "https:movie.mp4")!)) {
            XCTAssertEqual($0 as? MediaSourceError, .missingHost)
        }
        XCTAssertNoThrow(try MediaSourceResolver.validateBasicURL(URL(string: "https://example.com/movie.mp4")!))
    }

    private func kind(_ value: String) -> MediaSourceKind {
        MediaSourceResolver.classify(url: URL(string: value)!, mimeType: nil)
    }
}
