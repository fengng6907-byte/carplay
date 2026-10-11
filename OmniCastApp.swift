import SwiftUI

@main
struct OmniCastApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var library = MediaLibraryStore.shared
    @StateObject private var receiver = ReceiverController.shared

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(receiver)
        }
    }
}
