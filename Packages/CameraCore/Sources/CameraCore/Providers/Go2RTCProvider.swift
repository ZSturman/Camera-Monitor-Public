import Foundation

/// A go2rtc streaming server (https://github.com/AlexxIT/go2rtc): every
/// configured stream becomes a camera with live view and snapshots. go2rtc
/// doesn't record, so there's no history. Live view uses the server's RTSP
/// output by default (native H.264/H.265 player); HLS or MJPEG can be
/// chosen per connection. Producer URLs often embed camera passwords, so
/// they are never displayed.
public struct Go2RTCProvider: CameraProvider {
    public let profile: ConnectionProfile
    let client: HTTPClient
    let credential: ConnectionCredential?

    public init(profile: ConnectionProfile, credential: ConnectionCredential?, urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        precondition(profile.kind == .go2rtc)
        self.profile = profile
        self.credential = credential?.isEmpty == false ? credential : nil
        client = HTTPClient(base: profile.address, credential: self.credential, configuration: urlSessionConfiguration)
    }

    struct Info: Decodable {
        var version: String?
        var rtsp: Listen?

        struct Listen: Decodable {
            var listen: String?
        }
    }

    struct Stream: Decodable {
        var producers: [Producer]?
        var consumers: [Consumer]?

        struct Producer: Decodable {
            var url: String?
        }

        struct Consumer: Decodable {}
    }

    // MARK: CameraProvider

    public func testConnection() async throws -> ConnectionTestReport {
        let info = try await client.json(Info.self, "GET", "api", errorMapper: Self.error)
        let cameras = try await cameras()
        var notes = ["go2rtc \(info.version ?? "unknown version")"]
        if let listen = info.rtsp?.listen { notes.append("RTSP output on port \(Self.port(listen) ?? 8554)") }
        if cameras.isEmpty { notes.append("The server has no streams configured.") }
        return ConnectionTestReport(serverName: "go2rtc", cameras: cameras, notes: notes)
    }

    public func cameras() async throws -> [CameraDescriptor] {
        let streams = try await client.json([String: Stream].self, "GET", "api/streams", errorMapper: Self.error)
        return streams.keys.sorted().map { name in
            var capabilities = CameraCapabilities.directStream(liveProtocol)
            capabilities.snapshot = .supported
            let reason = "go2rtc relays live video; it doesn't record, keep history or detect motion."
            capabilities.history = .unsupported(reason: reason)
            capabilities.serverRecording = .unsupported(reason: reason)
            capabilities.motionEvents = .unsupported(reason: reason)
            capabilities.settings = .supported
            return CameraDescriptor(id: CameraID(connectionID: profile.id, nativeID: name), name: name, capabilities: capabilities, status: nil)
        }
    }

    var liveProtocol: StreamProtocol {
        switch profile.options.preferredProtocol {
        case .hls?: .hls
        case .mjpeg?: .mjpeg
        default: .rtsp
        }
    }

    public func liveSession(for camera: CameraID) async throws -> StreamSession {
        let source = [URLQueryItem(name: "src", value: camera.nativeID)]
        switch liveProtocol {
        case .hls:
            // fMP4 segments carry H.265 as well as H.264.
            return StreamSession(url: client.url("api/stream.m3u8", query: source + [URLQueryItem(name: "mp4", value: nil)]), streamProtocol: .hls, credential: credential)
        case .mjpeg:
            return StreamSession(url: client.url("api/stream.mjpeg", query: source), streamProtocol: .mjpeg, credential: credential)
        default:
            let info = try? await client.json(Info.self, "GET", "api", errorMapper: Self.error)
            var components = URLComponents()
            components.scheme = "rtsp"
            components.host = profile.address.host
            components.port = info?.rtsp?.listen.flatMap(Self.port) ?? 8554
            components.percentEncodedPath = "/" + (camera.nativeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?"))) ?? camera.nativeID)
            return StreamSession(url: components.url!, streamProtocol: .rtsp, credential: credential)
        }
    }

    public func snapshot(for camera: CameraID) async throws -> Data {
        let response = try await client.send("GET", "api/frame.jpeg", query: [URLQueryItem(name: "src", value: camera.nativeID)], extraHeaders: ["Accept": "image/jpeg"])
        guard response.isSuccess else { throw Self.error(response) }
        // go2rtc answers 200 with an empty body when the source can't start.
        guard !response.data.isEmpty else { throw ProviderError.disconnectedHardware("go2rtc couldn't read a frame from this stream's source. It may be offline or in use by another program.") }
        return response.data
    }

    public func settings(for camera: CameraID) async throws -> [CameraSetting] {
        let streams = try await client.json([String: Stream].self, "GET", "api/streams", errorMapper: Self.error)
        guard let stream = streams[camera.nativeID] else { throw ProviderError.notFound("go2rtc no longer has a stream named \(camera.nativeID).") }
        var settings = [CameraSetting(
            id: CameraSetting.preferredProtocolID, title: "Live view uses", section: "Playback",
            value: .choice(selected: liveProtocol.rawValue, options: [
                .init(id: StreamProtocol.rtsp.rawValue, title: "RTSP (lowest delay)"),
                .init(id: StreamProtocol.hls.rawValue, title: "HLS"),
                .init(id: StreamProtocol.mjpeg.rawValue, title: "MJPEG (most compatible)"),
            ]),
            detail: "Applies to every stream on this server."
        )]
        for (index, producer) in (stream.producers ?? []).enumerated() {
            settings.append(CameraSetting(id: "source\(index)", title: "Source \(index + 1)", section: "Server", value: .info(Self.describeSource(producer.url))))
        }
        settings.append(CameraSetting(id: "viewers", title: "Current viewers", section: "Server", value: .info("\(stream.consumers?.count ?? 0)")))
        return settings
    }

    // MARK: Helpers

    /// Only the kind of source; producer URLs can contain passwords.
    static func describeSource(_ url: String?) -> String {
        guard let url, let scheme = url.split(separator: ":").first.map(String.init) else { return "Unknown" }
        switch scheme {
        case "ffmpeg": return url.contains("device?") ? "Local device via FFmpeg" : "FFmpeg"
        case "rtsp", "rtsps": return "RTSP camera"
        case "http", "https": return "HTTP source"
        case "onvif": return "ONVIF camera"
        case "homekit": return "HomeKit camera"
        case "webrtc": return "WebRTC source"
        default: return scheme.uppercased()
        }
    }

    /// ":8554" or "0.0.0.0:8554" → 8554.
    static func port(_ listen: String) -> Int? {
        listen.split(separator: ":").last.flatMap { Int($0) }
    }

    static func error(_ response: HTTPClient.Response) -> ProviderError {
        switch response.status {
        case 401: .authenticationFailed("go2rtc rejected the username or password.")
        default: HTTPClient.defaultError(response)
        }
    }
}
