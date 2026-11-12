import Foundation

/// Stable identity for a camera: the local connection plus the provider's
/// own resource ID (Home Services camera ID, or `stream` for a bare URL).
public struct CameraID: Codable, Hashable, Sendable {
    public var connectionID: UUID
    public var nativeID: String

    public init(connectionID: UUID, nativeID: String) {
        self.connectionID = connectionID
        self.nativeID = nativeID
    }

    public static let directStreamNativeID = "stream"
}

public enum StreamProtocol: String, Codable, Sendable, CaseIterable {
    case hls
    case mjpeg
    case rtsp
    /// A progressive video file (recordings), played by AVPlayer.
    case mp4
    /// A camera attached to this device (Mac USB/built-in, iPad USB-C).
    case localDevice

    public var displayName: String {
        switch self {
        case .hls: "HLS"
        case .mjpeg: "MJPEG"
        case .rtsp: "RTSP"
        case .mp4: "MP4"
        case .localDevice: "Local camera"
        }
    }
}

/// Whether a provider supplies a feature for a camera, with the reason when
/// it does not. Unsupported is reported explicitly, never as empty success.
public enum FeatureSupport: Codable, Hashable, Sendable {
    case supported
    case unsupported(reason: String)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    public var reason: String? {
        if case let .unsupported(reason) = self { return reason }
        return nil
    }
}

public enum DeletionGranularity: String, Codable, Hashable, Sendable {
    case recording
    case interval

    public var displayName: String {
        switch self {
        case .recording: "Whole recordings"
        case .interval: "Time intervals"
        }
    }
}

public struct CameraCapabilities: Codable, Hashable, Sendable {
    /// The protocol used for live view, or nil when live view is unavailable.
    public var liveView: StreamProtocol?
    public var liveViewUnavailableReason: String?
    public var history: FeatureSupport
    public var playback: FeatureSupport
    public var export: FeatureSupport
    public var deletion: FeatureSupport
    public var deletionGranularity: DeletionGranularity?
    public var serverRecording: FeatureSupport
    public var motionEvents: FeatureSupport
    /// Notification delivery from an always-on sender (ntfy), not the phone.
    public var notifications: FeatureSupport
    public var notificationTransport: String?
    public var arming: FeatureSupport
    public var settings: FeatureSupport
    /// A still image on demand (for tiles and widgets), separate from live view.
    public var snapshot: FeatureSupport
    /// Marking recordings protected so retention and deletion skip them.
    public var protection: FeatureSupport = .unsupported(reason: "This source can't protect recordings.")
    /// What arming does on this provider, e.g. "motion notifications only".
    public var armingEffect: String?

    public init(
        liveView: StreamProtocol?,
        liveViewUnavailableReason: String? = nil,
        history: FeatureSupport,
        playback: FeatureSupport,
        export: FeatureSupport,
        deletion: FeatureSupport,
        deletionGranularity: DeletionGranularity? = nil,
        serverRecording: FeatureSupport,
        motionEvents: FeatureSupport,
        notifications: FeatureSupport,
        notificationTransport: String? = nil,
        arming: FeatureSupport,
        settings: FeatureSupport,
        snapshot: FeatureSupport = .unsupported(reason: "This source doesn't provide still images.")
    ) {
        self.liveView = liveView
        self.liveViewUnavailableReason = liveViewUnavailableReason
        self.history = history
        self.playback = playback
        self.export = export
        self.deletion = deletion
        self.deletionGranularity = deletionGranularity
        self.serverRecording = serverRecording
        self.motionEvents = motionEvents
        self.notifications = notifications
        self.notificationTransport = notificationTransport
        self.arming = arming
        self.settings = settings
        self.snapshot = snapshot
    }

    /// Nothing but what's explicitly granted; used as a starting point.
    public static func none(reason: String) -> CameraCapabilities {
        CameraCapabilities(
            liveView: nil, liveViewUnavailableReason: reason,
            history: .unsupported(reason: reason), playback: .unsupported(reason: reason),
            export: .unsupported(reason: reason), deletion: .unsupported(reason: reason),
            serverRecording: .unsupported(reason: reason), motionEvents: .unsupported(reason: reason),
            notifications: .unsupported(reason: reason), arming: .unsupported(reason: reason),
            settings: .unsupported(reason: reason)
        )
    }

    /// A bare stream URL supplies live view and nothing else. It must never
    /// appear to record, keep history, detect motion, or be armed.
    public static func directStream(_ streamProtocol: StreamProtocol) -> CameraCapabilities {
        let reason = "A bare \(streamProtocol.displayName) stream only provides live view. Recording, history and motion alerts need a camera, NVR or always-on recorder."
        return CameraCapabilities(
            liveView: streamProtocol,
            history: .unsupported(reason: reason),
            playback: .unsupported(reason: reason),
            export: .unsupported(reason: reason),
            deletion: .unsupported(reason: reason),
            serverRecording: .unsupported(reason: "Nothing records this stream while the app is closed. Watching live does not record."),
            motionEvents: .unsupported(reason: reason),
            notifications: .unsupported(reason: "Motion alerts need an always-on event source and notification sender; this phone or Mac is not a motion detector."),
            arming: .unsupported(reason: "There is no recorder to arm for a bare stream."),
            settings: .unsupported(reason: "Camera settings are not available through a stream URL.")
        )
    }
}

