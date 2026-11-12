import Foundation

/// A Frigate NVR (https://frigate.video) over its HTTP API: cameras from
/// `/api/config`, status from `/api/stats`, detection events with clips
/// as recordings, event deletion, and snapshots. Live view uses Frigate's
/// built-in go2rtc RTSP restream when the camera has one, otherwise its
/// MJPEG feed. Frigate's authenticated port (8971) needs a username and
/// password (exchanged for its `frigate_token` cookie); the internal port
/// (5000) needs none. Camera configuration changes go through Frigate's
/// own config/MQTT, so settings here are read-only.
public struct FrigateProvider: CameraProvider {
    public let profile: ConnectionProfile
    let client: HTTPClient
    let credential: ConnectionCredential?

    static let tokenCookie = "frigate_token"
    static let tokens = TokenCache()

    public init(profile: ConnectionProfile, credential: ConnectionCredential?, urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        precondition(profile.kind == .frigate)
        self.profile = profile
        self.credential = credential?.isEmpty == false ? credential : nil
        client = HTTPClient(base: profile.address, configuration: urlSessionConfiguration)
    }

    struct Config: Decodable {
        var cameras: [String: Camera]
        var go2rtc: Go2RTC?

        struct Camera: Decodable {
            var enabled: Bool?
            var record: Toggle?
            var snapshots: Toggle?
            var detect: Detect?
        }

        struct Toggle: Decodable {
            var enabled: Bool?
        }

        struct Detect: Decodable {
            var enabled: Bool?
            var width: Int?
            var height: Int?
            var fps: Double?
        }

        struct Go2RTC: Decodable {
            var streams: [String: AnyStream]?
        }

        /// Stream definitions vary (string or list); only names matter.
        struct AnyStream: Decodable {
            init(from decoder: Decoder) throws {}
        }
    }

    struct Stats: Decodable {
        var cameras: [String: CameraStats]?
        var service: Service?

        struct CameraStats: Decodable {
            var camera_fps: Double?
            var detection_fps: Double?
        }

        struct Service: Decodable {
            var version: String?
        }
    }

    struct Event: Decodable {
        var id: String
        var camera: String
        var label: String?
        var sub_label: AnyLabel?
        var start_time: Double
        var end_time: Double?
        var has_clip: Bool?
        var has_snapshot: Bool?
        var retain_indefinitely: Bool?

