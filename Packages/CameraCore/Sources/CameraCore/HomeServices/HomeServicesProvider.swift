import Foundation

/// The optional Home Services provider, over its versioned `/api/v1`
/// contract. Bearer tokens are sent only to the configured origin;
/// redirects elsewhere are refused. Media plays from opaque, expiring
/// session URLs that never contain the token.
///
/// Every camera capability is taken from the server's own report. While
/// Home Services has no recording engine it reports live view, recording,
/// history and arming as unavailable, and this app shows that. The
/// predecessor's archived motion events, which the server serves
/// read-only, appear as a separate "Archived events" entry.
public struct HomeServicesProvider: CameraProvider {
    public let profile: ConnectionProfile
    let client: HTTPClient
    let hasToken: Bool

    static let archiveNativeID = "_archived-events"
    static let requiredScope = "cameras:read"

    public init(profile: ConnectionProfile, credential: ConnectionCredential?, urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        precondition(profile.kind == .homeServices)
        self.profile = profile
        let token = credential?.password ?? ""
        hasToken = !token.isEmpty
        client = HTTPClient(
            base: profile.address,
            headers: [
                "Authorization": "Bearer \(token)",
                HomeServicesWire.contractHeader: "\(HomeServicesWire.clientMajor)",
            ],
            configuration: urlSessionConfiguration
        )
    }

    // MARK: CameraProvider

    public func testConnection() async throws -> ConnectionTestReport {
        let bootstrap = try await self.bootstrap()
        let cameras = try await cameras()
        var notes = ["Contract \(bootstrap.contract.version)" + (bootstrap.version.map { ", server \($0)" } ?? "")]
        if let token = bootstrap.token {
            notes.append("Token \"\(token.name ?? "unnamed")\" with \(token.scopes.count) scope\(token.scopes.count == 1 ? "" : "s")")
        }
        let real = cameras.filter { $0.id.nativeID != Self.archiveNativeID }
        if real.isEmpty {
            notes.append("The server has no cameras configured. Cameras are added on the server, not from this app.")
        } else if real.allSatisfy({ $0.capabilities.liveView == nil }) {
            notes.append("The server reports no live view or recording for its cameras yet: \(real[0].capabilities.liveViewUnavailableReason ?? "unavailable").")
        }
        return ConnectionTestReport(serverName: "Home Services" + (bootstrap.environment.map { " (\($0))" } ?? ""), cameras: cameras, notes: notes)
    }

    public func cameras() async throws -> [CameraDescriptor] {
        let list = try await request(HomeServicesWire.CameraList.self, "GET", "cameras")
        var descriptors = list.cameras.map(descriptor)
        if let capabilities = try? await request(HomeServicesWire.Capabilities.self, "GET", "capabilities"),
           capabilities.capabilities.media?["legacy_events"]?.isAvailable == true {
            descriptors.append(archiveDescriptor)
        }
        return descriptors
    }

    public func liveSession(for camera: CameraID) async throws -> StreamSession {
        guard camera.nativeID != Self.archiveNativeID else { throw ProviderError.unsupported("Archived events have no live view.") }
        let session = try await request(HomeServicesWire.Session.self, "POST", "cameras/\(escape(camera.nativeID))/live-sessions")
        return try streamSession(session, defaultProtocol: .hls)
    }

    /// The newest live frame (contract 1.2); not stored on the server.
    public func snapshot(for camera: CameraID) async throws -> Data {
        guard hasToken else { throw ProviderError.authenticationFailed("Enter the access token issued by your Home Services server.") }
        let response = try await client.send("GET", "api/v1/cameras/\(escape(camera.nativeID))/snapshot", query: [URLQueryItem(name: "width", value: "640")], extraHeaders: ["Accept": "image/jpeg"])
        guard response.isSuccess else { throw Self.error(response) }
        return response.data
    }

    public func setArmed(_ armed: Bool, for camera: CameraID) async throws -> Bool {
        let body = try JSONEncoder().encode(HomeServicesWire.Arming(armed: armed))
        let result = try await request(HomeServicesWire.Arming.self, "PUT", "cameras/\(escape(camera.nativeID))/armed", body: body)
        return result.armed
    }

