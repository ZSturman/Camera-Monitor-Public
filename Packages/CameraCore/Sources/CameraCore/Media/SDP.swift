import Foundation

/// The parts of an RTSP DESCRIBE session description Camera Monitor uses
/// to report what a camera offers and to set up a video track.
public struct SessionDescription: Equatable, Sendable {
    public struct Media: Equatable, Sendable {
        public var type: String
        public var codec: String?
        public var clockRate: Int?
        /// The first payload type listed on the `m=` line.
        public var payloadType: Int?
        /// `a=control`, absolute or relative to the content base.
        public var control: String?
        /// `a=fmtp` parameters for `payloadType`, keys lowercased.
        public var formatParameters: [String: String] = [:]

        public init(type: String, codec: String? = nil, clockRate: Int? = nil, payloadType: Int? = nil, control: String? = nil, formatParameters: [String: String] = [:]) {
            self.type = type
            self.codec = codec
            self.clockRate = clockRate
            self.payloadType = payloadType
            self.control = control
            self.formatParameters = formatParameters
        }
    }

    public var sessionName: String?
    public var media: [Media]
    /// Session-level `a=control`, used for aggregate PLAY.
    public var control: String?

    public init(sessionName: String? = nil, media: [Media], control: String? = nil) {
        self.sessionName = sessionName
        self.media = media
        self.control = control
    }

    public static func parse(_ text: String) -> SessionDescription {
        var sessionName: String?
        var sessionControl: String?
        var media: [Media] = []
        var payloadTypes: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("s=") {
                let name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                sessionName = name.isEmpty || name == "-" ? nil : name
            } else if line.hasPrefix("m=") {
                let parts = line.dropFirst(2).split(separator: " ")
                payloadTypes = parts.count > 3 ? parts[3...].map(String.init) : []
                media.append(Media(type: parts.first.map(String.init) ?? "unknown", payloadType: payloadTypes.first.flatMap { Int($0) }))
            } else if line.hasPrefix("a=control:") {
                let value = String(line.dropFirst("a=control:".count)).trimmingCharacters(in: .whitespaces)
                if media.isEmpty { sessionControl = value } else { media[media.count - 1].control = value }
            } else if line.hasPrefix("a=rtpmap:"), !media.isEmpty, media[media.count - 1].codec == nil {
                let mapping = line.dropFirst("a=rtpmap:".count).split(separator: " ", maxSplits: 1)
                guard mapping.count == 2, payloadTypes.isEmpty || payloadTypes.first == String(mapping[0]) else { continue }
                let encoding = mapping[1].split(separator: "/")
                media[media.count - 1].codec = encoding.first.map { $0.uppercased() }
                media[media.count - 1].clockRate = encoding.count > 1 ? Int(encoding[1]) : nil
            } else if line.hasPrefix("a=fmtp:"), !media.isEmpty {
                let mapping = line.dropFirst("a=fmtp:".count).split(separator: " ", maxSplits: 1)
                guard mapping.count == 2, payloadTypes.first == String(mapping[0]) else { continue }
                for pair in mapping[1].split(separator: ";") {
                    let keyValue = pair.split(separator: "=", maxSplits: 1)
                    guard let key = keyValue.first?.trimmingCharacters(in: .whitespaces).lowercased(), !key.isEmpty else { continue }
                    media[media.count - 1].formatParameters[key] = keyValue.count > 1 ? keyValue[1].trimmingCharacters(in: .whitespaces) : ""
                }
            }
        }
        // Static RTP payload types that don't need an rtpmap line.
        for index in media.indices where media[index].codec == nil {
            media[index].codec = media[index].payloadType.flatMap { Self.staticPayloadNames[$0] }
        }
        return SessionDescription(sessionName: sessionName, media: media, control: sessionControl)
    }

    private static let staticPayloadNames = [0: "PCMU", 8: "PCMA", 14: "MPA", 26: "JPEG", 32: "MPV", 33: "MP2T"]

    public var videoCodecs: [String] { media.filter { $0.type == "video" }.compactMap(\.codec) }
    public var audioCodecs: [String] { media.filter { $0.type == "audio" }.compactMap(\.codec) }

    public var summary: String {
        var parts: [String] = []
        parts.append(videoCodecs.isEmpty ? "no video track" : "video \(videoCodecs.joined(separator: ", "))")
        if !audioCodecs.isEmpty { parts.append("audio \(audioCodecs.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }

    /// The first video track the native player can decode.
    public var playableVideoTrack: Media? {
        media.first { $0.type == "video" && VideoCodec(sdpName: $0.codec) != nil }
    }

    /// Resolves a track or session control attribute against the content
    /// base, per RFC 2326 C.1.1.
    public static func resolve(control: String?, base: URL) -> URL {
        guard let control, !control.isEmpty, control != "*" else { return base }
        if let absolute = URL(string: control), absolute.scheme != nil { return absolute }
        var baseString = base.absoluteString
        if !baseString.hasSuffix("/") { baseString += "/" }
        return URL(string: baseString + control) ?? base
    }
}

public enum VideoCodec: String, Sendable, Equatable {
    case h264
    case h265

    public init?(sdpName: String?) {
        switch sdpName?.uppercased() {
        case "H264": self = .h264
        case "H265", "HEVC": self = .h265
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .h265: "H.265"
        }
    }

    /// Out-of-band parameter sets from `a=fmtp` (SPS/PPS, plus VPS for H.265).
    public func parameterSets(from formatParameters: [String: String]) -> [Data] {
        func decode(_ key: String) -> [Data] {
            (formatParameters[key] ?? "").split(separator: ",").compactMap { Data(base64Encoded: String($0).paddedBase64) }
        }
        switch self {
        case .h264: return decode("sprop-parameter-sets")
        case .h265: return decode("sprop-vps") + decode("sprop-sps") + decode("sprop-pps")
        }
    }
}

extension String {
    /// Cameras often omit base64 padding in SDP.
    var paddedBase64: String {
        let remainder = count % 4
        return remainder == 0 ? self : self + String(repeating: "=", count: 4 - remainder)
    }
}
