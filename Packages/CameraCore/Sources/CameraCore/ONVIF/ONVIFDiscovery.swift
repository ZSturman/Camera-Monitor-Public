import Darwin
import Foundation

/// ONVIF WS-Discovery: a multicast Probe for NetworkVideoTransmitter
/// devices on the local network (UDP 239.255.255.250:3702). Discovery is
/// a convenience; any camera can also be added by address. iOS requires
/// Apple's multicast networking entitlement for this, so on iPhone/iPad it
/// reports `.unavailable` unless the build has it.
public enum ONVIFDiscovery {
    public struct Device: Hashable, Sendable, Identifiable {
        public var id: String { endpoint }
        /// The WS-Addressing endpoint reference (stable device ID).
        public var endpoint: String
        public var serviceURLs: [URL]
        public var name: String?
        public var hardware: String?

        public var host: String? { serviceURLs.first?.host }
    }

    public enum DiscoveryError: Error, LocalizedError, Equatable {
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case let .unavailable(reason): reason
            }
        }
    }

    static let multicastAddress = "239.255.255.250"
    static let port: UInt16 = 3702

    static func probeMessage(id: UUID = UUID()) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:\(id.uuidString.lowercased())</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>
        """
    }

    /// Parses one ProbeMatches reply.
    static func parse(_ data: Data) -> [Device] {
        guard let xml = SOAPNode.parse(data) else { return [] }
        return xml.all("ProbeMatch").compactMap { match in
            let endpoint = match.first("EndpointReference")?.first("Address")?.text ?? UUID().uuidString
            let urls = (match.first("XAddrs")?.text ?? "").split(separator: " ").compactMap { URL(string: String($0)) }
            guard !urls.isEmpty else { return nil }
            let scopes = (match.first("Scopes")?.text ?? "").split(separator: " ").map(String.init)
            func scope(_ key: String) -> String? {
                scopes.first { $0.contains("/\(key)/") }.flatMap { $0.components(separatedBy: "/\(key)/").last?.removingPercentEncoding }
            }
            return Device(endpoint: endpoint, serviceURLs: urls, name: scope("name"), hardware: scope("hardware"))
        }
    }

    /// Sends the probe twice and collects replies for `duration` seconds.
    public static func discover(duration: TimeInterval = 3) async throws -> [Device] {
        try await Task.detached(priority: .userInitiated) { try probe(duration: duration) }.value
    }

    static func probe(duration: TimeInterval) throws -> [Device] {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw DiscoveryError.unavailable("Couldn't open a network socket for discovery.") }
        defer { close(socketFD) }
        var ttl: UInt8 = 2
        setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        inet_pton(AF_INET, multicastAddress, &destination.sin_addr)

        let message = Array(probeMessage().utf8)
        var sentAny = false
        var lastError: Int32 = 0
        for _ in 0..<2 {
            let sent = withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socketFD, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if sent >= 0 { sentAny = true } else { lastError = errno }
        }
        guard sentAny else {
            #if os(iOS)
            throw DiscoveryError.unavailable("This build can't send local-network discovery messages on iOS (it needs Apple's multicast entitlement). Add the camera by its address instead.")
            #else
            throw DiscoveryError.unavailable("Discovery couldn't send on the local network (\(String(cString: strerror(lastError)))).")
            #endif
        }

        var devices: [String: Device] = [:]
        let deadline = Date().addingTimeInterval(duration)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let count = recv(socketFD, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            for device in parse(Data(buffer[0..<count])) {
                devices[device.endpoint] = devices[device.endpoint] ?? device
            }
        }
        return devices.values.sorted { ($0.host ?? "") < ($1.host ?? "") }
    }
}
