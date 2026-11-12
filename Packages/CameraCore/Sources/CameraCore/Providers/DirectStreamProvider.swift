import Foundation

/// A bare HLS, MJPEG or RTSP URL: exactly one camera with live view only.
public struct DirectStreamProvider: CameraProvider {
    public let profile: ConnectionProfile
    let credential: ConnectionCredential?
    let urlSessionConfiguration: URLSessionConfiguration

    public init(
        profile: ConnectionProfile,
        credential: ConnectionCredential?,
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        precondition(profile.kind.isDirectStream, "DirectStreamProvider requires a direct stream profile")
        self.profile = profile
        self.credential = credential
        self.urlSessionConfiguration = urlSessionConfiguration
    }

    var streamProtocol: StreamProtocol {
        switch profile.kind {
        case .hls: .hls
        case .mjpeg: .mjpeg
        case .rtsp: .rtsp
        default: preconditionFailure("not a direct stream")
        }
    }

    var cameraID: CameraID { CameraID(connectionID: profile.id, nativeID: CameraID.directStreamNativeID) }

    var capabilities: CameraCapabilities {
        CameraCapabilities.directStream(streamProtocol)
    }

    func descriptor(status: CameraStatus?) -> CameraDescriptor {
        CameraDescriptor(id: cameraID, name: profile.name, capabilities: capabilities, status: status)
    }

    public func testConnection() async throws -> ConnectionTestReport {
        var notes: [String] = []
        switch streamProtocol {
        case .hls:
            let playlist = try await HLSProbe(configuration: urlSessionConfiguration).probe(profile.address, credential: credential)
            notes.append(playlist.summary)
            if case .media(_, false, _) = playlist.kind {
                notes.append("This playlist has ended, so it is a recording rather than a live camera feed.")
            }
        case .mjpeg:
            let stream = MJPEGStream(url: profile.address, credential: credential, configuration: urlSessionConfiguration)
            defer { stream.cancel() }
            let frames = try await Self.firstFrames(2, of: stream, within: 10)
            notes.append("Receiving JPEG frames (\(ByteCountFormatter.string(fromByteCount: Int64(frames[0].count), countStyle: .file)) each).")
        case .rtsp:
            let result = try await RTSPProbe().probe(profile.address, credential: credential)
            notes.append("Camera offers \(result.description.summary).")
            if let server = result.server { notes.append("Server: \(server)") }
            if result.description.playableVideoTrack == nil {
                notes.append("Live view needs H.264 or H.265 video; choose one of those streams in the camera's settings.")
            }
        case .mp4, .localDevice:
            break
        }
        let status = CameraStatus(state: .online, observedAt: Date())
        return ConnectionTestReport(cameras: [descriptor(status: status)], notes: notes)
    }

    /// The camera list for a direct stream is the profile itself; it does
    /// not require contacting the camera. Liveness is shown by the player.
    public func cameras() async throws -> [CameraDescriptor] {
        [descriptor(status: nil)]
    }

    public func liveSession(for camera: CameraID) async throws -> StreamSession {
        guard camera == cameraID else { throw ProviderError.notFound("Unknown camera.") }
        if let reason = capabilities.liveViewUnavailableReason { throw ProviderError.unsupported(reason) }
        return StreamSession(url: profile.address, streamProtocol: streamProtocol, credential: credential)
    }

    /// Requires `count` frames so a single snapshot image isn't mistaken
    /// for a live stream.
    static func firstFrames(_ count: Int, of stream: MJPEGStream, within seconds: Double) async throws -> [Data] {
        try await withThrowingTaskGroup(of: [Data].self) { group in
            group.addTask {
                var frames: [Data] = []
                do {
                    for try await frame in stream.frames() {
                        frames.append(frame)
                        if frames.count == count { return frames }
                    }
                } catch ProviderError.staleStream {
                    // fall through: the response ended
                }
                if frames.count == 1 {
                    throw ProviderError.unsupportedSource("The address returned a single JPEG image, not a continuous MJPEG stream.")
                }
                throw ProviderError.staleStream(lastFrameAt: nil)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                stream.cancel()
                throw ProviderError.timedOut
            }
            defer { group.cancelAll() }
            guard let frames = try await group.next() else { throw ProviderError.timedOut }
            return frames
        }
    }
}
