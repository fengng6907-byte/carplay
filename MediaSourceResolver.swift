import Foundation

enum MediaSourceKind: Equatable, Sendable {
    case nativeHLS
    case nativeFile
    case nativeAudio
    case dashManifest
    case webPage
}

struct ResolvedMediaSource: Equatable, Sendable {
    let originalURL: URL
    let resolvedURL: URL
    let kind: MediaSourceKind
    let mimeType: String?

    var playbackRoute: PlaybackRoute {
        switch kind {
        case .nativeHLS, .nativeFile, .nativeAudio:
            return .native(resolvedURL)
        case .dashManifest, .webPage:
            return .web(resolvedURL)
        }
    }
}

enum MediaSourceError: LocalizedError, Equatable {
    case unsupportedScheme
    case missingHost
    case invalidResponse
    case httpStatus(Int)
    case oversizedRedirectChain

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme: return "Only HTTP and HTTPS media URLs are supported."
        case .missingHost: return "The media URL does not contain a host."
        case .invalidResponse: return "The media server returned an invalid response."
        case let .httpStatus(code): return "The media server returned HTTP \(code)."
        case .oversizedRedirectChain: return "The media URL redirected too many times."
        }
    }
}

protocol MediaSourceResolving: Sendable {
    func resolve(
        _ url: URL,
        suppliedMIMEType: String?,
        policy: NetworkSecurityPolicy
    ) async throws -> ResolvedMediaSource
}

struct MediaSourceResolver: MediaSourceResolving, Sendable {
    func resolve(
        _ url: URL,
        suppliedMIMEType: String? = nil,
        policy: NetworkSecurityPolicy = .publicInternet
    ) async throws -> ResolvedMediaSource {
        try Self.validateBasicURL(url)
        try await policy.validate(url)

        if let suppliedMIMEType {
            return ResolvedMediaSource(
                originalURL: url,
                resolvedURL: url,
                kind: Self.classify(url: url, mimeType: suppliedMIMEType),
                mimeType: suppliedMIMEType.normalizedMIMEType
            )
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "HEAD"
        request.setValue("OmniCast/1.0", forHTTPHeaderField: "User-Agent")

        let redirectDelegate = RedirectGuard(policy: policy)
        let session = URLSession(
            configuration: Self.makeSessionConfiguration(),
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MediaSourceError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw MediaSourceError.httpStatus(http.statusCode) }
            let resolved = http.url ?? url
            try Self.validateBasicURL(resolved)
            try await policy.validate(resolved)
            let mime = http.mimeType?.normalizedMIMEType
            return ResolvedMediaSource(
                originalURL: url,
                resolvedURL: resolved,
                kind: Self.classify(url: resolved, mimeType: mime),
                mimeType: mime
            )
        } catch let error as MediaSourceError {
            throw error
        } catch let error as NetworkPolicyError {
            throw error
        } catch {
            // Many CDNs reject HEAD. Extension-based classification is a safe fallback;
            // AVPlayer/WebKit will still surface the eventual transport error.
            return ResolvedMediaSource(
                originalURL: url,
                resolvedURL: url,
                kind: Self.classify(url: url, mimeType: nil),
                mimeType: nil
            )
        }
    }

    static func classify(url: URL, mimeType: String?) -> MediaSourceKind {
        let mime = mimeType?.normalizedMIMEType ?? ""
        if ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl"].contains(mime) {
            return .nativeHLS
        }
        if ["application/dash+xml", "video/vnd.mpeg.dash.mpd"].contains(mime) {
            return .dashManifest
        }
        if mime.hasPrefix("audio/") { return .nativeAudio }
        if mime.hasPrefix("video/") { return .nativeFile }
        if mime == "text/html" || mime == "application/xhtml+xml" { return .webPage }

        switch url.pathExtension.lowercased() {
        case "m3u8": return .nativeHLS
        case "mp4", "m4v", "mov": return .nativeFile
        case "mp3", "m4a", "aac", "wav", "aiff", "flac": return .nativeAudio
        case "mpd": return .dashManifest
        default: return .webPage
        }
    }

    static func validateBasicURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw MediaSourceError.unsupportedScheme
        }
        guard let host = url.host, !host.isEmpty else { throw MediaSourceError.missingHost }
    }

    private static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: NetworkSecurityPolicy
    private let lock = NSLock()
    private var redirects = 0

    init(policy: NetworkSecurityPolicy) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirects += 1
        let count = redirects
        lock.unlock()
        guard count <= 5, let url = request.url else {
            completionHandler(nil)
            return
        }
        Task {
            do {
                try await policy.validate(url)
                completionHandler(request)
            } catch {
                completionHandler(nil)
            }
        }
    }
}

private extension String {
    var normalizedMIMEType: String {
        split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? lowercased()
    }
}
