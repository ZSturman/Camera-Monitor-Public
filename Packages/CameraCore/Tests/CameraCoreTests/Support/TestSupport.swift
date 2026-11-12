import Foundation
import Network
@testable import CameraCore

enum Fixture {
    static func url(_ path: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }
}

/// Serves canned responses to URLSessions configured with
/// `StubURLProtocol.configuration()`. Handlers are keyed by host so tests
/// using different hosts don't interfere.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case response(status: Int, headers: [String: String], chunks: [Data])
        case redirect(to: URL)
        /// Mimics URLSession's own multipart/x-mixed-replace handling: one
        /// `image/jpeg` response per part.
        case replacingParts([Data])
        case failure(URLError.Code)
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func register(host: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers = [:]
        requests = []
    }

    static func recordedRequests(host: String? = nil) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { host == nil || $0.url?.host == host }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    static func json(_ fixture: String, status: Int = 200) -> Reply {
        .response(status: status, headers: ["Content-Type": "application/json"], chunks: [(try? Fixture.data(fixture)) ?? Data()])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = request.url?.host.flatMap { Self.handlers[$0] }
        Self.lock.unlock()

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch handler(request) {
        case let .response(status, headers, chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var next = URLRequest(url: target)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // If the session refuses the redirect, the 302 itself is the
            // final response, as with a real server.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case let .replacingParts(parts):
            for part in parts {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/jpeg", "Content-Length": "\(part.count)"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: part)
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

/// A scripted RTSP server on 127.0.0.1 for probe tests. Each received
/// request is passed to `respond`, which returns the raw reply to send
/// (or nil to stay silent).
final class FakeRTSPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeRTSPServer")
    private let respond: @Sendable (_ request: String) -> String?
    private let lock = NSLock()
    private var received: [String] = []
    private var connections: [NWConnection] = []

    init(respond: @escaping @Sendable (_ request: String) -> String?) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.respond = respond
    }

    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [listener] state in
                // Called serially on `queue`.
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener.port!.rawValue)
                case let .failed(error):
                    once.done = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock(); connections.forEach { $0.cancel() }; lock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let request = String(decoding: buffer[..<end.upperBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                self.lock.lock(); self.received.append(request); self.lock.unlock()
                if let reply = self.respond(request) {
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
                }
            }
            if !isComplete { self.read(connection, buffer: buffer) }
        }
    }

    static func header(_ name: String, in request: String) -> String? {
        for line in request.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].caseInsensitiveCompare(name) == .orderedSame {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

extension ConnectionProfile {
    static func fixture(_ kind: ConnectionKind, _ address: String, name: String = "Fixture") -> ConnectionProfile {
        ConnectionProfile(name: name, kind: kind, address: URL(string: address)!)
    }
}
