import Foundation
import Network

struct RTSPResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    func headerValues(_ name: String) -> [String] {
        headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map(\.1)
    }
}

/// One message read from an RTSP connection: a response, or an RTP/RTCP
/// packet interleaved on the TCP connection (RFC 2326 §10.12).
enum RTSPMessage: Sendable {
    case response(RTSPResponse)
    case interleaved(channel: UInt8, payload: Data)
    /// A request from the server (e.g. ANNOUNCE); ignored by this client.
    case serverRequest
}

/// A growable byte queue that consumes from the front without copying the
/// remainder on every read.
struct ByteQueue {
    private var storage = Data()
    private var start = 0

    var count: Int { storage.count - start }
    var isEmpty: Bool { count == 0 }

    mutating func append(_ data: Data) {
        if start > 0, start >= storage.count / 2 {
            storage = storage.subdata(in: (storage.startIndex + start)..<storage.endIndex)
            start = 0
        }
        storage.append(data)
    }

    subscript(offset: Int) -> UInt8 { storage[storage.startIndex + start + offset] }

    func slice(_ offset: Int, _ length: Int) -> Data {
        let from = storage.startIndex + start + offset
        return storage.subdata(in: from..<(from + length))
    }

    func firstRange(of pattern: Data, maxScan: Int) -> Range<Int>? {
        let from = storage.startIndex + start
        let upTo = min(storage.endIndex, from + maxScan)
        guard let found = storage.range(of: pattern, in: from..<upTo) else { return nil }
        return (found.lowerBound - from)..<(found.upperBound - from)
    }

    mutating func consume(_ length: Int) {
        start += length
        if start >= storage.count {
            storage.removeAll(keepingCapacity: true)
            start = 0
        }
    }
}

