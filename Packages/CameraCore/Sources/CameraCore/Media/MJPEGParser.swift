import Foundation

/// Incremental parser for `multipart/x-mixed-replace` JPEG streams.
/// Memory is bounded: a part larger than `maxFrameBytes` is an error rather
/// than an unbounded buffer.
public struct MJPEGParser: Sendable {
    public enum ParserError: Error, Equatable, LocalizedError {
        case frameTooLarge(limit: Int)
        case missingBoundary

        public var errorDescription: String? {
            switch self {
            case let .frameTooLarge(limit):
                "A frame exceeded the \(limit / 1_000_000) MB limit; this doesn't look like an MJPEG stream."
            case .missingBoundary:
                "The stream didn't declare a multipart boundary."
            }
        }
    }

    private let delimiter: Data
    private let maxFrameBytes: Int
    private var buffer = Data()

    public init(boundary: String, maxFrameBytes: Int = 8 * 1024 * 1024) {
        let trimmed = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        // RFC 2046 delimiters are "--" + boundary; some cameras already
        // include the dashes in the declared boundary.
        delimiter = Data((trimmed.hasPrefix("--") ? trimmed : "--" + trimmed).utf8)
        self.maxFrameBytes = maxFrameBytes
    }

    /// Extracts the boundary parameter from a Content-Type header value.
    public static func boundary(fromContentType contentType: String) -> String? {
        guard contentType.lowercased().hasPrefix("multipart/") else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else { continue }
            let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Feed received bytes; returns each complete JPEG part in order.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while let frame = try nextFrame() {
            frames.append(frame)
        }
        if buffer.count > maxFrameBytes + 4096 {
            throw ParserError.frameTooLarge(limit: maxFrameBytes)
        }
        return frames
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let crlf = Data("\r\n".utf8)

    private mutating func nextFrame() throws -> Data? {
        while true {
            guard let start = buffer.range(of: delimiter) else {
                // Keep only a tail that could still contain a split delimiter.
                if buffer.count > delimiter.count { buffer = Data(buffer.suffix(delimiter.count)) }
                return nil
            }
            guard let headerEnd = buffer.range(of: Self.headerTerminator, in: start.upperBound..<buffer.endIndex) else {
                return nil
            }
            let headerData = buffer[start.upperBound..<headerEnd.lowerBound]
            let headers = Self.parseHeaders(headerData)
            let bodyStart = headerEnd.upperBound

            var body: Data
            var consumedThrough: Data.Index
            if let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0 {
                guard length <= maxFrameBytes else { throw ParserError.frameTooLarge(limit: maxFrameBytes) }
                guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
                let bodyEnd = buffer.index(bodyStart, offsetBy: length)
                body = Data(buffer[bodyStart..<bodyEnd])
                consumedThrough = bodyEnd
            } else {
                guard let next = buffer.range(of: delimiter, in: bodyStart..<buffer.endIndex) else { return nil }
                var bodyEnd = next.lowerBound
                if buffer.distance(from: bodyStart, to: bodyEnd) >= 2,
                   buffer[buffer.index(bodyEnd, offsetBy: -2)..<bodyEnd] == Self.crlf {
                    bodyEnd = buffer.index(bodyEnd, offsetBy: -2)
                }
                body = Data(buffer[bodyStart..<bodyEnd])
                consumedThrough = next.lowerBound
            }
            buffer = Data(buffer[consumedThrough...])

            // Skip non-JPEG parts (some cameras interleave text/metadata).
            if body.count >= 2, body[body.startIndex] == 0xFF, body[body.startIndex + 1] == 0xD8 {
                return body
            }
        }
    }

    private static func parseHeaders(_ data: Data) -> [String: String] {
        var headers: [String: String] = [:]
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }
}