public enum CameraState: String, Codable, Hashable, Sendable {
    case online
    case offline
    case authenticationFailed
    case disconnectedHardware
    case staleStream
    case recorderUnavailable
    case storageUnavailable
    case unknown

    public var displayName: String {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .authenticationFailed: "Sign-in failed"
        case .disconnectedHardware: "Camera disconnected"
        case .staleStream: "Stream stale"
        case .recorderUnavailable: "Recorder unavailable"
        case .storageUnavailable: "Storage unavailable"
        case .unknown: "Unknown"
        }
    }
}

public struct CameraStatus: Codable, Hashable, Sendable {
    public var state: CameraState
    public var detail: String?
    public var observedAt: Date
    /// Only reported by providers that actually have a recorder to arm.
    public var armed: Bool?
    public var recording: Bool?

    public init(state: CameraState, detail: String? = nil, observedAt: Date, armed: Bool? = nil, recording: Bool? = nil) {
        self.state = state
        self.detail = detail
        self.observedAt = observedAt
        self.armed = armed
        self.recording = recording
    }
}

public struct CameraDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var id: CameraID
    public var name: String
    public var capabilities: CameraCapabilities
    public var status: CameraStatus?

    public init(id: CameraID, name: String, capabilities: CameraCapabilities, status: CameraStatus?) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.status = status
    }
}

/// What a player needs to show a stream. `credential` is only for the
/// stream's own host; Home Services sessions are opaque URLs and carry none.
public struct StreamSession: Hashable, Sendable {
    public var url: URL
    public var streamProtocol: StreamProtocol
    public var credential: ConnectionCredential?
    public var expiresAt: Date?
    /// Header-based auth for URLSession players (MJPEG), same origin only.
    public var headers: [String: String]
    /// Cookie-based auth for AVPlayer, which can't add headers. Sent only
    /// to the session URL's host.
    public var cookies: [SessionCookie]
    /// For local-device sessions: the AVCaptureDevice unique ID.
    public var deviceID: String?

    public init(url: URL, streamProtocol: StreamProtocol, credential: ConnectionCredential? = nil, expiresAt: Date? = nil, headers: [String: String] = [:], cookies: [SessionCookie] = [], deviceID: String? = nil) {
        self.url = url
        self.streamProtocol = streamProtocol
        self.credential = credential
        self.expiresAt = expiresAt
        self.headers = headers
        self.cookies = cookies
        self.deviceID = deviceID
    }
}

public struct SessionCookie: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

extension StreamSession: CustomStringConvertible {
    // Headers and cookies carry secrets; keep them out of logs.
    public var description: String { "StreamSession(\(streamProtocol.rawValue), \(AddressParser.redacted(url)))" }
}

public struct Recording: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case motion
        case continuous
        case manual
        case other
    }

    public var id: String
    public var camera: CameraID
    public var startedAt: Date
    public var endedAt: Date?
    public var kind: Kind
    public var sizeBytes: Int64?
    /// Provider-protected media cannot be deleted from the app.
    public var isProtected: Bool
    /// Still being written; deleting it is rejected.
    public var isActive: Bool
    /// What was detected, e.g. "person" (NVR events).
    public var label: String?
    /// Read-only archives (e.g. predecessor media) can never be deleted.
    public var isReadOnly: Bool
    /// Provider-specific details the provider needs later (never secrets).
    public var metadata: [String: String]

    public init(id: String, camera: CameraID, startedAt: Date, endedAt: Date?, kind: Kind, sizeBytes: Int64?, isProtected: Bool, isActive: Bool, label: String? = nil, isReadOnly: Bool = false, metadata: [String: String] = [:]) {
        self.id = id
        self.camera = camera
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.isProtected = isProtected
        self.isActive = isActive
        self.label = label
        self.isReadOnly = isReadOnly
        self.metadata = metadata
    }

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    public var deletionBlockedReason: String? {
        if isReadOnly { return "This archive is read-only; it can't be deleted from the app." }
        if isActive { return "This recording is still being written and can't be deleted yet." }
        if isProtected { return "This recording is protected by the server and can't be deleted from the app." }
        return nil
    }
}

public struct RecordingPage: Hashable, Sendable {
    public var recordings: [Recording]
    public var nextCursor: String?

    public init(recordings: [Recording], nextCursor: String?) {
        self.recordings = recordings
        self.nextCursor = nextCursor
    }
}

public struct RecordingExport: Hashable, Sendable, CustomStringConvertible {
    public var description: String { "RecordingExport(\(AddressParser.redacted(downloadURL)))" }
    public var downloadURL: URL
    public var suggestedFilename: String
    public var contentType: String?
    public var expiresAt: Date?
    /// Auth headers for the download, sent only to `downloadURL`'s origin.
    public var headers: [String: String]

    public init(downloadURL: URL, suggestedFilename: String, contentType: String?, expiresAt: Date?, headers: [String: String] = [:]) {
        self.downloadURL = downloadURL
        self.suggestedFilename = suggestedFilename
        self.contentType = contentType
        self.expiresAt = expiresAt
        self.headers = headers
    }
}
