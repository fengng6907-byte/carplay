import Darwin
import Foundation

struct NetworkSecurityPolicy: Sendable {
    var allowsPrivateAddresses: Bool
    var allowsInsecureHTTP: Bool

    static let publicInternet = NetworkSecurityPolicy(
        allowsPrivateAddresses: false,
        allowsInsecureHTTP: false
    )

    static let userApprovedLocalNetwork = NetworkSecurityPolicy(
        allowsPrivateAddresses: true,
        allowsInsecureHTTP: true
    )

    func validate(_ url: URL) async throws {
        try validateWithoutDNS(url)
        guard !allowsPrivateAddresses, let host = url.host else { return }
        let addresses = await Task.detached(priority: .utility) {
            Self.resolve(host: host)
        }.value
        guard !addresses.isEmpty else { throw NetworkPolicyError.hostCouldNotBeResolved }
        if addresses.contains(where: Self.isRestrictedAddress) {
            throw NetworkPolicyError.privateAddressDenied
        }
    }

    func validateWithoutDNS(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= 4_096 else { throw NetworkPolicyError.urlTooLong }
        guard url.user == nil, url.password == nil else { throw NetworkPolicyError.embeddedCredentialsDenied }
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            throw NetworkPolicyError.unsupportedScheme
        }
        if scheme == "http", !allowsInsecureHTTP { throw NetworkPolicyError.insecureHTTPDenied }
        guard let host = url.host?.lowercased(), !host.isEmpty else { throw NetworkPolicyError.missingHost }
        if !allowsPrivateAddresses {
            if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
                throw NetworkPolicyError.privateAddressDenied
            }
            if Self.isRestrictedAddress(host) { throw NetworkPolicyError.privateAddressDenied }
        }
    }

    private static func resolve(host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var values: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let current = pointer {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                values.append(String(cString: buffer))
            }
            pointer = current.pointee.ai_next
        }
        return values
    }

    static func isRestrictedAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let first = UInt8((value >> 24) & 0xff)
            let second = UInt8((value >> 16) & 0xff)
            if first == 0 || first == 10 || first == 127 || first >= 224 { return true }
            if first == 100 && (64...127).contains(second) { return true }
            if first == 169 && second == 254 { return true }
            if first == 172 && (16...31).contains(second) { return true }
            if first == 192 && second == 168 { return true }
            if first == 198 && (second == 18 || second == 19) { return true }
            return false
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { bytes in
                let values = Array(bytes)
                let loopback = values.dropLast().allSatisfy { $0 == 0 } && values.last == 1
                let unspecified = values.allSatisfy { $0 == 0 }
                let uniqueLocal = values.first.map { ($0 & 0xfe) == 0xfc } ?? false
                let linkLocal = values.count > 1 && values[0] == 0xfe && (values[1] & 0xc0) == 0x80
                let multicast = values.first == 0xff
                return loopback || unspecified || uniqueLocal || linkLocal || multicast
            }
        }
        return false
    }
}

enum NetworkPolicyError: LocalizedError, Equatable {
    case unsupportedScheme
    case missingHost
    case insecureHTTPDenied
    case embeddedCredentialsDenied
    case privateAddressDenied
    case hostCouldNotBeResolved
    case urlTooLong

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme: return "Only HTTP and HTTPS URLs are supported."
        case .missingHost: return "The URL does not contain a host."
        case .insecureHTTPDenied: return "Unencrypted HTTP is disabled."
        case .embeddedCredentialsDenied: return "URLs containing embedded credentials are not accepted."
        case .privateAddressDenied: return "This address is not allowed by the current network policy."
        case .hostCouldNotBeResolved: return "The host could not be resolved safely."
        case .urlTooLong: return "The URL is too long."
        }
    }
}
