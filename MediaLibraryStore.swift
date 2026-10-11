import Foundation
import Combine

struct MediaLibraryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var url: URL
    var mimeType: String?
    var lastPlayedAt: Date
    var isSaved: Bool

    init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        mimeType: String? = nil,
        lastPlayedAt: Date = .now,
        isSaved: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.mimeType = mimeType
        self.lastPlayedAt = lastPlayedAt
        self.isSaved = isSaved
    }
}

@MainActor
final class MediaLibraryStore: ObservableObject {
    static let shared = MediaLibraryStore()

    @Published private(set) var entries: [MediaLibraryEntry] = []

    var recentEntries: [MediaLibraryEntry] {
        Array(entries.sorted { $0.lastPlayedAt > $1.lastPlayedAt }.prefix(25))
    }

    var savedEntries: [MediaLibraryEntry] {
        entries.filter(\.isSaved).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private let defaults: UserDefaults
    private let storageKey = "OmniCast.MediaLibrary.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    @discardableResult
    func record(url: URL, title: String? = nil, mimeType: String? = nil) -> MediaLibraryEntry {
        if let index = entries.firstIndex(where: { $0.url == url }) {
            entries[index].lastPlayedAt = .now
            if let title = title?.trimmedNonempty { entries[index].title = title }
            if let mimeType { entries[index].mimeType = mimeType }
            persist()
            return entries[index]
        }

        let entry = MediaLibraryEntry(
            title: title?.trimmedNonempty ?? url.lastPathComponent.trimmedNonempty ?? url.host ?? "Media",
            url: url,
            mimeType: mimeType
        )
        entries.append(entry)
        trimHistory()
        persist()
        return entry
    }

    func setSaved(_ saved: Bool, for entry: MediaLibraryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isSaved = saved
        persist()
    }

    func remove(_ entry: MediaLibraryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clearRecents() {
        entries.removeAll { !$0.isSaved }
        persist()
    }

    private func trimHistory() {
        let savedIDs = Set(entries.lazy.filter(\.isSaved).map(\.id))
        let recentIDs = Set(entries.sorted { $0.lastPlayedAt > $1.lastPlayedAt }.prefix(50).map(\.id))
        entries.removeAll { !savedIDs.contains($0.id) && !recentIDs.contains($0.id) }
    }

    private func restore() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MediaLibraryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private extension String {
    var trimmedNonempty: String? {
        let result = trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