    public func recordings(for camera: CameraID, cursor: String?) async throws -> RecordingPage {
        if camera.nativeID == Self.archiveNativeID { return try await archivedEvents(camera, cursor: cursor) }
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let list = try await request(HomeServicesWire.RecordingList.self, "GET", "cameras/\(escape(camera.nativeID))/recordings", query: query)
        let recordings = list.recordings.map { wire in
            Recording(
                id: wire.id, camera: camera, startedAt: wire.started_at, endedAt: wire.ended_at,
                kind: wire.kind.flatMap(Recording.Kind.init(rawValue:)) ?? .other, sizeBytes: wire.size_bytes,
                isProtected: wire.protected ?? false, isActive: wire.active ?? (wire.ended_at == nil),
                metadata: ["playable": wire.playable == false ? "0" : "1"]
            )
        }
        return RecordingPage(recordings: recordings, nextCursor: list.next_cursor)
    }

    private func archivedEvents(_ camera: CameraID, cursor: String?) async throws -> RecordingPage {
        let pageSize = 50
        var query = [URLQueryItem(name: "limit", value: "\(pageSize)")]
        if let cursor { query.append(URLQueryItem(name: "before", value: cursor)) }
        let list = try await request(HomeServicesWire.LegacyEvents.self, "GET", "media/legacy/events", query: query)
        let recordings = list.events.compactMap { event -> Recording? in
            guard let started = event.started_at else { return nil }
            let media = event.media ?? []
            return Recording(
                id: event.id, camera: camera, startedAt: started, endedAt: event.ended_at,
                kind: .motion, sizeBytes: nil, isProtected: false, isActive: false,
                label: event.camera_name, isReadOnly: true,
                metadata: ["video": media.first { $0.hasSuffix(".mp4") } ?? "", "image": media.first { $0.hasSuffix(".jpg") } ?? ""]
            )
        }
        return RecordingPage(recordings: recordings, nextCursor: list.events.count == pageSize ? list.events.last?.id : nil)
    }

    public func playbackSession(for recording: Recording) async throws -> StreamSession {
        guard recording.isReadOnly else {
            if recording.metadata["playable"] == "0" { throw ProviderError.notFound("This recording has no video yet.") }
            let session = try await request(HomeServicesWire.Session.self, "POST", recordingPath(recording) + "/playback-sessions")
            return try streamSession(session, defaultProtocol: .hls)
        }
        guard let video = recording.metadata["video"], !video.isEmpty else {
            throw ProviderError.notFound("This event has snapshots but no video.")
        }
        return try streamSession(try await mediaSession(recording, name: video), defaultProtocol: .mp4)
    }

    public func export(_ recording: Recording) async throws -> RecordingExport {
        guard recording.isReadOnly else {
            let export = try await request(HomeServicesWire.Export.self, "POST", recordingPath(recording) + "/exports")
            guard let link = export.download_url ?? export.url else { throw ProviderError.invalidResponse("The server didn't return a download link.") }
            return RecordingExport(
                downloadURL: try client.resolveSameOrigin(link),
                suggestedFilename: export.filename ?? "recording-\(recording.id).mp4",
                contentType: export.content_type, expiresAt: export.expires_at
            )
        }
        guard let video = recording.metadata["video"], !video.isEmpty else {
            throw ProviderError.notFound("This event has snapshots but no video.")
        }
        let session = try await mediaSession(recording, name: video)
        return RecordingExport(
            downloadURL: try client.resolveSameOrigin(session.url),
            suggestedFilename: "\(recording.id)-\(video)",
            contentType: "video/mp4",
            expiresAt: session.expires_at
        )
    }

    public func delete(_ recording: Recording) async throws {
        // Fail early with the reason; the server enforces this too.
        if let reason = recording.deletionBlockedReason { throw ProviderError.conflict(reason) }
        let response = try await client.send("DELETE", "api/v1/" + recordingPath(recording), extraHeaders: ["Accept": "application/json"])
        guard response.isSuccess else { throw Self.error(response) }
    }

