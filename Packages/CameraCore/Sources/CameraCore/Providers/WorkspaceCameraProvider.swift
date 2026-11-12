import Foundation

/// The Pi camera dashboard from Workspace Sync & Backup Utility (the
/// predecessor camera system): one USB camera with HLS live view, motion
/// events with MP4 recordings, and "out of the house" mode, which arms
/// motion recording. Its API is read from that project's dashboard
/// (`/api/camera/...`); it has no deletion endpoint, so recordings are
/// read-only here.
///
/// Auth: the dashboard token goes in `X-Workspace-Token`. AVPlayer can't
/// add headers, so live/recording playback sends the dashboard's own
/// session cookie, which holds the same token, to the dashboard host only.
/// A dashboard without a token configured (Tailscale as the boundary)
/// works with the token left blank.
public struct WorkspaceCameraProvider: CameraProvider {
    public let profile: ConnectionProfile
    let client: HTTPClient
    let token: String?

    static let nativeID = "camera"
    static let tokenHeader = "X-Workspace-Token"
    static let sessionCookie = "workspace_session"

    public init(profile: ConnectionProfile, credential: ConnectionCredential?, urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        precondition(profile.kind == .workspaceCamera)
        self.profile = profile
        let token = credential?.password.isEmpty == false ? credential?.password : nil
        self.token = token
        client = HTTPClient(base: profile.address, headers: token.map { [Self.tokenHeader: $0] } ?? [:], configuration: urlSessionConfiguration)
    }

    struct Status: Decodable {
        var enabled: Bool?
        var available: Bool?
        var detail: String?
        var device: String?
        var width: Int?
        var height: Int?
        var out_of_house: Bool?
        var recording: Bool?
        var current_event_id: String?
        var last_snapshot_at: Double?
        var last_capture_error: String?
        var last_motion_at: Double?
        var live_stream: LiveStream?
    }

    struct LiveStream: Decodable {
        var enabled: Bool?
        var available: Bool?
        var detail: String?
        var width: Int?
        var height: Int?
        var fps: Double?
        var playlist: String?
        var latest_segment_age_seconds: Double?
    }

    struct Event: Decodable {
        var event_id: String
        var start_ts: Double?
        var end_ts: Double?
        var last_motion_ts: Double?
        var camera_device_name: String?
        var recording_started: Bool?
        var recording_path: String?
        var recording_bytes: Int64?
    }

    var cameraID: CameraID { CameraID(connectionID: profile.id, nativeID: Self.nativeID) }

    // MARK: CameraProvider

    public func testConnection() async throws -> ConnectionTestReport {
        let status = try await self.status()
        var notes: [String] = []
        if let device = status.device { notes.append("Camera device \(device): \(status.detail ?? "unknown")") }
        if let live = status.live_stream {
            notes.append(live.enabled == true ? "Live stream: \(live.detail ?? "unknown")" + (live.width.map { " (\($0)×\(live.height ?? 0)\(live.fps.map { ", \(Int($0)) fps" } ?? ""))" } ?? "") : "Live streaming is turned off on the Pi.")
        }
        notes.append("Out-of-house mode is \(status.out_of_house == true ? "on" : "off").")
        if token == nil { notes.append("No token entered: this dashboard accepted requests without one.") }
        return ConnectionTestReport(serverName: "Workspace Sync dashboard", cameras: [descriptor(status)], notes: notes)
    }

    public func cameras() async throws -> [CameraDescriptor] {
        [descriptor(try await status())]
    }

    public func liveSession(for camera: CameraID) async throws -> StreamSession {
        let status = try await status()
        guard status.live_stream?.enabled == true else {
            throw ProviderError.unsupported(status.live_stream?.detail ?? "Live streaming is turned off on the Pi.")
        }
        guard status.live_stream?.available == true else {
            throw ProviderError.networkUnavailable(status.live_stream?.detail ?? "The camera is starting or reconnecting.")
        }
        return StreamSession(url: client.url("api/camera/live/\(status.live_stream?.playlist ?? "index.m3u8")"), streamProtocol: .hls, cookies: cookies)
    }

    public func setArmed(_ armed: Bool, for camera: CameraID) async throws -> Bool {
        struct Arming: Codable { var armed: Bool }
        return try await client.json(Arming.self, "POST", "api/camera/out-of-house", body: JSONEncoder().encode(Arming(armed: armed)), errorMapper: Self.error).armed
    }

    public func snapshot(for camera: CameraID) async throws -> Data {
        // The most recent saved frame is cheap and doesn't touch the
        // device; an on-demand capture fails while the live stream owns it.
        for path in ["api/camera/latest", "api/camera/snapshot"] {
            let response = try await client.send("GET", path, extraHeaders: ["Accept": "image/jpeg"])
            if response.isSuccess, response.header("Content-Type")?.hasPrefix("image/") == true { return response.data }
            if response.status == 401 { throw Self.error(response) }
        }
        throw ProviderError.unsupported("The Pi has no saved snapshot and can't capture one while the live stream is using the camera.")
    }

