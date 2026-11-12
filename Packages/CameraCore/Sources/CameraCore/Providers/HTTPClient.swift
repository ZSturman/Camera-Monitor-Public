import Foundation

/// Requests to one server origin for the JSON-based providers. Redirects to
/// another origin are refused, so tokens and passwords never follow them;
/// Basic/Digest challenges are answered only for the configured origin.
/// Cookies and shared credential storage are never used.
struct HTTPClient: Sendable {
    let base: URL
    var credential: ConnectionCredential?
    var headers: [String: String] = [:]
    var configuration: URLSessionConfiguration = .ephemeral
    var timeout: TimeInterval = 15

    struct Response: Sendable {
        var data: Data
        var http: HTTPURLResponse

        var status: Int { http.statusCode }
        var isSuccess: Bool { (200..<300).contains(status) }

        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
    }

    /// `path` is appended to the base path; it may contain an encoded query.
    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let relative = path.hasPrefix("/") ? path : "/" + path
        components.percentEncodedPath = basePath + relative
        components.queryItems = query.isEmpty ? nil : query
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url!
    }

    /// Resolves a server-issued link (absolute, or an absolute path) and
    /// requires it to stay on this origin.
    func resolveSameOrigin(_ link: String) throws -> URL {
        guard let url = URL(string: link, relativeTo: base)?.absoluteURL, ScopedCredentialDelegate.sameOrigin(url, base) else {
            throw ProviderError.invalidResponse("The server issued a link on a different host.")
        }
        return url
    }

    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = "application/json", extraHeaders: [String: String] = [:]) async throws -> Response {
        try await send(method, url: url(path, query: query), body: body, contentType: contentType, extraHeaders: extraHeaders)
    }

    func send(_ method: String, url: URL, body: Data? = nil, contentType: String? = "application/json", extraHeaders: [String: String] = [:]) async throws -> Response {
        guard ScopedCredentialDelegate.sameOrigin(url, base) else { throw ProviderError.insecureRedirect }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        for (name, value) in headers.merging(extraHeaders, uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }

        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let delegate = ScopedCredentialDelegate(origin: base, credential: credential)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if delegate.rejectedRedirect { throw ProviderError.insecureRedirect }
            if delegate.authenticationRejected { throw ProviderError.authenticationFailed() }
            throw HTTPStatusMapping.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse("Not an HTTP response.") }
        if delegate.rejectedRedirect || (300..<400).contains(http.statusCode) { throw ProviderError.insecureRedirect }
        return Response(data: data, http: http)
    }

    /// GETs JSON and maps non-2xx statuses with `errorMapper`.
    func json<T: Decodable>(_ type: T.Type, _ method: String = "GET", _ path: String, query: [URLQueryItem] = [], body: Data? = nil, decoder: JSONDecoder = JSONDecoder(), errorMapper: (Response) -> ProviderError = HTTPClient.defaultError) async throws -> T {
        let response = try await send(method, path, query: query, body: body, extraHeaders: ["Accept": "application/json"])
        guard response.isSuccess else { throw errorMapper(response) }
        do {
            return try decoder.decode(T.self, from: response.data)
        } catch {
            throw ProviderError.invalidResponse("The server's response to \(path) wasn't in the expected format.")
        }
    }

    static func defaultError(_ response: Response) -> ProviderError {
        switch response.status {
        case 401, 403: .authenticationFailed()
        case 404: .notFound("Not found on the server.")
        case 409: .conflict("The server rejected the change.")
        case 501: .unsupported("The server doesn't support that.")
        case 502, 503, 504: .networkUnavailable("The server reported HTTP \(response.status).")
        default: .invalidResponse("HTTP \(response.status)")
        }
    }
}

/// Dates as ISO 8601 strings (with or without fractional seconds) or Unix
/// seconds, since the servers Camera Monitor talks to use both.
enum FlexibleDate {
    @Sendable static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
        let text = try container.decode(String.self)
        if let date = parse(text) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(text)")
    }

    static func parse(_ text: String) -> Date? {
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        return lock.withLock { fractional.date(from: text) ?? plain.date(from: text) }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decode)
        return decoder
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
}
