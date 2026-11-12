import Foundation

/// Just enough HLS playlist parsing to validate a source before AVPlayer
/// plays it, and to report what it is during Test Connection.
public struct HLSPlaylist: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case multivariant(variantCount: Int)
        case media(segmentCount: Int, isLive: Bool, targetDuration: Double?)
    }

    public var kind: Kind
    public var codecs: [String]
    public var resolutions: [String]

    public enum ParseError: Error, Equatable, LocalizedError {
        case notAPlaylist
        case empty

        public var errorDescription: String? {
            switch self {
            case .notAPlaylist: "The address didn't return an HLS playlist (#EXTM3U)."
            case .empty: "The HLS playlist has no variants or segments."
            }
        }
    }

    public static func parse(_ text: String) throws -> HLSPlaylist {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw ParseError.notAPlaylist }

        var variants = 0
        var segments = 0
        var endList = false
        var targetDuration: Double?
        var codecs: [String] = []
        var resolutions: [String] = []
        var playlistType: String?

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                variants += 1
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                if let value = attributes["CODECS"] {
                    for codec in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !codecs.contains(codec) {
                        codecs.append(codec)
                    }
                }
                if let resolution = attributes["RESOLUTION"], !resolutions.contains(resolution) {
                    resolutions.append(resolution)
                }
            } else if line.hasPrefix("#EXTINF:") {
                segments += 1
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                endList = true
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                playlistType = String(line.dropFirst("#EXT-X-PLAYLIST-TYPE:".count))
            }
        }

        if variants > 0 {
            return HLSPlaylist(kind: .multivariant(variantCount: variants), codecs: codecs, resolutions: resolutions)
        }
        guard segments > 0 else { throw ParseError.empty }
        let isLive = !endList && playlistType != "VOD"
        return HLSPlaylist(kind: .media(segmentCount: segments, isLive: isLive, targetDuration: targetDuration), codecs: codecs, resolutions: resolutions)
    }

    /// Parses `KEY=VALUE,KEY="quoted,value"` attribute lists.
    static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false
        func commit() {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            if !trimmedKey.isEmpty { result[trimmedKey] = value }
            key = ""; value = ""; inKey = true
        }
        for character in text {
            if inKey {
                if character == "=" { inKey = false } else if character != "," { key.append(character) }
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                commit()
            } else {
                value.append(character)
            }
        }
        commit()
        return result
    }

    public var summary: String {
        switch kind {
        case let .multivariant(count):
            var parts = ["Multivariant playlist with \(count) variant\(count == 1 ? "" : "s")"]
            if !resolutions.isEmpty { parts.append(resolutions.joined(separator: ", ")) }
            if !codecs.isEmpty { parts.append("codecs \(codecs.joined(separator: ", "))") }
            return parts.joined(separator: "; ")
        case let .media(count, isLive, _):
            return isLive ? "Live media playlist (\(count) segments in window)" : "Recorded (VOD) playlist with \(count) segments, not a live feed"
        }
    }
}

/// Fetches and validates an HLS playlist using only the stream's own
/// credentials, scoped to its origin.
public struct HLSProbe: Sendable {
    public var configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func probe(_ url: URL, credential: ConnectionCredential?) async throws -> HLSPlaylist {
        let config = configuration
        config.timeoutIntervalForRequest = 10
        config.urlCredentialStorage = nil
        let delegate = ScopedCredentialDelegate(origin: url, credential: credential)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            if delegate.authenticationRejected { throw ProviderError.authenticationFailed() }
            if delegate.rejectedRedirect { throw ProviderError.insecureRedirect }
            throw HTTPStatusMapping.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse("Not an HTTP response.") }
        if let error = HTTPStatusMapping.error(for: http.statusCode, redirectRejected: delegate.rejectedRedirect) { throw error }
        guard data.count < 2_000_000, let text = String(data: data, encoding: .utf8) else {
            throw ProviderError.unsupportedSource(HLSPlaylist.ParseError.notAPlaylist.localizedDescription)
        }
        do {
            return try HLSPlaylist.parse(text)
        } catch {
            throw ProviderError.unsupportedSource(error.localizedDescription)
        }
    }
}
