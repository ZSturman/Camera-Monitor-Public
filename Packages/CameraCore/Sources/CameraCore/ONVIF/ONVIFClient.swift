import CryptoKit
import Foundation

/// The small part of ONVIF Camera Monitor uses: device information, media
/// profiles, stream and snapshot URIs (Profile S). Requests carry a
/// WS-Security UsernameToken with a password digest; cameras that insist
/// on HTTP Digest are answered through the origin-scoped HTTP client.
/// ONVIF finds and describes streams; video still plays over RTSP.
struct ONVIFClient: Sendable {
    let deviceURL: URL
    let credential: ConnectionCredential?
    let configuration: URLSessionConfiguration
    /// Camera clock offset, so the WS-Security timestamp is accepted by
    /// cameras whose time is wrong.
    var clockOffset: TimeInterval = 0

    struct DeviceInfo: Equatable, Sendable {
        var manufacturer: String?
        var model: String?
        var firmware: String?
        var serial: String?
    }

    struct Profile: Equatable, Sendable {
        var token: String
        var name: String
        var encoding: String?
        var width: Int?
        var height: Int?
        var frameRate: Double?

        var summary: String {
            var parts = [name]
            if let encoding { parts.append(encoding) }
            if let width, let height { parts.append("\(width)×\(height)") }
            if let frameRate, frameRate > 0 { parts.append("\(Int(frameRate)) fps") }
            return parts.joined(separator: " · ")
        }

        var isPlayable: Bool {
            guard let encoding = encoding?.uppercased() else { return true }
            return encoding.contains("H264") || encoding.contains("H265") || encoding.contains("HEVC")
        }
    }

    static let deviceNS = "http://www.onvif.org/ver10/device/wsdl"
    static let mediaNS = "http://www.onvif.org/ver10/media/wsdl"

    // MARK: Operations

    func systemTime() async throws -> Date? {
        let xml = try await call(deviceURL, namespace: Self.deviceNS, body: "<tds:GetSystemDateAndTime/>", authenticated: false)
        let utc = xml.first("UTCDateTime")
        guard let date = utc?.first("Date"), let time = utc?.first("Time"),
              let year = Int(date.first("Year")?.text ?? ""), let month = Int(date.first("Month")?.text ?? ""), let day = Int(date.first("Day")?.text ?? ""),
              let hour = Int(time.first("Hour")?.text ?? ""), let minute = Int(time.first("Minute")?.text ?? ""), let second = Int(time.first("Second")?.text ?? "")
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    func deviceInformation() async throws -> DeviceInfo {
        let xml = try await call(deviceURL, namespace: Self.deviceNS, body: "<tds:GetDeviceInformation/>")
        let response = xml.first("GetDeviceInformationResponse")
        return DeviceInfo(
            manufacturer: response?.first("Manufacturer")?.text,
            model: response?.first("Model")?.text,
            firmware: response?.first("FirmwareVersion")?.text,
            serial: response?.first("SerialNumber")?.text
        )
    }

    /// The media service address from GetCapabilities (falls back to the
    /// device service address, which many cameras also accept).
    func mediaURL() async throws -> URL {
        let xml = try await call(deviceURL, namespace: Self.deviceNS, body: "<tds:GetCapabilities><tds:Category>Media</tds:Category></tds:GetCapabilities>")
        guard let address = xml.first("Media")?.first("XAddr")?.text, let url = URL(string: address) else { return deviceURL }
        return rehost(url)
    }

    func profiles(media: URL) async throws -> [Profile] {
        let xml = try await call(media, namespace: Self.mediaNS, body: "<trt:GetProfiles/>")
        return xml.all("Profiles").compactMap { node in
            guard let token = node.attributes["token"] else { return nil }
            let encoder = node.first("VideoEncoderConfiguration")
            let resolution = encoder?.first("Resolution")
            return Profile(
                token: token,
                name: node.first("Name")?.text ?? token,
                encoding: encoder?.first("Encoding")?.text,
                width: Int(resolution?.first("Width")?.text ?? ""),
                height: Int(resolution?.first("Height")?.text ?? ""),
                frameRate: Double(encoder?.first("RateControl")?.first("FrameRateLimit")?.text ?? "")
            )
        }
    }

    func streamURI(media: URL, profile: String) async throws -> URL {
        let body = """
        <trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup><trt:ProfileToken>\(profile.xmlEscaped)</trt:ProfileToken></trt:GetStreamUri>
        """
        let xml = try await call(media, namespace: Self.mediaNS, body: body)
        guard let text = xml.first("MediaUri")?.first("Uri")?.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProviderError.invalidResponse("The camera didn't return a stream address for this profile.")
        }
        return rehost(url)
    }

