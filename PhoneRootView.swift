import AVKit
import SwiftUI
import UIKit

struct PhoneRootView: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        TabView {
            HomeScreen()
                .tabItem { Label("Home", systemImage: "house.fill") }
            CastScreen()
                .tabItem { Label("Cast", systemImage: "dot.radiowaves.left.and.right") }
            LibraryScreen()
                .tabItem { Label("Library", systemImage: "rectangle.stack.fill") }
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.route != .idle { MiniPlayerView() }
        }
    }
}

private struct HomeScreen: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: MediaLibraryStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    PlayerSurface()
                    PlaybackStatusCard()

                    if !library.recentEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recently played").font(.headline)
                            ForEach(library.recentEntries.prefix(5)) { entry in
                                MediaEntryButton(entry: entry)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("OmniCast")
        }
    }
}

private struct PlayerSurface: View {
    @EnvironmentObject private var player: PlayerManager
    @AppStorage("OmniCast.DrivingSafetyEnabled") private var drivingSafetyEnabled = false
    @StateObject private var safety = DrivingSafetyMonitor()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)

            switch player.route {
            case .idle:
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 44))
                    Text("Open a media URL from Cast or Library")
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding()
            case .native:
                VideoPlayer(player: player.player)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            case let .web(url):
                OmniCastWebView(
                    url: url,
                    interactionAllowed: !drivingSafetyEnabled || !safety.restrictsTouchInput
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if player.state == .loading || player.state == .buffering {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(player.state == .buffering ? "Buffering…" : "Loading…")
                        .foregroundStyle(.white)
                }
                .padding(18)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }

            if case let .failed(message, retryable) = player.state {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message).multilineTextAlignment(.center)
                    if retryable { Button("Retry", action: player.retry).buttonStyle(.borderedProminent) }
                }
                .foregroundStyle(.white)
                .padding()
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                .padding()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityLabel("Media player")
        .onAppear { if drivingSafetyEnabled { safety.start() } }
        .onDisappear { safety.stop() }
        .onChange(of: drivingSafetyEnabled) { enabled in enabled ? safety.start() : safety.stop() }
    }
}

