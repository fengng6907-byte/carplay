import Foundation
import Network
import Darwin

/// Lightweight UPnP AVTransport/Digital Media Renderer.
///
/// The process-wide service is owned by ReceiverController, not by a view controller or
/// CarPlay session. Loopback is always available; LAN exposure and SSDP require explicit
/// user opt-in. Multicast discovery also needs Apple's multicast entitlement on device.
final class DLNAReceiverService: @unchecked Sendable {
    static let shared = DLNAReceiverService()

    enum Status: Sendable, Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    enum Exposure: Sendable {
        case loopbackOnly
        case localNetwork
    }

    struct Configuration: Sendable {
        var exposure: Exposure = .loopbackOnly
        var preferredPort: UInt16 = 49_152
        var apiToken: String = ""
        var dlnaCompatibilityEnabled = false
    }

    struct MediaMetadata: Sendable, Equatable {
        var title: String?
        var creator: String?
        var mimeType: String?
        var duration: String?
        var artworkURL: URL?
    }

    private let queue = DispatchQueue(label: "com.omnicast.dlna", qos: .userInitiated)
    private var httpListener: NWListener?
    private var ssdpGroup: NWConnectionGroup?
    private var aliveTimer: DispatchSourceTimer?
    private var running = false
    private var configuration = Configuration()
    private var boundPort: UInt16 = 0
    private var status: Status = .stopped
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var requestBudget = RequestBudget()
    private let deviceUUID: String

    private init() {
        let key = "OmniCast.DLNA.DeviceUUID"
        if let saved = UserDefaults.standard.string(forKey: key) {
            deviceUUID = saved
        } else {
            let created = UUID().uuidString.lowercased()
            UserDefaults.standard.set(created, forKey: key)
            deviceUUID = created
        }
    }

