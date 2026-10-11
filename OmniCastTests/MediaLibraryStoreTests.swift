import XCTest
@testable import OmniCast

@MainActor
final class MediaLibraryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MediaLibraryStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordsDeduplicatesAndPersistsEntries() {
        let url = URL(string: "https://example.com/movie.mp4")!
        let store = MediaLibraryStore(defaults: defaults)
        let first = store.record(url: url, title: "Movie")
        store.setSaved(true, for: first)
        _ = store.record(url: url, title: "Renamed")

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.title, "Renamed")
        XCTAssertEqual(store.savedEntries.count, 1)

        let restored = MediaLibraryStore(defaults: defaults)
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(restored.entries.first?.url, url)
        XCTAssertTrue(restored.entries.first?.isSaved == true)
    }

    func testClearRecentsPreservesSavedEntries() {
        let store = MediaLibraryStore(defaults: defaults)
        let saved = store.record(url: URL(string: "https://example.com/saved.mp4")!, title: "Saved")
        store.setSaved(true, for: saved)
        _ = store.record(url: URL(string: "https://example.com/recent.mp4")!, title: "Recent")

        store.clearRecents()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.title, "Saved")
    }
}