    public func recordings(for camera: CameraID, cursor: String?) async throws -> RecordingPage {
        let events = try await client.json([Event].self, "GET", "api/camera/events", query: [URLQueryItem(name: "limit", value: "200")], errorMapper: Self.error)
        let recordings = events.compactMap { event -> Recording? in
            guard let start = event.start_ts else { return nil }
            let video = event.recording_path.map { ($0 as NSString).lastPathComponent }
            return Recording(
                id: event.event_id, camera: camera,
                startedAt: Date(timeIntervalSince1970: start),
                endedAt: event.end_ts.map { Date(timeIntervalSince1970: $0) },
                kind: .motion, sizeBytes: event.recording_bytes,
                isProtected: false, isActive: event.end_ts == nil,
                label: event.camera_device_name, isReadOnly: true,
                metadata: ["video": event.recording_started == false ? "" : (video ?? "")]
            )
        }
        return RecordingPage(recordings: recordings, nextCursor: nil)
    }

    public func playbackSession(for recording: Recording) async throws -> StreamSession {
        StreamSession(url: try mediaURL(recording), streamProtocol: .mp4, cookies: cookies)
    }

    public func export(_ recording: Recording) async throws -> RecordingExport {
        RecordingExport(downloadURL: try mediaURL(recording), suggestedFilename: "\(recording.id).mp4", contentType: "video/mp4", expiresAt: nil, headers: client.headers)
    }

    public func delete(_ recording: Recording) async throws {
        throw ProviderError.unsupported("The Pi dashboard doesn't delete recordings; they're managed on the Pi.")
    }

    public func settings(for camera: CameraID) async throws -> [CameraSetting] {
        let status = try await status()
        var settings: [CameraSetting] = []
        func info(_ id: String, _ title: String, _ value: String?) {
            if let value { settings.append(CameraSetting(id: id, title: title, section: "Camera", value: .info(value))) }
        }
        info("device", "Device", status.device)
        info("snapshot", "Snapshot size", status.width.map { "\($0)×\(status.height ?? 0)" })
        if let live = status.live_stream, live.enabled == true {
            info("live", "Live stream", live.width.map { "\($0)×\(live.height ?? 0) at \(Int(live.fps ?? 0)) fps" })
            info("segment", "Newest segment", live.latest_segment_age_seconds.map { "\(Int($0)) s old" })
        }
        info("lastMotion", "Last motion", status.last_motion_at.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard) })
        info("captureError", "Last capture error", status.last_capture_error)
        settings.append(CameraSetting(id: "note", title: "Changing settings", section: "Camera", value: .info("Edit /etc/workspace-util/config.yaml on the Pi"), detail: "The dashboard API doesn't change camera configuration."))
        return settings
    }

    // MARK: Mapping

    var cookies: [SessionCookie] {
        token.map { [SessionCookie(name: Self.sessionCookie, value: $0)] } ?? []
    }

    func mediaURL(_ recording: Recording) throws -> URL {
        guard let video = recording.metadata["video"], !video.isEmpty else {
            throw ProviderError.notFound(recording.isActive ? "This event is still recording." : "This event has no video recording.")
        }
        let id = recording.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? recording.id
        let name = video.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? video
        return client.url("api/camera/events/\(id)/media/\(name)")
    }

    func descriptor(_ status: Status) -> CameraDescriptor {
        var capabilities = CameraCapabilities.none(reason: "Not provided by the Pi dashboard.")
        let live = status.live_stream
        if status.enabled == false {
            capabilities.liveViewUnavailableReason = "The camera is disabled in the Pi's configuration."
        } else if live?.enabled == true {
            capabilities.liveView = .hls
            capabilities.liveViewUnavailableReason = nil
        } else {
            capabilities.liveViewUnavailableReason = "Live streaming is turned off on the Pi."
        }
        capabilities.snapshot = .supported
        capabilities.history = .supported
        capabilities.playback = .supported
        capabilities.export = .supported
        capabilities.deletion = .unsupported(reason: "The Pi dashboard has no deletion API; recordings are managed on the Pi.")
        capabilities.serverRecording = .supported
        capabilities.motionEvents = .supported
        capabilities.arming = .supported
        capabilities.settings = .supported
        capabilities.notifications = .unsupported(reason: "Add an ntfy topic in this connection's Alerts settings if the Pi posts motion alerts to one.")

        let state: CameraState
        var detail: String?
        if status.available == false {
            state = (status.detail ?? "").contains("not found") ? .disconnectedHardware : .unknown
            detail = status.detail
        } else if live?.enabled == true, live?.available == false {
            state = .staleStream
            detail = live?.detail
        } else {
            state = .online
            detail = status.recording == true ? "Recording a motion event" : nil
        }
        return CameraDescriptor(
            id: cameraID,
            name: profile.name,
            capabilities: capabilities,
            status: CameraStatus(state: state, detail: detail, observedAt: Date(), armed: status.out_of_house, recording: status.recording)
        )
    }

    func status() async throws -> Status {
        try await client.json(Status.self, "GET", "api/camera/status", errorMapper: Self.error)
    }

    static func error(_ response: HTTPClient.Response) -> ProviderError {
        struct Detail: Decodable { var detail: String? }
        let detail = (try? JSONDecoder().decode(Detail.self, from: response.data))?.detail
        switch response.status {
        case 401, 403: return .authenticationFailed(detail.map { "The dashboard rejected the token (\($0))." } ?? "Enter the dashboard token configured on the Pi.")
        case 404: return .notFound(detail ?? "Not found on the dashboard.")
        case 429: return .conflict(detail ?? "The camera is busy.")
        case 503: return .disconnectedHardware(detail)
        default: return HTTPClient.defaultError(response)
        }
    }
}
