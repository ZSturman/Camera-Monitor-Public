import Foundation

/// Opens a multipart JPEG stream and yields frames. The stream buffers at
/// most the newest two frames so a slow renderer drops frames instead of
/// growing memory.
public final class MJPEGStream: NSObject, @unchecked Sendable {
    public let url: URL
    private let credential: ConnectionCredential?
    private let headers: [String: String]
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private enum Mode {
        case awaitingResponse
        case multipart(MJPEGParser)
        case parts(pending: Data, count: Int)
    }

    private var mode: Mode = .awaitingResponse
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var scope: ScopedCredentialDelegate
    private let lock = NSLock()

    public init(url: URL, credential: ConnectionCredential?, headers: [String: String] = [:], configuration: URLSessionConfiguration = .ephemeral) {
        self.url = url
        self.credential = credential
        self.headers = headers
        self.configuration = configuration
        scope = ScopedCredentialDelegate(origin: url, credential: credential)
    }

    public func frames() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            lock.lock()
            self.continuation = continuation
            let config = configuration
            config.timeoutIntervalForRequest = 15
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCredentialStorage = nil
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            lock.unlock()

            var request = URLRequest(url: url)
            request.setValue("multipart/x-mixed-replace, image/jpeg", forHTTPHeaderField: "Accept")
            request.httpShouldHandleCookies = false
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            session.dataTask(with: request).resume()

            continuation.onTermination = { [weak self] _ in self?.cancel() }
        }
    }

    public func cancel() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish(throwing: error)
        cancel()
    }
}

extension MJPEGStream: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        scope.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        scope.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(throwing: ProviderError.invalidResponse("Not an HTTP response."))
            return
        }
        if let error = HTTPStatusMapping.error(for: http.statusCode, redirectRejected: scope.rejectedRedirect) {
            completionHandler(.cancel)
            finish(throwing: error)
            return
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        lock.lock()
        if let boundary = MJPEGParser.boundary(fromContentType: contentType) {
            // The raw multipart body is delivered to us; parse it ourselves.
            mode = .multipart(MJPEGParser(boundary: boundary))
        } else if contentType.hasPrefix("image/jpeg") {
            // URLSession splits multipart/x-mixed-replace itself and reports
            // each part as a new response. A new part completes the previous.
            if case let .parts(pending, count) = mode, !pending.isEmpty {
                lock.unlock()
                emit(pending)
                lock.lock()
                mode = .parts(pending: Data(), count: count + 1)
            } else if case let .parts(_, count) = mode {
                mode = .parts(pending: Data(), count: count + 1)
            } else {
                mode = .parts(pending: Data(), count: 1)
            }
        } else {
            lock.unlock()
            completionHandler(.cancel)
            finish(throwing: ProviderError.unsupportedSource("Expected multipart/x-mixed-replace, got \(contentType.isEmpty ? "no content type" : contentType)."))
            return
        }
        lock.unlock()
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        switch mode {
        case var .multipart(parser):
            let result = Result { try parser.append(data) }
            mode = .multipart(parser)
            lock.unlock()
            switch result {
            case let .success(frames): frames.forEach(emit)
            case let .failure(error): finish(throwing: ProviderError.unsupportedSource(error.localizedDescription))
            }
        case .parts(var pending, let count):
            pending.append(data)
            guard pending.count <= Self.maxFrameBytes else {
                lock.unlock()
                finish(throwing: ProviderError.unsupportedSource(MJPEGParser.ParserError.frameTooLarge(limit: Self.maxFrameBytes).localizedDescription))
                return
            }
            // Emit as soon as the JPEG end-of-image marker arrives rather
            // than waiting for the next part's headers.
            if Self.endsWithEOI(pending) {
                mode = .parts(pending: Data(), count: count)
                lock.unlock()
                emit(pending)
            } else {
                mode = .parts(pending: pending, count: count)
                lock.unlock()
            }
        case .awaitingResponse:
            lock.unlock()
        }
    }

    private static let maxFrameBytes = 8 * 1024 * 1024

    static func endsWithEOI(_ data: Data) -> Bool {
        var end = data.endIndex
        // Tolerate trailing CR/LF after the image.
        while end > data.startIndex, data[data.index(before: end)] == 0x0A || data[data.index(before: end)] == 0x0D {
            end = data.index(before: end)
        }
        guard data.distance(from: data.startIndex, to: end) >= 4 else { return false }
        return data[data.index(end, offsetBy: -2)] == 0xFF && data[data.index(before: end)] == 0xD9
            && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    }

    private func emit(_ frame: Data) {
        guard frame.count >= 2, frame[frame.startIndex] == 0xFF, frame[frame.startIndex + 1] == 0xD8 else { return }
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(frame)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if case let .parts(pending, count) = mode, !pending.isEmpty {
            mode = .parts(pending: Data(), count: count)
            lock.unlock()
            emit(pending)
        } else {
            lock.unlock()
        }
        if scope.authenticationRejected {
            finish(throwing: ProviderError.authenticationFailed())
        } else if scope.rejectedRedirect {
            finish(throwing: ProviderError.insecureRedirect)
        } else if let error {
            finish(throwing: HTTPStatusMapping.map(error))
        } else {
            finish(throwing: ProviderError.staleStream(lastFrameAt: nil))
        }
    }
}

enum HTTPStatusMapping {
    static func error(for status: Int, redirectRejected: Bool = false) -> ProviderError? {
        switch status {
        case 200..<300: nil
        case 300..<400: redirectRejected ? .insecureRedirect : .invalidResponse("HTTP \(status) redirect.")
        case 401, 403: .authenticationFailed()
        case 404: .notFound("The stream address wasn't found (HTTP 404).")
        case 415: .unsupportedSource("HTTP 415")
        case 502, 503, 504: .networkUnavailable("The server reported HTTP \(status).")
        default: .invalidResponse("HTTP \(status)")
        }
    }

    static func map(_ error: Error) -> ProviderError {
        if let provider = error as? ProviderError { return provider }
        guard let urlError = error as? URLError else { return .networkUnavailable(error.localizedDescription) }
        // iOS reports Local Network privacy denial as "offline".
        if urlError.code == .notConnectedToInternet, String(describing: (urlError as NSError).userInfo["_NSURLErrorNWPathKey"] ?? "").contains("Local network prohibited") {
            return .networkUnavailable(ProviderError.localNetworkDeniedMessage)
        }
        switch urlError.code {
        case .timedOut: return .timedOut
        case .userAuthenticationRequired, .userCancelledAuthentication: return .authenticationFailed()
        case .cancelled: return .networkUnavailable("The request was cancelled.")
        case .appTransportSecurityRequiresSecureConnection:
            return .invalidAddress("Plain http:// is only allowed for local network addresses (IP addresses, .local names or single-label host names). Use https:// for other hosts.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            return .networkUnavailable("The server's HTTPS certificate isn't trusted.")
        default: return .networkUnavailable(urlError.localizedDescription)
        }
    }
}