    public func setProtected(_ protected: Bool, for recording: Recording) async throws -> Recording {
        guard !recording.isReadOnly else { throw ProviderError.unsupported("Archived events are read-only.") }
        let body = try JSONEncoder().encode(HomeServicesWire.Protection(protected: protected))
        let wire = try await request(HomeServicesWire.Recording.self, "PUT", recordingPath(recording) + "/protected", body: body)
        var updated = recording
        updated.isProtected = wire.protected ?? protected
        return updated
    }

    private func recordingPath(_ recording: Recording) -> String {
        "cameras/\(escape(recording.camera.nativeID))/recordings/\(escape(recording.id))"
    }

    // MARK: Mapping

    func descriptor(_ camera: HomeServicesWire.Camera) -> CameraDescriptor {
        let caps = camera.capabilities
        func support(_ name: String, _ feature: String) -> FeatureSupport {
            guard let capability = caps[name] else { return .unsupported(reason: "This server doesn't report \(feature) for this camera.") }
            return capability.isAvailable ? .supported : .unsupported(reason: Self.reason(capability, feature: feature))
        }
        let live = caps["live_view"]
        let liveProtocol: StreamProtocol? = live?.isAvailable == true ? StreamProtocol(rawValue: live?.protocol?.lowercased() ?? "hls") : nil
        let deletion = support("deletion", "deletion")
        let arming = support("arming", "arming")
        var capabilities = CameraCapabilities(
            liveView: liveProtocol,
            liveViewUnavailableReason: liveProtocol == nil ? (live.map { Self.reason($0, feature: "live view") } ?? "This server doesn't report live view for this camera.") : nil,
            history: support("history", "recording history"),
            playback: support("playback", "recording playback"),
            export: support("export", "recording export"),
            deletion: deletion,
            deletionGranularity: deletion.isSupported ? DeletionGranularity(rawValue: caps["deletion"]?.granularity ?? "recording") : nil,
            serverRecording: support("recording", "server-side recording"),
            motionEvents: support("motion_events", "motion events"),
            notifications: support("notifications", "notifications"),
            notificationTransport: caps["notifications"]?.isAvailable == true ? (caps["notifications"]?.transport ?? "ntfy") : nil,
            arming: arming,
            settings: .unsupported(reason: "Camera settings are managed on the Home Services server.")
        )
        capabilities.armingEffect = caps["arming"]?.isAvailable == true ? caps["arming"]?.effect : nil
        capabilities.snapshot = support("snapshot", "still images")
        if deletion.isSupported { capabilities.protection = .supported }
        let status = camera.status.map { wire in
            CameraStatus(
                state: CameraState(wire: wire.state),
                detail: wire.detail ?? wire.reason.map(Self.describe(reason:)),
                observedAt: wire.observed_at ?? Date(),
                armed: arming.isSupported ? camera.armed : nil,
                recording: wire.recording
            )
        }
        return CameraDescriptor(id: CameraID(connectionID: profile.id, nativeID: camera.id), name: camera.name, capabilities: capabilities, status: status)
    }

    var archiveDescriptor: CameraDescriptor {
        let readOnly = "Archived events are read-only."
        var capabilities = CameraCapabilities.none(reason: readOnly)
        capabilities.liveViewUnavailableReason = "Motion events recorded by the previous camera system, served read-only by Home Services. There is no live view for an archive."
        capabilities.history = .supported
        capabilities.playback = .supported
        capabilities.export = .supported
        capabilities.deletion = .unsupported(reason: "Home Services never deletes the previous system's media.")
        capabilities.serverRecording = .unsupported(reason: "Nothing new is recorded into this archive.")
        return CameraDescriptor(
            id: CameraID(connectionID: profile.id, nativeID: Self.archiveNativeID),
            name: "Archived events",
            capabilities: capabilities,
            status: nil
        )
    }

    static func reason(_ capability: HomeServicesWire.Capability, feature: String) -> String {
        if let message = capability.message, !message.isEmpty { return message }
        if let reason = capability.reason { return describe(reason: reason) }
        return "This server doesn't provide \(feature) for this camera."
    }