private struct PlaybackStatusCard: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.title).font(.headline).lineLimit(2)
                    Label(player.snapshot.destination.displayName, systemImage: "airplayvideo")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(player.state.shortLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }

            if player.duration > 0 {
                ProgressView(value: min(player.elapsed, player.duration), total: player.duration)
                    .accessibilityValue("\(Int(player.elapsed)) of \(Int(player.duration)) seconds")
            }

            HStack {
                Button { player.skip(by: -10) } label: { Label("Back 10", systemImage: "gobackward.10") }
                Spacer()
                Button { player.togglePlayback() } label: {
                    Label(
                        player.state == .playing ? "Pause" : "Play",
                        systemImage: player.state == .playing ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button { player.skip(by: 10) } label: { Label("Forward 10", systemImage: "goforward.10") }
            }
            .labelStyle(.iconOnly)
            .font(.title2)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct CastScreen: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: MediaLibraryStore
    @EnvironmentObject private var receiver: ReceiverController
    @AppStorage("OmniCast.AllowLocalSources") private var allowsLocalSources = false
    @State private var urlText = ""
    @State private var titleText = ""
    @State private var validationMessage: String?
    @State private var isValidating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Media") {
                    TextField("Title (optional)", text: $titleText)
                    TextField("https://example.com/video.m3u8", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Media URL")
                    Button { validateAndPlay() } label: {
                        if isValidating { ProgressView() } else { Label("Validate and Play", systemImage: "play.fill") }
                    }
                    .disabled(isValidating || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section("Receiver") {
                    LabeledContent("Status", value: receiver.statusText)
                    LabeledContent("LAN access", value: receiver.lanEnabled ? "Enabled" : "Off")
                    Text("Loopback casting remains available on this iPhone. LAN access must be enabled in Settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cast")
        }
    }

    private func validateAndPlay() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else {
            validationMessage = "Enter a valid URL."
            return
        }
        isValidating = true
        validationMessage = nil
        let policy: NetworkSecurityPolicy = allowsLocalSources
            ? .userApprovedLocalNetwork
            : .publicInternet
        Task {
            do {
                try await policy.validate(url)
                await MainActor.run {
                    let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
                    library.record(url: url, title: title.isEmpty ? nil : title)
                    player.load(
                        url,
                        title: title.isEmpty ? nil : title,
                        allowsLocalNetworkSource: allowsLocalSources
                    )
                    isValidating = false
                }
            } catch {
                await MainActor.run {
                    validationMessage = error.localizedDescription
                    isValidating = false
                }
            }
        }
    }
}

private struct LibraryScreen: View {
    @EnvironmentObject private var library: MediaLibraryStore

    var body: some View {
        NavigationStack {
            List {
                if !library.savedEntries.isEmpty {
                    Section("Saved") {
                        ForEach(library.savedEntries) { entry in MediaEntryRow(entry: entry) }
                    }
                }
                Section("Recent") {
                    if library.recentEntries.isEmpty {
                        Text("Played media appears here.").foregroundStyle(.secondary)
                    } else {
                        ForEach(library.recentEntries) { entry in MediaEntryRow(entry: entry) }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                if !library.recentEntries.isEmpty {
                    Button("Clear", role: .destructive, action: library.clearRecents)
                }
            }
        }
    }
}

private struct MediaEntryRow: View {
    @EnvironmentObject private var library: MediaLibraryStore
    let entry: MediaLibraryEntry

    var body: some View {
        MediaEntryButton(entry: entry)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { library.remove(entry) } label: { Label("Delete", systemImage: "trash") }
                Button { library.setSaved(!entry.isSaved, for: entry) } label: {
                    Label(entry.isSaved ? "Unsave" : "Save", systemImage: entry.isSaved ? "bookmark.slash" : "bookmark")
                }
                .tint(.blue)
            }
    }
}

private struct MediaEntryButton: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: MediaLibraryStore
    @AppStorage("OmniCast.AllowLocalSources") private var allowsLocalSources = false
    let entry: MediaLibraryEntry

    var body: some View {
        Button {
            library.record(url: entry.url, title: entry.title, mimeType: entry.mimeType)
            player.load(
                entry.url,
                title: entry.title,
                mimeType: entry.mimeType,
                allowsLocalNetworkSource: allowsLocalSources
            )
        } label: {
            HStack {
                Image(systemName: entry.isSaved ? "bookmark.fill" : "play.rectangle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(entry.title).foregroundStyle(.primary).lineLimit(1)
                    Text(entry.url.host ?? entry.url.absoluteString)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays this media")
    }
}

private struct SettingsScreen: View {
    @EnvironmentObject private var receiver: ReceiverController
    @AppStorage("OmniCast.AllowLocalSources") private var allowsLocalSources = false
    @AppStorage("OmniCast.DrivingSafetyEnabled") private var drivingSafetyEnabled = false
    @State private var revealsToken = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Network receiver") {
                    Toggle("Allow LAN receiver", isOn: $receiver.lanEnabled)
                    Toggle("DLNA compatibility mode", isOn: $receiver.dlnaCompatibilityEnabled)
                        .disabled(!receiver.lanEnabled)
                    LabeledContent("Status", value: receiver.statusText)
                    Text("LAN access is off by default. DLNA discovery is advertised only when both options are enabled.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("LAN API credential") {
                    if revealsToken {
                        Text(receiver.apiToken).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button(revealsToken ? "Hide token" : "Reveal token") { revealsToken.toggle() }
                    Button("Copy token") { UIPasteboard.general.string = receiver.apiToken }
                    Button("Rotate token", role: .destructive, action: receiver.rotateToken)
                    Text("LAN requests to /cast and /health require Authorization: Bearer <token>.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Playback safety") {
                    Toggle("Allow explicitly configured local HTTP sources", isOn: $allowsLocalSources)
                    Toggle("Restrict web controls while moving", isOn: $drivingSafetyEnabled)
                    Text("CarPlay and the vehicle remain authoritative for driver-distraction restrictions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Compatibility") {
                    LabeledContent("Native", value: "HLS, MP4, MOV, audio")
                    LabeledContent("Web", value: "Site-dependent")
                    Text("OmniCast does not bypass DRM and cannot guarantee arbitrary website, DASH, or WebRTC playback.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(player.state.shortLabel) · \(player.snapshot.destination.displayName)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { player.togglePlayback() } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
            Button(action: player.stop) {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Stop and close player")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private extension PlaybackPhase {
    var shortLabel: String {
        switch self {
        case .idle: return "Idle"
        case .loading: return "Loading"
        case .buffering: return "Buffering"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .ended: return "Ended"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Error"
        }
    }
}