    var statusSummary: String {
        queue.sync {
            guard running else { return "Stopped" }
            let port = boundPort > 0 ? boundPort : configuration.preferredPort
            return "http://127.0.0.1:\(port)/cast"
        }
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.statusHandler = handler
            handler(self.status)
        }
    }

    func start(configuration: Configuration = .init()) {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.configuration = configuration
            self.updateStatus(.starting)
            self.startHTTPListener(port: configuration.preferredPort)
            if configuration.exposure == .localNetwork && configuration.dlnaCompatibilityEnabled {
                self.startSSDPListener()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            if self.configuration.exposure == .localNetwork && self.configuration.dlnaCompatibilityEnabled {
                self.sendSSDP(alive: false)
            }
            self.running = false
            self.httpListener?.cancel()
            self.ssdpGroup?.cancel()
            self.aliveTimer?.cancel()
            self.httpListener = nil
            self.ssdpGroup = nil
            self.aliveTimer = nil
            self.boundPort = 0
            self.updateStatus(.stopped)
        }
    }

    // MARK: HTTP transport

    private func startHTTPListener(port: UInt16) {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let nwPort: NWEndpoint.Port
            if port == 0 {
                nwPort = .any
            } else if let requested = NWEndpoint.Port(rawValue: port) {
                nwPort = requested
            } else {
                throw ReceiverError.invalidPort
            }
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in self?.acceptHTTP(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.boundPort = listener.port?.rawValue ?? port
                    self.updateStatus(.running(port: self.boundPort))
                    if self.configuration.exposure == .localNetwork && self.configuration.dlnaCompatibilityEnabled {
                        self.sendSSDP(alive: true)
                        self.scheduleAliveAnnouncements()
                    }
                case .failed:
                    listener.cancel()
                    if port != 0 {
                        self.startHTTPListener(port: 0)
                    } else {
                        self.running = false
                        self.updateStatus(.failed("The receiver could not bind a local port."))
                    }
                default:
                    break
                }
            }
            httpListener = listener
            listener.start(queue: queue)
        } catch {
            running = false
            updateStatus(.failed(error.localizedDescription))
        }
    }

    private func acceptHTTP(_ connection: NWConnection) {
        // In loopback mode, reject non-loopback peers even though the TCP listener binds
        // all local interfaces (NWListener has no public bind-to-127.0.0.1-only switch).
        let isLoopback = connection.endpoint.isLoopback
        if configuration.exposure == .loopbackOnly, !isLoopback {
            connection.cancel()
            return
        }

        connection.start(queue: queue)
        let clientKey = "\(connection.endpoint)"
        guard requestBudget.allow(client: clientKey, now: .now) else {
            send(.tooManyRequests, on: connection)
            return
        }
        receiveHTTP(on: connection, buffer: Data(), isLoopback: isLoopback)
    }

    private func receiveHTTP(on connection: NWConnection, buffer: Data, isLoopback: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if accumulated.count > HTTPRequest.maximumRequestBytes {
                self.send(.payloadTooLarge, on: connection)
            } else if let declaredLength = HTTPRequest.declaredContentLength(in: accumulated),
                      declaredLength > HTTPRequest.maximumBodyBytes {
                self.send(.payloadTooLarge, on: connection)
            } else if let request = HTTPRequest(data: accumulated) {
                self.handle(request, on: connection, isLoopback: isLoopback)
            } else if isComplete || error != nil {
                self.send(.badRequest("Malformed request"), on: connection)
            } else {
                self.receiveHTTP(on: connection, buffer: accumulated, isLoopback: isLoopback)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection, isLoopback: Bool) {
        let cleanPath = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path

        if ["/cast", "/health"].contains(cleanPath),
           !Self.isAuthorized(request: request, token: configuration.apiToken, isLoopback: isLoopback) {
            send(.unauthorized, on: connection)
            return
        }

        switch (request.method, cleanPath) {
        case ("GET", "/description.xml") where configuration.dlnaCompatibilityEnabled:
            send(.xml(deviceDescription), on: connection)
        case ("GET", "/AVTransport/scpd.xml") where configuration.dlnaCompatibilityEnabled:
            send(.xml(Self.avTransportSCPD), on: connection)
        case ("POST", "/AVTransport/control") where configuration.dlnaCompatibilityEnabled:
            handleSOAP(request, on: connection)
        case ("SUBSCRIBE", "/AVTransport/event") where configuration.dlnaCompatibilityEnabled:
            let sid = request.headers["sid"] ?? "uuid:\(UUID().uuidString.lowercased())"
            send(HTTPResponse(status: 200, headers: ["SID": sid, "TIMEOUT": "Second-1800"], body: Data()), on: connection)
        case ("UNSUBSCRIBE", "/AVTransport/event") where configuration.dlnaCompatibilityEnabled:
            send(.emptyOK, on: connection)
        case ("GET", "/cast"):
            handleCastQuery(request, on: connection)
        case ("POST", "/cast"):
            handleCastJSON(request, on: connection)
        case ("GET", "/health"):
            send(.json(["status": "ok", "renderer": "OmniCast"]), on: connection)
        default:
            send(.notFound, on: connection)
        }
    }

    private func handleCastQuery(_ request: HTTPRequest, on connection: NWConnection) {
        guard let components = URLComponents(string: "http://localhost\(request.path)"),
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: value) else {
            send(.badRequest("Use /cast?url=https%3A%2F%2Fexample%2Fvideo.m3u8"), on: connection)
            return
        }
        handOff(url: url, metadata: nil)
        send(.json(["accepted": true]), on: connection)
    }

    private func handleCastJSON(_ request: HTTPRequest, on connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let value = object["url"] as? String,
              let url = URL(string: value) else {
            send(.badRequest("Expected JSON object containing a url"), on: connection)
            return
        }
        var metadata = MediaMetadata()
        metadata.title = object["title"] as? String
        handOff(url: url, metadata: metadata)
        send(.json(["accepted": true]), on: connection)
    }

    // MARK: UPnP AVTransport

    private func handleSOAP(_ request: HTTPRequest, on connection: NWConnection) {
        let actionHeader = request.headers["soapaction"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
        let action = actionHeader.split(separator: "#").last.map(String.init) ?? ""
        let values = SOAPValues(data: request.body).values

        switch action {
        case "SetAVTransportURI":
            guard let raw = values["CurrentURI"], let url = URL(string: raw) else {
                send(.soapFault(code: 714, description: "Illegal MIME-type or URI"), on: connection)
                return
            }
            let metadata = values["CurrentURIMetaData"].flatMap { DIDLMetadataParser.parse($0) }
            handOff(url: url, metadata: metadata)
            send(.soap(action: action, values: [:]), on: connection)
        case "Play":
            Task { @MainActor in PlayerManager.shared.play() }
            send(.soap(action: action, values: [:]), on: connection)
        case "Pause":
            Task { @MainActor in PlayerManager.shared.pause() }
            send(.soap(action: action, values: [:]), on: connection)
        case "Stop":
            Task { @MainActor in PlayerManager.shared.stop() }
            send(.soap(action: action, values: [:]), on: connection)
        case "Seek":
            guard let target = values["Target"], let seconds = Self.timeInterval(from: target) else {
                send(.soapFault(code: 711, description: "Illegal seek target"), on: connection)
                return
            }
            Task { @MainActor in PlayerManager.shared.seek(to: seconds) }
            send(.soap(action: action, values: [:]), on: connection)
        case "GetTransportInfo":
            Task { @MainActor [weak self] in
                guard let self else { return }
                let state = PlayerManager.shared.state == .playing ? "PLAYING" : "PAUSED_PLAYBACK"
                self.queue.async {
                    self.send(.soap(action: action, values: [
                        "CurrentTransportState": state,
                        "CurrentTransportStatus": "OK",
                        "CurrentSpeed": "1"
                    ]), on: connection)
                }
            }
        case "GetPositionInfo":
            Task { @MainActor [weak self] in
                guard let self else { return }
                let elapsed = Self.upnpTime(PlayerManager.shared.elapsed)
                let duration = Self.upnpTime(PlayerManager.shared.duration)
                self.queue.async {
                    self.send(.soap(action: action, values: [
                        "Track": "1", "TrackDuration": duration, "RelTime": elapsed,
                        "AbsTime": elapsed, "RelCount": "2147483647", "AbsCount": "2147483647"
                    ]), on: connection)
                }
            }
        default:
            send(.soapFault(code: 401, description: "Invalid Action"), on: connection)
        }
    }

    private func handOff(url: URL, metadata: MediaMetadata?) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor in
            PlayerManager.shared.load(
                url,
                title: metadata?.title,
                mimeType: metadata?.mimeType,
                allowsLocalNetworkSource: true,
                autoplay: true
            )
            MediaLibraryStore.shared.record(url: url, title: metadata?.title, mimeType: metadata?.mimeType)
        }
    }

    // MARK: SSDP discovery

    private func startSSDPListener() {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let endpoint = NWEndpoint.hostPort(host: "239.255.255.250", port: 1900)
            let descriptor = try NWMulticastGroup(for: [endpoint])
            let group = NWConnectionGroup(with: descriptor, using: parameters)
            group.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: true) { [weak self] message, data, _ in
                guard let self, let data,
                      let request = String(data: data, encoding: .utf8),
                      request.uppercased().hasPrefix("M-SEARCH") else { return }
                self.sendDiscoveryResponse(for: message)
            }
            ssdpGroup = group
            group.start(queue: queue)
        } catch {
            // HTTP loopback casting remains available if multicast is unavailable.
            ssdpGroup = nil
        }
    }

    private func sendDiscoveryResponse(for inboundMessage: NWConnectionGroup.Message) {
        let message = [
            "HTTP/1.1 200 OK",
            "CACHE-CONTROL: max-age=1800",
            "EXT:",
            "LOCATION: \(descriptionURL)",
            "SERVER: iOS/1.0 UPnP/1.1 OmniCast/1.0",
            "ST: urn:schemas-upnp-org:device:MediaRenderer:1",
            "USN: uuid:\(deviceUUID)::urn:schemas-upnp-org:device:MediaRenderer:1",
            "BOOTID.UPNP.ORG: 1",
            "CONFIGID.UPNP.ORG: 1", "", ""
        ].joined(separator: "\r\n")
        inboundMessage.reply(content: Data(message.utf8), message: .default)
    }

    private func sendSSDP(alive: Bool) {
        guard boundPort > 0 else { return }
        let notification = [
            "NOTIFY * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "CACHE-CONTROL: max-age=1800",
            "LOCATION: \(descriptionURL)",
            "NT: urn:schemas-upnp-org:device:MediaRenderer:1",
            "NTS: ssdp:\(alive ? "alive" : "byebye")",
            "SERVER: iOS/1.0 UPnP/1.1 OmniCast/1.0",
            "USN: uuid:\(deviceUUID)::urn:schemas-upnp-org:device:MediaRenderer:1", "", ""
        ].joined(separator: "\r\n")

        ssdpGroup?.send(content: Data(notification.utf8), message: .default) { _ in }
    }

    private func scheduleAliveAnnouncements() {
        aliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 900, repeating: 900)
        timer.setEventHandler { [weak self] in self?.sendSSDP(alive: true) }
        aliveTimer = timer
        timer.resume()
    }

    // MARK: Documents and helpers

    private var descriptionURL: String {
        "http://\(Self.localIPv4Address() ?? "127.0.0.1"):\(boundPort)/description.xml"
    }

    private var deviceDescription: String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <URLBase>http://\(Self.localIPv4Address() ?? "127.0.0.1"):\(boundPort)/</URLBase>
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
            <friendlyName>OmniCast</friendlyName>
            <manufacturer>OmniCast</manufacturer>
            <modelName>OmniCast iOS Renderer</modelName>
            <UDN>uuid:\(deviceUUID)</UDN>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
                <SCPDURL>/AVTransport/scpd.xml</SCPDURL>
                <controlURL>/AVTransport/control</controlURL>
                <eventSubURL>/AVTransport/event</eventSubURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
    }

    private static let avTransportSCPD = """
    <?xml version="1.0" encoding="utf-8"?>
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <actionList>
        <action><name>SetAVTransportURI</name></action><action><name>Play</name></action>
        <action><name>Pause</name></action><action><name>Stop</name></action>
        <action><name>Seek</name></action><action><name>GetTransportInfo</name></action>
        <action><name>GetPositionInfo</name></action>
      </actionList>
      <serviceStateTable/>
    </scpd>
    """

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.encoded, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func updateStatus(_ status: Status) {
        self.status = status
        statusHandler?(status)
    }

    static func isAuthorized(request: HTTPRequest, token: String, isLoopback: Bool) -> Bool {
        if isLoopback { return true }
        guard !token.isEmpty,
              let authorization = request.headers["authorization"],
              authorization.lowercased().hasPrefix("bearer ") else { return false }
        let supplied = String(authorization.dropFirst(7))
        return supplied.constantTimeEquals(token)
    }

    private static func timeInterval(from value: String) -> TimeInterval? {
        let components = value.split(separator: ":").compactMap(Double.init)
        guard components.count == 3 else { return nil }
        return components[0] * 3600 + components[1] * 60 + components[2]
    }

    private static func upnpTime(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.finiteOrZero))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 { return String(cString: host) }
        }
        return nil
    }

    private enum ReceiverError: Error { case invalidPort }
}

