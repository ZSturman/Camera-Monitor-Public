import Foundation

/// The kinds of connection Camera Monitor can talk to directly. Each one is
/// independent: no kind requires another provider to be reachable.
public enum ConnectionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case rtsp
    case hls
    case mjpeg
    case onvif
    case go2rtc
    case frigate
    case workspaceCamera
    case homeServices
    case localDevice

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .homeServices: "Home Services"
        case .hls: "HLS stream"
        case .mjpeg: "MJPEG stream"
        case .rtsp: "RTSP camera"
        case .onvif: "ONVIF camera"
        case .go2rtc: "go2rtc server"
        case .frigate: "Frigate NVR"
        case .workspaceCamera: "Workspace Sync camera"
        case .localDevice: "Cameras on this device"
        }
    }

    public var summary: String {
        switch self {
        case .homeServices:
            "An optional always-on server. Shows exactly what it advertises for each camera."
        case .hls:
            "An HTTP Live Streaming (.m3u8) URL. Live view only."
        case .mjpeg:
            "A multipart JPEG stream, common on simple IP cameras. Live view only."
        case .rtsp:
            "A network camera's RTSP URL (H.264 or H.265). Live view only."
        case .onvif:
            "A network camera that speaks ONVIF. Finds its streams and snapshot address for you."
        case .go2rtc:
            "A go2rtc streaming server. Lists all of its streams; live view and snapshots."
        case .frigate:
            "A Frigate NVR: cameras, recordings, detection events and snapshots."
        case .workspaceCamera:
            "The Pi camera dashboard from Workspace Sync & Backup Utility: live view, motion events and out-of-house mode."
        case .localDevice:
            "Built-in and USB cameras attached to this Mac or iPad. Live view on this device only."
        }
    }

    public var addressPlaceholder: String {
        switch self {
        case .homeServices: "https://host.example.net"
        case .hls: "https://camera.local/live/index.m3u8"
        case .mjpeg: "http://192.168.1.20/video.mjpg"
        case .rtsp: "rtsp://192.168.1.20:554/stream1"
        case .onvif: "192.168.1.20 or http://192.168.1.20/onvif/device_service"
        case .go2rtc: "http://192.168.1.10:1984"
        case .frigate: "http://192.168.1.10:5000 or https://frigate.local:8971"
        case .workspaceCamera: "https://host.example.net"
        case .localDevice: ""
        }
    }

    /// The scheme assumed when an address is typed without one.
    public var defaultScheme: String {
        switch self {
        case .rtsp: "rtsp"
        case .onvif, .go2rtc, .frigate, .mjpeg: "http"
        case .localDevice: "camera-monitor-local"
        case .hls, .homeServices, .workspaceCamera: "https"
        }
    }

    public var allowedSchemes: Set<String> {
        switch self {
        case .rtsp: ["rtsp", "rtsps"]
        case .localDevice: ["camera-monitor-local"]
        default: ["https", "http"]
        }
    }

    public var credentialStyle: CredentialStyle {
        switch self {
        case .homeServices, .workspaceCamera: .token
        case .localDevice: .none
        case .hls, .mjpeg, .rtsp, .onvif, .go2rtc, .frigate: .usernamePassword
        }
    }

    public var tokenLabel: String {
        switch self {
        case .workspaceCamera: "Dashboard token"
        default: "Access token"
        }
    }

    /// A single stream URL: exactly one camera, live view only.
    public var isDirectStream: Bool { [.hls, .mjpeg, .rtsp].contains(self) }

    /// Kinds whose camera status comes from watching the stream, because
    /// nothing reports it while you aren't watching.
    public var playerReportsStatus: Bool { [.hls, .mjpeg, .rtsp, .onvif, .go2rtc, .localDevice].contains(self) }

    public static let localDeviceAddress = URL(string: "camera-monitor-local://devices")!
}

public enum CredentialStyle: String, Codable, Sendable {
    case usernamePassword
    case token
    case none
}

/// Per-connection preferences that aren't secrets.
public struct ConnectionOptions: Codable, Hashable, Sendable {
    /// go2rtc: which of the server's outputs to play.
    public var preferredProtocol: StreamProtocol?
    /// ONVIF/Frigate: prefer a camera's lower-resolution substream.
    public var preferSubstream: Bool?
    /// ONVIF: the media profile token chosen per camera.
    public var onvifProfiles: [String: String]?
    /// ntfy topic this connection's server publishes alerts to.
    public var notifications: NotificationSubscription?

    public init(preferredProtocol: StreamProtocol? = nil, preferSubstream: Bool? = nil, onvifProfiles: [String: String]? = nil, notifications: NotificationSubscription? = nil) {
        self.preferredProtocol = preferredProtocol
        self.preferSubstream = preferSubstream
        self.onvifProfiles = onvifProfiles
        self.notifications = notifications
    }

    public var isEmpty: Bool { self == ConnectionOptions() }
}

/// Where an always-on sender (the camera server, an NVR automation) posts
/// alerts. Camera Monitor reads it and helps subscribe the ntfy app for
/// delivery to a locked phone; the phone is never the motion detector.
public struct NotificationSubscription: Codable, Hashable, Sendable {
    public var server: URL
    public var topic: String
    /// Whether an access token for the topic is in the Keychain.
    public var hasToken: Bool

    public init(server: URL = URL(string: "https://ntfy.sh")!, topic: String, hasToken: Bool = false) {
        self.server = server
        self.topic = topic
        self.hasToken = hasToken
    }

    public var topicURL: URL { server.appendingPathComponent(topic) }
}

/// Nonsecret connection settings persisted on disk. Secrets live in the
/// app's Keychain under `id`; they are never stored or logged here.
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ConnectionKind
    public var address: URL
    public var hasCredential: Bool
    public var createdAt: Date
    public var options: ConnectionOptions

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ConnectionKind,
        address: URL,
        hasCredential: Bool = false,
        createdAt: Date = Date(),
        options: ConnectionOptions = ConnectionOptions()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.address = address
        self.hasCredential = hasCredential
        // Whole seconds, so the value survives the ISO 8601 profile file.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, address, hasCredential, createdAt, options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(ConnectionKind.self, forKey: .kind)
        address = try container.decode(URL.self, forKey: .address)
        hasCredential = try container.decode(Bool.self, forKey: .hasCredential)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Version 1 files predate options.
        options = try container.decodeIfPresent(ConnectionOptions.self, forKey: .options) ?? ConnectionOptions()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(address, forKey: .address)
        try container.encode(hasCredential, forKey: .hasCredential)
        try container.encode(createdAt, forKey: .createdAt)
        if !options.isEmpty { try container.encode(options, forKey: .options) }
    }
}

/// A secret attached to one connection profile. `password` holds the
/// password for direct streams or the access token for token-based servers.
public struct ConnectionCredential: Codable, Hashable, Sendable {
    public var username: String?
    public var password: String

    public init(username: String? = nil, password: String) {
        self.username = username
        self.password = password
    }

    public var isEmpty: Bool { (username ?? "").isEmpty && password.isEmpty }
}

extension ConnectionCredential: CustomStringConvertible, CustomDebugStringConvertible {
    // Keep secrets out of print/dump/log interpolation.
    public var description: String { "ConnectionCredential(username: \(username == nil ? "nil" : "<set>"), password: <redacted>)" }
    public var debugDescription: String { description }
}