/// Request/response and interleaved media over one NWConnection.
final class RTSPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "CameraCore.RTSPConnection")
    let timeout: TimeInterval
    private var buffer = ByteQueue()

    convenience init(url: URL, timeout: TimeInterval) throws {
        guard let host = url.host, let scheme = url.scheme?.lowercased(), ["rtsp", "rtsps"].contains(scheme) else {
            throw ProviderError.invalidAddress("RTSP addresses start with rtsp:// or rtsps://.")
        }
        self.init(host: host, port: url.port ?? (scheme == "rtsps" ? 322 : 554), useTLS: scheme == "rtsps", timeout: timeout)
    }

    init(host: String, port: Int, useTLS: Bool, timeout: TimeInterval) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        tcp.noDelay = true
        let parameters = useTLS ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)), using: parameters)
        self.timeout = timeout
    }

    func open() async throws {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = LockedFlag()
                self.connection.stateUpdateHandler = { state in
                    guard !resumed.isSet else { return }
                    switch state {
                    case .ready:
                        resumed.set()
                        continuation.resume()
                    case let .waiting(error), let .failed(error):
                        resumed.set()
                        #if os(iOS)
                        if self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                            continuation.resume(throwing: ProviderError.networkUnavailable(ProviderError.localNetworkDeniedMessage))
                            return
                        }
                        #endif
                        continuation.resume(throwing: ProviderError.networkUnavailable(error.localizedDescription))
                    case .cancelled:
                        resumed.set()
                        continuation.resume(throwing: ProviderError.networkUnavailable("Connection cancelled."))
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    func close() {
        connection.cancel()
    }

    /// Sends `data`, then closes once it has been handed to the network.
    func writeThenClose(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    static func encode(method: String, uri: String, headers: [String: String]) -> Data {
        var request = "\(method) \(uri) RTSP/1.0\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            request += "\(name): \(value)\r\n"
        }
        request += "\r\n"
        return Data(request.utf8)
    }

    func write(method: String, uri: String, headers: [String: String]) async throws {
        let data = Self.encode(method: method, uri: uri, headers: headers)
        try await withTimeout {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: ProviderError.networkUnavailable(error.localizedDescription)) } else { continuation.resume() }
                })
            }
        }
    }

    /// Sends a request and waits for its response, skipping any media that
    /// arrives first.
    func send(method: String, uri: String, headers: [String: String]) async throws -> RTSPResponse {
        try await write(method: method, uri: uri, headers: headers)
        return try await withTimeout {
            while true {
                if case let .response(response) = try await self.readMessage() { return response }
            }
        }
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 256 * 1024
    private static let rtspPrefix = Array("RTSP/".utf8)

    /// Reads the next complete message. No timeout of its own: the media
    /// loop applies a frame watchdog instead.
    func readMessage() async throws -> RTSPMessage {
        while true {
            if let message = try parseMessage() { return message }
            guard buffer.count <= Self.maxHeaderBytes + Self.maxBodyBytes else {
                throw ProviderError.invalidResponse("RTSP response too large.")
            }
            buffer.append(try await receive())
        }
    }

    func parseMessage() throws -> RTSPMessage? {
        guard !buffer.isEmpty else { return nil }
        if buffer[0] == 0x24 { // "$": interleaved binary data
            guard buffer.count >= 4 else { return nil }
            let length = Int(buffer[2]) << 8 | Int(buffer[3])
            guard buffer.count >= 4 + length else { return nil }
            let channel = buffer[1]
            let payload = buffer.slice(4, length)
            buffer.consume(4 + length)
            return .interleaved(channel: channel, payload: payload)
        }
        guard let headerEnd = buffer.firstRange(of: Self.headerTerminator, maxScan: Self.maxHeaderBytes) else {
            if buffer.count >= 5, !(0..<5).allSatisfy({ buffer[$0] == Self.rtspPrefix[$0] }), !Self.looksLikeRequest(buffer) {
                throw ProviderError.unsupportedSource("The server didn't answer with RTSP. Check the address and port.")
            }
            if buffer.count > Self.maxHeaderBytes { throw ProviderError.invalidResponse("RTSP response too large.") }
            return nil
        }
        let head = String(decoding: buffer.slice(0, headerEnd.lowerBound), as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let startLine = lines.removeFirst()
        let headers: [(String, String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).trimmingCharacters(in: .whitespaces), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        let length = headers.first { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }.flatMap { Int($0.1) } ?? 0
        guard length >= 0, length <= Self.maxBodyBytes else { throw ProviderError.invalidResponse("RTSP response too large.") }
        guard buffer.count - headerEnd.upperBound >= length else { return nil }
        let body = buffer.slice(headerEnd.upperBound, length)
        buffer.consume(headerEnd.upperBound + length)

        let parts = startLine.split(separator: " ", maxSplits: 2)
        if parts.count >= 2, parts[0].hasPrefix("RTSP/"), let status = Int(parts[1]) {
            return .response(RTSPResponse(status: status, headers: headers, body: body))
        }
        if parts.count == 3, parts[2].hasPrefix("RTSP/") { return .serverRequest }
        throw ProviderError.unsupportedSource("The server didn't answer with RTSP. Check the address and port.")
    }

    private static func looksLikeRequest(_ buffer: ByteQueue) -> Bool {
        // Server-to-client requests start with an uppercase method name.
        (0..<min(buffer.count, 4)).allSatisfy { (0x41...0x5A).contains(buffer[$0]) || buffer[$0] == 0x5F }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: ProviderError.networkUnavailable(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ProviderError.networkUnavailable("The camera closed the connection."))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func withTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let timeout = self.timeout
        let timedOut = LockedFlag()
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    // Cancelling the connection resumes any pending callback
                    // so the group can finish.
                    timedOut.set()
                    self.close()
                    throw ProviderError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw ProviderError.timedOut }
                return result
            }
        } catch {
            throw timedOut.isSet ? ProviderError.timedOut : error
        }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); value = true; lock.unlock()
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
