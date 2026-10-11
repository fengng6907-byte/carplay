import XCTest
@testable import OmniCast

final class NetworkSecurityTests: XCTestCase {
    func testPublicPolicyRejectsUnsafeDestinations() {
        let policy = NetworkSecurityPolicy.publicInternet
        XCTAssertThrowsError(try policy.validateWithoutDNS(URL(string: "http://example.com/video.mp4")!)) {
            XCTAssertEqual($0 as? NetworkPolicyError, .insecureHTTPDenied)
        }
        XCTAssertThrowsError(try policy.validateWithoutDNS(URL(string: "https://127.0.0.1/video.mp4")!)) {
            XCTAssertEqual($0 as? NetworkPolicyError, .privateAddressDenied)
        }
        XCTAssertThrowsError(try policy.validateWithoutDNS(URL(string: "https://192.168.1.20/video.mp4")!)) {
            XCTAssertEqual($0 as? NetworkPolicyError, .privateAddressDenied)
        }
        XCTAssertThrowsError(try policy.validateWithoutDNS(URL(string: "https://user:password@example.com/video.mp4")!)) {
            XCTAssertEqual($0 as? NetworkPolicyError, .embeddedCredentialsDenied)
        }
        XCTAssertNoThrow(try policy.validateWithoutDNS(URL(string: "https://example.com/video.mp4")!))
    }

    func testUserApprovedLocalPolicyAllowsLocalHTTP() {
        XCTAssertNoThrow(try NetworkSecurityPolicy.userApprovedLocalNetwork.validateWithoutDNS(
            URL(string: "http://192.168.1.20/video.mp4")!
        ))
    }

    func testHTTPRequestParsingAndBodyLimits() {
        let request = makeRequest(headers: ["Authorization": "Bearer secret"], body: Data("{}".utf8))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/cast")
        XCTAssertEqual(request?.headers["authorization"], "Bearer secret")
        XCTAssertEqual(request?.body, Data("{}".utf8))

        let oversizedHeader = Data(("POST /cast HTTP/1.1\r\nContent-Length: \(HTTPRequest.maximumBodyBytes + 1)\r\n\r\n").utf8)
        XCTAssertEqual(
            HTTPRequest.declaredContentLength(in: oversizedHeader),
            HTTPRequest.maximumBodyBytes + 1
        )
        XCTAssertNil(HTTPRequest(data: oversizedHeader))
    }

    func testLANAuthenticationAndLoopbackException() {
        let authorized = makeRequest(headers: ["Authorization": "Bearer secret"], body: Data())!
        let unauthorized = makeRequest(headers: [:], body: Data())!
        XCTAssertTrue(DLNAReceiverService.isAuthorized(request: authorized, token: "secret", isLoopback: false))
        XCTAssertFalse(DLNAReceiverService.isAuthorized(request: unauthorized, token: "secret", isLoopback: false))
        XCTAssertFalse(DLNAReceiverService.isAuthorized(request: authorized, token: "different", isLoopback: false))
        XCTAssertTrue(DLNAReceiverService.isAuthorized(request: unauthorized, token: "", isLoopback: true))
    }

    func testRequestBudget() {
        var budget = RequestBudget(maximumRequests: 2, window: 60)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(budget.allow(client: "client", now: now))
        XCTAssertTrue(budget.allow(client: "client", now: now))
        XCTAssertFalse(budget.allow(client: "client", now: now))
        XCTAssertTrue(budget.allow(client: "client", now: now.addingTimeInterval(61)))
    }

    private func makeRequest(headers: [String: String], body: Data) -> HTTPRequest? {
        var value = "POST /cast HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n"
        headers.forEach { value += "\($0.key): \($0.value)\r\n" }
        value += "\r\n"
        var data = Data(value.utf8)
        data.append(body)
        return HTTPRequest(data: data)
    }
}
