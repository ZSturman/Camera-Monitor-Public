import Foundation

/// Plays one RTSP video track natively: DESCRIBE, SETUP with RTP
/// interleaved over the RTSP TCP connection, PLAY, then access units for
/// H.264/H.265 decoding by VideoToolbox. No third-party media library.
/// Audio tracks are not set up (live view is video only).
public final class RTSPPlayerSession: @unchecked Sendable {
    public enum Event: Sendable {
        case started(codec: VideoCodec, parameterSets: [Data], server: String?)
        case accessUnit(VideoAccessUnit)
    }

    public let url: URL
    let credential: ConnectionCredential?
    let timeout: TimeInterval
    let userAgent: String
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var connection: RTSPConnection?
    private var teardown: Data?

    public init(url: URL, credential: ConnectionCredential?, timeout: TimeInterval = 10, userAgent: String = "CameraMonitor/1.0") {
        self.url = url
        self.credential = credential
        self.timeout = timeout
        self.userAgent = userAgent
    }

    /// Events until the camera ends the stream, an error occurs, or `stop()`.
    public func events() -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(120)) { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.run(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            lock.withLock { self.task = task }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    /// Sends TEARDOWN (best effort) and closes the connection.
    public func stop() {
        let (task, connection, teardown) = lock.withLock { () -> (Task<Void, Never>?, RTSPConnection?, Data?) in
            defer { self.task = nil; self.connection = nil; self.teardown = nil }
            return (self.task, self.connection, self.teardown)
        }
        task?.cancel()
        if let connection {
            if let teardown { connection.writeThenClose(teardown) } else { connection.close() }
        }
    }

    private func run(_ continuation: AsyncThrowingStream<Event, Error>.Continuation) async throws {
        let connection = try RTSPConnection(url: url, timeout: timeout)
        lock.withLock { self.connection = connection }
        try await connection.open()
        let requester = RTSPRequester(connection: connection, credential: credential, userAgent: userAgent)
        let described = try await RTSPProbe(timeout: timeout, userAgent: userAgent).describe(url, using: requester)

        guard let track = described.description.playableVideoTrack, let codec = VideoCodec(sdpName: track.codec) else {
            let offered = described.description.videoCodecs.joined(separator: ", ")
            throw ProviderError.unsupportedSource(offered.isEmpty
                ? "The camera's stream has no video track."
                : "The camera sends \(offered) video, which this player can't decode. Choose an H.264 or H.265 stream in the camera's settings.")
        }

        let trackURL = SessionDescription.resolve(control: track.control, base: described.contentBase)
        let setup = try await requester.send("SETUP", uri: trackURL.absoluteString, extra: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"])
        if let error = RTSPProbe.error(for: setup.status, method: "SETUP") { throw error }
        guard let sessionHeader = setup.headerValues("Session").first else {
            throw ProviderError.invalidResponse("The camera didn't start an RTSP session.")
        }
        let sessionParts = sessionHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        requester.session = sessionParts.first
        let sessionTimeout = sessionParts.dropFirst().first { $0.lowercased().hasPrefix("timeout=") }
            .flatMap { Int($0.dropFirst("timeout=".count)) } ?? 60
        let channel = Self.rtpChannel(from: setup.headerValues("Transport").first) ?? 0

        let aggregateURL = SessionDescription.resolve(control: described.description.control, base: described.contentBase)
        let play = try await requester.send("PLAY", uri: aggregateURL.absoluteString, extra: ["Range": "npt=0.000-"])
        if let error = RTSPProbe.error(for: play.status, method: "PLAY") { throw error }
        lock.withLock {
            teardown = RTSPConnection.encode(method: "TEARDOWN", uri: aggregateURL.absoluteString, headers: requester.headers("TEARDOWN", uri: aggregateURL.absoluteString, extra: [:]))
        }

        continuation.yield(.started(codec: codec, parameterSets: codec.parameterSets(from: track.formatParameters), server: described.server))

        // Keep the session alive; GET_PARAMETER is the usual choice, but
        // OPTIONS works with cameras that don't implement it.
        let keepAliveMethod = described.methods.contains("GET_PARAMETER") ? "GET_PARAMETER" : "OPTIONS"
        let keepAliveInterval = max(5, Double(sessionTimeout) / 2)
        var nextKeepAlive = Date().addingTimeInterval(keepAliveInterval)

        var depacketizer = RTPDepacketizer(codec: codec)
        while !Task.isCancelled {
            let message = try await connection.readMessage()
            if case let .interleaved(packetChannel, payload) = message, packetChannel == channel, let packet = RTPPacket(payload) {
                for unit in depacketizer.push(packet) { continuation.yield(.accessUnit(unit)) }
            } else if case let .response(response) = message, response.status == 401 || response.status == 454 {
                throw ProviderError.networkUnavailable("The camera ended the RTSP session (RTSP \(response.status)).")
            }
            if Date() >= nextKeepAlive {
                nextKeepAlive = Date().addingTimeInterval(keepAliveInterval)
                try await requester.post(keepAliveMethod, uri: aggregateURL.absoluteString)
            }
        }
    }

    /// The RTP channel from `interleaved=a-b` in the SETUP reply.
    static func rtpChannel(from transport: String?) -> UInt8? {
        guard let transport else { return nil }
        for part in transport.split(separator: ";") where part.lowercased().hasPrefix("interleaved=") {
            let range = part.dropFirst("interleaved=".count).split(separator: "-")
            return range.first.flatMap { UInt8($0) }
        }
        return nil
    }
}