struct HTTPRequest {
    static let maximumHeaderBytes = 32 * 1_024
    static let maximumBodyBytes = 256 * 1_024
    static let maximumRequestBytes = maximumHeaderBytes + maximumBodyBytes

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func declaredContentLength(in data: Data) -> Int? {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: marker), range.lowerBound <= maximumHeaderBytes,
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "content-length" {
                return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return 0
    }

    init?(data: Data) {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: marker),
              range.lowerBound <= Self.maximumHeaderBytes,
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        method = String(first[0]).uppercased()
        path = String(first[1])
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            parsed[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        headers = parsed
        let bodyStart = range.upperBound
        let expected = Int(parsed["content-length"] ?? "0") ?? 0
        guard expected <= Self.maximumBodyBytes else { return nil }
        guard data.distance(from: bodyStart, to: data.endIndex) >= expected else { return nil }
        body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: expected)])
    }
}

private struct HTTPResponse {
    let status: Int
    var headers: [String: String]
    let body: Data

    var encoded: Data {
        let reason = [
            200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
            413: "Payload Too Large", 429: "Too Many Requests", 500: "Internal Server Error"
        ][status] ?? "OK"
        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in fields { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static var emptyOK: HTTPResponse { .init(status: 200, headers: [:], body: Data()) }
    static var notFound: HTTPResponse { .init(status: 404, headers: [:], body: Data()) }
    static var unauthorized: HTTPResponse {
        .init(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"OmniCast\""], body: Data())
    }
    static var payloadTooLarge: HTTPResponse { .init(status: 413, headers: [:], body: Data()) }
    static var tooManyRequests: HTTPResponse {
        .init(status: 429, headers: ["Retry-After": "60"], body: Data())
    }
    static func badRequest(_ message: String) -> HTTPResponse {
        .init(status: 400, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(message.utf8))
    }
    static func xml(_ value: String) -> HTTPResponse {
        .init(status: 200, headers: ["Content-Type": "text/xml; charset=utf-8"], body: Data(value.utf8))
    }
    static func json(_ object: [String: Any]) -> HTTPResponse {
        .init(status: 200, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
    static func soap(action: String, values: [String: String]) -> HTTPResponse {
        let fields = values.map { "<\($0.key)>\($0.value.xmlEscaped)</\($0.key)>" }.joined()
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\(fields)</u:\(action)Response></s:Body>
        </s:Envelope>
        """
        return .xml(envelope)
    }
    static func soapFault(code: Int, description: String) -> HTTPResponse {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>
          <faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>
          <UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode><errorDescription>\(description.xmlEscaped)</errorDescription></UPnPError>
          </detail></s:Fault></s:Body></s:Envelope>
        """
        return .init(status: 500, headers: ["Content-Type": "text/xml; charset=utf-8"], body: Data(envelope.utf8))
    }
}

private final class SOAPValues: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var element = ""
    private var text = ""

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        element = elementName.split(separator: ":").last.map(String.init) ?? elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == element { values[name] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private final class DIDLMetadataParser: NSObject, XMLParserDelegate {
    private var metadata = DLNAReceiverService.MediaMetadata()
    private var current = ""
    private var text = ""

    static func parse(_ xml: String) -> DLNAReceiverService.MediaMetadata? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = DIDLMetadataParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.metadata
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        current = elementName.split(separator: ":").last.map(String.init) ?? elementName
        text = ""
        if current == "res" {
            metadata.mimeType = attributeDict["protocolInfo"]?.split(separator: ":").dropFirst(2).first.map(String.init)
            metadata.duration = attributeDict["duration"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "title" { metadata.title = value }
        if name == "creator" { metadata.creator = value }
        if name == "albumArtURI" { metadata.artworkURL = URL(string: value) }
    }
}

private extension NWEndpoint {
    var isLoopback: Bool {
        guard case let .hostPort(host, _) = self else { return false }
        let value = "\(host)".lowercased()
        return value == "127.0.0.1" || value == "::1" || value == "localhost"
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    func constantTimeEquals(_ other: String) -> Bool {
        let lhs = Array(utf8)
        let rhs = Array(other.utf8)
        var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}

struct RequestBudget {
    var maximumRequests = 60
    var window: TimeInterval = 60
    private var requests: [String: [Date]] = [:]

    init(maximumRequests: Int = 60, window: TimeInterval = 60) {
        self.maximumRequests = maximumRequests
        self.window = window
    }

    mutating func allow(client: String, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        var recent = requests[client, default: []].filter { $0 >= cutoff }
        guard recent.count < maximumRequests else {
            requests[client] = recent
            return false
        }
        recent.append(now)
        requests[client] = recent
        if requests.count > 256 {
            requests = requests.filter { $0.value.last.map { $0 >= cutoff } ?? false }
        }
        return true
    }
}