        /// `sub_label` is a string or [name, score] depending on version.
        struct AnyLabel: Decodable {
            var text: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) {
                    text = string
                } else if let array = try? container.decode([LabelPart].self) {
                    text = array.compactMap(\.string).first
                }
            }
        }

        struct LabelPart: Decodable {
            var string: String?
            init(from decoder: Decoder) throws {
                string = try? decoder.singleValueContainer().decode(String.self)
            }
        }
    }

    // MARK: CameraProvider

    public func testConnection() async throws -> ConnectionTestReport {
        let cameras = try await cameras()
        let stats = try? await request(Stats.self, "api/stats")
        var notes = ["Frigate \(stats?.service?.version ?? "")".trimmingCharacters(in: .whitespaces)]
        notes.append(credential == nil ? "Connected without signing in (Frigate's internal port)." : "Signed in to Frigate.")
        if cameras.isEmpty { notes.append("Frigate has no cameras configured.") }
        return ConnectionTestReport(serverName: "Frigate", cameras: cameras, notes: notes)
    }

    public func cameras() async throws -> [CameraDescriptor] {
        let config = try await request(Config.self, "api/config")
        let stats = try? await request(Stats.self, "api/stats")
        let restreams = Set(config.go2rtc?.streams?.keys.map { $0 } ?? [])
        return config.cameras.keys.sorted().map { name in
            descriptor(name, config.cameras[name]!, stats: stats?.cameras?[name], hasRestream: restreams.contains(name))
        }
    }

    func descriptor(_ name: String, _ camera: Config.Camera, stats: Stats.CameraStats?, hasRestream: Bool) -> CameraDescriptor {
        var capabilities = CameraCapabilities.none(reason: "Not provided by Frigate.")
        let enabled = camera.enabled != false
        capabilities.liveView = enabled ? (hasRestream ? .rtsp : .mjpeg) : nil
        capabilities.liveViewUnavailableReason = enabled ? nil : "This camera is disabled in Frigate."
        capabilities.snapshot = .supported
        let detecting = camera.detect?.enabled != false
        capabilities.motionEvents = detecting ? .supported : .unsupported(reason: "Object detection is turned off for this camera in Frigate.")
        capabilities.history = .supported
        capabilities.playback = .supported
        capabilities.export = .supported
        capabilities.deletion = .supported
        capabilities.deletionGranularity = .recording
        capabilities.protection = .supported
        capabilities.serverRecording = camera.record?.enabled == true ? .supported : .unsupported(reason: "Recording is turned off for this camera in Frigate; only detection events with clips are kept.")
        capabilities.arming = .unsupported(reason: "Frigate's detect/record switches are controlled through its own UI or MQTT, not its HTTP API.")
        capabilities.settings = .supported
        capabilities.notifications = .unsupported(reason: "Frigate doesn't post to ntfy itself. If an automation does, add its topic in this connection's Alerts settings.")

        var status: CameraStatus?
        if let stats {
            let fps = stats.camera_fps ?? 0
            status = CameraStatus(
                state: !enabled ? .unknown : (fps > 0 ? .online : .offline),
                detail: enabled ? (fps > 0 ? String(format: "%.0f fps from camera", fps) : "Frigate is receiving no frames.") : "Disabled",
                observedAt: Date(),
                armed: nil,
                recording: camera.record?.enabled
            )
        }
        return CameraDescriptor(id: CameraID(connectionID: profile.id, nativeID: name), name: Self.displayName(name), capabilities: capabilities, status: status)
    }

    public func liveSession(for camera: CameraID) async throws -> StreamSession {
        let config = try await request(Config.self, "api/config")
        let auth = try await authHeaders()
        if config.go2rtc?.streams?[camera.nativeID] != nil, profile.options.preferredProtocol != .mjpeg {
            var components = URLComponents()
            components.scheme = "rtsp"
            components.host = profile.address.host
            components.port = 8554
            components.percentEncodedPath = "/" + escape(camera.nativeID)
            return StreamSession(url: components.url!, streamProtocol: .rtsp, credential: credential)
        }
        let url = client.url("api/\(escape(camera.nativeID))", query: [URLQueryItem(name: "fps", value: "10"), URLQueryItem(name: "h", value: "720")])
        return StreamSession(url: url, streamProtocol: .mjpeg, headers: auth)
    }

    public func snapshot(for camera: CameraID) async throws -> Data {
        try await data("api/\(escape(camera.nativeID))/latest.jpg", query: [URLQueryItem(name: "h", value: "360")])
    }

    public func recordings(for camera: CameraID, cursor: String?) async throws -> RecordingPage {
        let pageSize = 50
        var query = [URLQueryItem(name: "cameras", value: camera.nativeID), URLQueryItem(name: "camera", value: camera.nativeID), URLQueryItem(name: "limit", value: "\(pageSize)")]
        if let cursor { query.append(URLQueryItem(name: "before", value: cursor)) }
        let events = try await request([Event].self, "api/events", query: query)
        let recordings = events.filter { $0.camera == camera.nativeID }.map { event in
            Recording(
                id: event.id, camera: camera,
                startedAt: Date(timeIntervalSince1970: event.start_time),
                endedAt: event.end_time.map { Date(timeIntervalSince1970: $0) },
                kind: .motion, sizeBytes: nil,
                isProtected: event.retain_indefinitely == true,
                isActive: event.end_time == nil,
                label: [event.label, event.sub_label?.text].compactMap { $0 }.joined(separator: " · "),
                metadata: ["clip": event.has_clip == true ? "1" : "", "snapshot": event.has_snapshot == true ? "1" : ""]
            )
        }
        let next = events.count == pageSize ? events.last.map { String($0.start_time) } : nil
        return RecordingPage(recordings: recordings, nextCursor: next)
    }

    public func playbackSession(for recording: Recording) async throws -> StreamSession {
        guard recording.metadata["clip"] == "1" else { throw ProviderError.notFound("Frigate kept no clip for this event, only a snapshot.") }
        let url = client.url("api/events/\(escape(recording.id))/clip.mp4")
        let cookies = try await authToken().map { [SessionCookie(name: Self.tokenCookie, value: $0)] } ?? []
        return StreamSession(url: url, streamProtocol: .mp4, cookies: cookies)
    }

    public func export(_ recording: Recording) async throws -> RecordingExport {
        guard recording.metadata["clip"] == "1" else { throw ProviderError.notFound("Frigate kept no clip for this event, only a snapshot.") }
        return RecordingExport(
            downloadURL: client.url("api/events/\(escape(recording.id))/clip.mp4", query: [URLQueryItem(name: "download", value: "true")]),
            suggestedFilename: "\(recording.camera.nativeID)-\(recording.id).mp4",
            contentType: "video/mp4", expiresAt: nil, headers: try await authHeaders()
        )
    }

    public func delete(_ recording: Recording) async throws {
        if let reason = recording.deletionBlockedReason { throw ProviderError.conflict(reason) }
        let response = try await send("DELETE", "api/events/\(escape(recording.id))")
        guard response.isSuccess else { throw Self.error(response) }
    }

    /// Frigate's "retain indefinitely" flag.
    public func setProtected(_ protected: Bool, for recording: Recording) async throws -> Recording {
        let response = try await send(protected ? "POST" : "DELETE", "api/events/\(escape(recording.id))/retain")
        guard response.isSuccess else { throw Self.error(response) }
        var updated = recording
        updated.isProtected = protected
        return updated
    }

    public func settings(for camera: CameraID) async throws -> [CameraSetting] {
        let config = try await request(Config.self, "api/config")
        guard let settings = config.cameras[camera.nativeID] else { throw ProviderError.notFound("Frigate no longer has a camera named \(camera.nativeID).") }
        func onOff(_ value: Bool?) -> String { value == false ? "Off" : "On" }
        var result: [CameraSetting] = [
            CameraSetting(id: "enabled", title: "Camera", section: "Frigate", value: .info(onOff(settings.enabled))),
            CameraSetting(id: "detect", title: "Object detection", section: "Frigate", value: .info(onOff(settings.detect?.enabled))),
            CameraSetting(id: "record", title: "Recording", section: "Frigate", value: .info(settings.record?.enabled == true ? "On" : "Off")),
            CameraSetting(id: "snapshots", title: "Snapshots", section: "Frigate", value: .info(settings.snapshots?.enabled == true ? "On" : "Off")),
        ]
        if let width = settings.detect?.width, let height = settings.detect?.height {
            result.append(CameraSetting(id: "detectSize", title: "Detection resolution", section: "Frigate", value: .info("\(width)×\(height) at \(Int(settings.detect?.fps ?? 5)) fps")))
        }
        if config.go2rtc?.streams?[camera.nativeID] != nil {
            result.append(CameraSetting(
                id: CameraSetting.preferredProtocolID, title: "Live view uses", section: "Playback",
                value: .choice(selected: profile.options.preferredProtocol == .mjpeg ? StreamProtocol.mjpeg.rawValue : StreamProtocol.rtsp.rawValue, options: [
                    .init(id: StreamProtocol.rtsp.rawValue, title: "RTSP restream (full quality)"),
                    .init(id: StreamProtocol.mjpeg.rawValue, title: "MJPEG (lower quality, most compatible)"),
                ]),
                detail: "Applies to every camera on this Frigate server."
            ))
        }
        result.append(CameraSetting(id: "note", title: "Changing settings", section: "Frigate", value: .info("Use Frigate's configuration editor"), detail: "Frigate's HTTP API doesn't switch detection or recording."))
        return result
    }

    // MARK: HTTP

    static func displayName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    func authHeaders() async throws -> [String: String] {
        try await authToken().map { ["Cookie": "\(Self.tokenCookie)=\($0)"] } ?? [:]
    }

    /// Logs in once per connection and reuses the token until it's rejected.
    func authToken(refresh: Bool = false) async throws -> String? {
        guard let credential else { return nil }
        if !refresh, let cached = await Self.tokens.token(for: profile.id) { return cached }
        struct Login: Encodable { var user: String; var password: String }
        let body = try JSONEncoder().encode(Login(user: credential.username ?? "", password: credential.password))
        let response = try await client.send("POST", "api/login", body: body)
        guard response.isSuccess else {
            throw response.status == 401 || response.status == 400 ? ProviderError.authenticationFailed("Frigate rejected the username or password.") : Self.error(response)
        }
        guard let token = Self.cookieValue(Self.tokenCookie, in: response.header("Set-Cookie")) else {
            throw ProviderError.invalidResponse("Frigate accepted the sign-in but returned no session token.")
        }
        await Self.tokens.set(token, for: profile.id)
        return token
    }

    static func cookieValue(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";").flatMap({ $0.split(separator: ",") }) {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == name { return String(pair[1]) }
        }
        return nil
    }

    func send(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> HTTPClient.Response {
        var response = try await client.send(method, path, query: query, extraHeaders: try await authHeaders().merging(["Accept": "application/json"]) { $1 })
        if response.status == 401, credential != nil {
            let token = try await authToken(refresh: true)
            response = try await client.send(method, path, query: query, extraHeaders: ["Cookie": "\(Self.tokenCookie)=\(token ?? "")", "Accept": "application/json"])
        }
        return response
    }

    func request<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let response = try await send("GET", path, query: query)
        guard response.isSuccess else { throw Self.error(response) }
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw ProviderError.invalidResponse("Frigate's \(path) response wasn't in the expected format.")
        }
    }

    func data(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let response = try await send("GET", path, query: query)
        guard response.isSuccess else { throw Self.error(response) }
        return response.data
    }

    static func error(_ response: HTTPClient.Response) -> ProviderError {
        struct Message: Decodable { var message: String? }
        let message = (try? JSONDecoder().decode(Message.self, from: response.data))?.message
        switch response.status {
        case 401, 403: return .authenticationFailed(message ?? "Frigate requires signing in. Enter a Frigate username and password, or use its internal port 5000.")
        case 404: return .notFound(message ?? "Not found in Frigate.")
        default: return HTTPClient.defaultError(response)
        }
    }

    actor TokenCache {
        private var tokens: [UUID: String] = [:]
        func token(for id: UUID) -> String? { tokens[id] }
        func set(_ token: String, for id: UUID) { tokens[id] = token }
    }
}
