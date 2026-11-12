import Foundation
import Network

/// A minimal RTSP/1.0 client for Test Connection: OPTIONS then DESCRIBE,
/// with Basic/Digest auth, over TCP (or TLS for rtsps://). It does not
/// play media; `RTSPPlayerSession` does.
public struct RTSPProbe: Sendable {
    public struct Result: Equatable, Sendable {
        public var description: SessionDescription
        public var server: String?
        public var methods: [String]
        /// The base for resolving relative track controls.
        public var contentBase: URL
    }

    public var timeout: TimeInterval
    public var userAgent: String

    public init(timeout: TimeInterval = 8, userAgent: String = "CameraMonitor/1.0") {
        self.timeout = timeout
        self.userAgent = userAgent
    }

    public func probe(_ url: URL, credential: ConnectionCredential?) async throws -> Result {
        let connection = try RTSPConnection(url: url, timeout: timeout)
        defer { connection.close() }
        try await connection.open()
        return try await describe(url, using: RTSPRequester(connection: connection, credential: credential, userAgent: userAgent))
    }

    func describe(_ url: URL, using requester: RTSPRequester) async throws -> Result {
        let uri = Self.requestURI(url)
        let options = try await requester.send("OPTIONS", uri: uri)
        let methods = options.headerValues("Public").flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let error = Self.error(for: options.status, method: "OPTIONS"), options.status != 501 { throw error }

        let describe = try await requester.send("DESCRIBE", uri: uri, extra: ["Accept": "application/sdp"])
        if let error = Self.error(for: describe.status, method: "DESCRIBE") { throw error }
        let sdp = SessionDescription.parse(String(decoding: describe.body, as: UTF8.self))
        guard !sdp.media.isEmpty else { throw ProviderError.unsupportedSource("The camera's session description has no media tracks.") }
        let base = (describe.headerValues("Content-Base").first ?? describe.headerValues("Content-Location").first)
            .flatMap { URL(string: $0) } ?? URL(string: uri) ?? url
        return Result(
            description: sdp,
            server: options.headerValues("Server").first ?? describe.headerValues("Server").first,
            methods: methods,
            contentBase: base
        )
    }

    /// The request URI: the address without any userinfo.
    static func requestURI(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        return components?.string ?? url.absoluteString
    }

    static func error(for status: Int, method: String) -> ProviderError? {
        switch status {
        case 200..<300: nil
        case 401, 403: .authenticationFailed()
        case 404: .notFound("The camera has no stream at that path (RTSP 404).")
        case 415, 461: .unsupportedSource("The camera rejected the transport or media type (RTSP \(status)).")
        case 453: .networkUnavailable("The camera doesn't have enough bandwidth for another viewer (RTSP 453).")
        case 503: .networkUnavailable("The camera is busy or has too many viewers (RTSP 503).")
        default: .invalidResponse("\(method) returned RTSP \(status).")
        }
    }
}

/// Sends requests on one connection with CSeq, Session and Basic/Digest
/// authorization. Credentials only go to the connection's own host.
final class RTSPRequester: @unchecked Sendable {
    let connection: RTSPConnection
    let credential: ConnectionCredential?
    let userAgent: String
    var session: String?
    private var cseq = 1
    private var challenge: RTSPAuthChallenge?
    private var nonceCount = 0

    init(connection: RTSPConnection, credential: ConnectionCredential?, userAgent: String) {
        self.connection = connection
        self.credential = credential
        self.userAgent = userAgent
    }

    func headers(_ method: String, uri: String, extra: [String: String]) -> [String: String] {
        var headers = ["CSeq": "\(cseq)", "User-Agent": userAgent]
        extra.forEach { headers[$0] = $1 }
        if let session { headers["Session"] = session }
        cseq += 1
        if let challenge, let credential {
            nonceCount += 1
            headers["Authorization"] = challenge.authorization(method: method, uri: uri, credential: credential, nonceCount: nonceCount)
        }
        return headers
    }

    func send(_ method: String, uri: String, extra: [String: String] = [:]) async throws -> RTSPResponse {
        for attempt in 0..<2 {
            let response = try await connection.send(method: method, uri: uri, headers: headers(method, uri: uri, extra: extra))
            guard response.status == 401 else { return response }
            guard attempt == 0, credential != nil, let parsed = RTSPAuthChallenge.parse(response.headerValues("WWW-Authenticate")) else {
                throw ProviderError.authenticationFailed(credential == nil ? "This camera requires a username and password." : nil)
            }
            challenge = parsed
            nonceCount = 0
        }
        throw ProviderError.authenticationFailed()
    }

    /// Writes a request without waiting for its response (keep-alives and
    /// TEARDOWN while media is flowing).
    func post(_ method: String, uri: String) async throws {
        try await connection.write(method: method, uri: uri, headers: headers(method, uri: uri, extra: [:]))
    }
}