    func snapshotURI(media: URL, profile: String) async throws -> URL? {
        let xml = try? await call(media, namespace: Self.mediaNS, body: "<trt:GetSnapshotUri><trt:ProfileToken>\(profile.xmlEscaped)</trt:ProfileToken></trt:GetSnapshotUri>")
        guard let text = xml?.first("MediaUri")?.first("Uri")?.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return rehost(url)
    }

    /// Cameras behind NAT or reached by another name often report their
    /// own internal address; keep the host the user connected to.
    func rehost(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = deviceURL.host else { return url }
        if components.host != host {
            components.host = host
            // A different reported port for the same service only makes
            // sense on the camera's own address; keep RTSP's port.
            if components.scheme?.hasPrefix("http") == true { components.port = deviceURL.port }
        }
        components.user = nil
        components.password = nil
        return components.url ?? url
    }

    // MARK: SOAP

    func envelope(namespace: String, body: String, authenticated: Bool) -> String {
        var header = ""
        if authenticated, let credential, !credential.isEmpty {
            header = "<s:Header>\(Self.securityHeader(credential, created: Date().addingTimeInterval(clockOffset)))</s:Header>"
        }
        let prefix = namespace == Self.mediaNS ? "trt" : "tds"
        return """
        <?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:\(prefix)="\(namespace)" xmlns:tt="http://www.onvif.org/ver10/schema">\(header)<s:Body>\(body)</s:Body></s:Envelope>
        """
    }

    static func securityHeader(_ credential: ConnectionCredential, created: Date, nonce: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let createdText = formatter.string(from: created)
        let digest = Data(Insecure.SHA1.hash(data: nonce + Data(createdText.utf8) + Data(credential.password.utf8))).base64EncodedString()
        return """
        <Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><UsernameToken><Username>\((credential.username ?? "").xmlEscaped)</Username><Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</Password><Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</Nonce><Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\(createdText)</Created></UsernameToken></Security>
        """
    }

    func call(_ url: URL, namespace: String, body: String, authenticated: Bool = true) async throws -> SOAPNode {
        let client = HTTPClient(base: url, credential: credential, configuration: configuration, timeout: 10)
        let soap = Data(envelope(namespace: namespace, body: body, authenticated: authenticated).utf8)
        let response = try await client.send("POST", url: url, body: soap, contentType: "application/soap+xml; charset=utf-8")
        let xml = SOAPNode.parse(response.data)
        if response.isSuccess, let xml { return xml }
        let reason = xml?.first("Reason")?.first("Text")?.text ?? xml?.first("faultstring")?.text
        let subcode = xml?.first("Subcode")?.first("Value")?.text ?? ""
        if response.status == 401 || subcode.contains("NotAuthorized") || (reason ?? "").localizedCaseInsensitiveContains("not authorized") {
            throw ProviderError.authenticationFailed("The camera rejected the ONVIF username or password.")
        }
        if response.status == 404 { throw ProviderError.notFound("No ONVIF service at \(AddressParser.redacted(url)).") }
        if let reason { throw ProviderError.invalidResponse("The camera reported: \(reason)") }
        throw response.isSuccess ? ProviderError.invalidResponse("The camera's ONVIF reply couldn't be read.") : HTTPClient.defaultError(response)
    }
}

extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// A minimal namespace-agnostic XML tree for SOAP replies.
final class SOAPNode: @unchecked Sendable {
    let name: String
    var attributes: [String: String]
    var children: [SOAPNode] = []
    var text: String?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func first(_ local: String) -> SOAPNode? {
        for child in children {
            if child.name == local { return child }
            if let found = child.first(local) { return found }
        }
        return nil
    }

    func all(_ local: String) -> [SOAPNode] {
        children.flatMap { ($0.name == local ? [$0] : []) + $0.all(local) }
    }

    static func parse(_ data: Data) -> SOAPNode? {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return nil }
        return delegate.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: SOAPNode?
        var stack: [SOAPNode] = []
        var buffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = SOAPNode(name: local, attributes: attributeDict)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
            buffer = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let node = stack.popLast(), node.children.isEmpty, !trimmed.isEmpty { node.text = trimmed }
            buffer = ""
        }
    }
}