    static func describe(reason: String) -> String {
        switch reason {
        case "engine_gate_pending", "engine_not_configured": "Home Services has no recording engine on this host yet."
        case "volume_unavailable": "The server's recording volume is unavailable."
        default: reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    func streamSession(_ session: HomeServicesWire.Session, defaultProtocol: StreamProtocol) throws -> StreamSession {
        let url = try client.resolveSameOrigin(session.url)
        guard url.scheme?.lowercased() == "https" || AddressParser.isLoopback(url.host ?? "") else {
            throw ProviderError.invalidResponse("The server issued a media session that isn't HTTPS.")
        }
        let proto = session.protocol.flatMap { StreamProtocol(rawValue: $0.lowercased()) } ?? defaultProtocol
        return StreamSession(url: url, streamProtocol: proto, credential: nil, expiresAt: session.expires_at)
    }

    private func mediaSession(_ recording: Recording, name: String) async throws -> HomeServicesWire.Session {
        let body = try JSONEncoder().encode(HomeServicesWire.MediaSessionRequest(event_id: recording.id, name: name))
        return try await request(HomeServicesWire.Session.self, "POST", "media/sessions", body: body)
    }

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    // MARK: HTTP

    func bootstrap() async throws -> HomeServicesWire.Bootstrap {
        let bootstrap = try await request(HomeServicesWire.Bootstrap.self, "GET", "bootstrap")
        guard bootstrap.contract.supported_majors.contains(HomeServicesWire.clientMajor) else {
            throw ProviderError.contractVersionMismatch(server: bootstrap.contract.supported_majors.map(String.init), client: "\(HomeServicesWire.clientMajor)")
        }
        if let scopes = bootstrap.token?.scopes, !scopes.contains(Self.requiredScope) {
            throw ProviderError.authenticationFailed("This token can't read cameras. On the server, create one with `home-services tokens create --preset camera-monitor`.")
        }
        return bootstrap
    }

    func request<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        guard hasToken else {
            throw ProviderError.authenticationFailed("Enter the access token issued by your Home Services server.")
        }
        return try await client.json(type, method, "api/v1/" + path, query: query, body: body, decoder: HomeServicesWire.decoder, errorMapper: Self.error)
    }

    static func error(_ response: HTTPClient.Response) -> ProviderError {
        let body = try? HomeServicesWire.decoder.decode(HomeServicesWire.ErrorEnvelope.self, from: response.data).error
        let message = body?.message
        switch body?.code {
        case "unauthenticated": return .authenticationFailed(message.map { "Home Services rejected the token: \($0)." })
        case "forbidden":
            let scope = body?.details?.required_scope
            return .authenticationFailed(scope.map { "This token lacks the \($0) scope. Create one with the camera-monitor preset." } ?? message)
        case "contract_version_unsupported":
            return .contractVersionMismatch(server: (body?.details?.supported_majors ?? []).map(String.init), client: "\(HomeServicesWire.clientMajor)")
        case "not_found": return .notFound(message ?? "Not found on the server.")
        case "capability_unavailable": return .unsupported(body?.details?.message ?? message ?? "The server can't do that for this camera yet.")
        case "media_session_expired": return .notFound("The media link expired. Try again.")
        case "recording_active": return .conflict(message ?? "The recording is still being written and can't be deleted yet.")
        case "recording_protected": return .conflict(message ?? "The recording is protected and can't be deleted.")
        case "volume_unavailable": return .storageUnavailable(message)
        case "camera_disconnected": return .disconnectedHardware(message)
        case "recorder_unavailable": return .recorderUnavailable(message)
        default: break
        }
        switch response.status {
        case 401, 403: return .authenticationFailed(message)
        case 404: return .notFound(message ?? "Not found on the server.")
        case 409: return .conflict(message ?? "The server rejected the change.")
        case 501: return .unsupported(message ?? "The server doesn't support that.")
        case 502, 503, 504: return .networkUnavailable(message ?? "The server reported HTTP \(response.status).")
        default: return .invalidResponse(message ?? "HTTP \(response.status)")
        }
    }
}

extension CameraState {
    init(wire: String) {
        switch wire {
        case "online", "recording", "idle", "streaming": self = .online
        case "offline": self = .offline
        case "camera_disconnected", "disconnected": self = .disconnectedHardware
        case "stale": self = .staleStream
        case "recorder_unavailable": self = .recorderUnavailable
        case "storage_unavailable", "volume_unavailable": self = .storageUnavailable
        default: self = .unknown
        }
    }
}
