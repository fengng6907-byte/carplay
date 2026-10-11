import Foundation
import Combine
import Security

@MainActor
final class ReceiverController: ObservableObject {
    static let shared = ReceiverController()

    @Published var lanEnabled: Bool {
        didSet { defaults.set(lanEnabled, forKey: Keys.lanEnabled); restart() }
    }
    @Published var dlnaCompatibilityEnabled: Bool {
        didSet { defaults.set(dlnaCompatibilityEnabled, forKey: Keys.dlnaCompatibility); restart() }
    }
    @Published private(set) var status: DLNAReceiverService.Status = .stopped
    @Published private(set) var apiToken: String

    var statusText: String {
        switch status {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case let .waiting(message): return "Waiting: \(message)"
        case let .running(port): return "Listening on port \(port)"
        case let .failed(message): return message
        }
    }

    private enum Keys {
        static let lanEnabled = "OmniCast.Receiver.LANEnabled"
        static let dlnaCompatibility = "OmniCast.Receiver.DLNACompatibility"
    }

    private let defaults: UserDefaults
    private let service: DLNAReceiverService

    init(defaults: UserDefaults = .standard, service: DLNAReceiverService = .shared) {
        self.defaults = defaults
        self.service = service
        self.lanEnabled = defaults.bool(forKey: Keys.lanEnabled)
        self.dlnaCompatibilityEnabled = defaults.bool(forKey: Keys.dlnaCompatibility)
        self.apiToken = Self.loadOrCreateToken()
        service.setStatusHandler { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        restart()
    }

    func restart() {
        service.stop()
        let exposure: DLNAReceiverService.Exposure = lanEnabled ? .localNetwork : .loopbackOnly
        service.start(configuration: .init(
            exposure: exposure,
            preferredPort: 49_152,
            apiToken: apiToken,
            dlnaCompatibilityEnabled: lanEnabled && dlnaCompatibilityEnabled
        ))
    }

    func rotateToken() {
        apiToken = Self.generateToken()
        Self.storeToken(apiToken)
        restart()
    }

    private static let keychainService = "com.omnicast.receiver"
    private static let keychainAccount = "lan-api-token"

    private static func loadOrCreateToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return token
        }
        let token = generateToken()
        storeToken(token)
        return token
    }

    private static func storeToken(_ token: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(identity as CFDictionary)
        var item = identity
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
