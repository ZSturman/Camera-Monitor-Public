import Foundation

/// Errors a provider can report. Each case maps to a distinct user-facing
/// explanation; none of them is ever turned into an empty success.
public enum ProviderError: Error, Equatable, Sendable, LocalizedError {
    case authenticationFailed(String? = nil)
    case unsupported(String)
    case networkUnavailable(String)
    case timedOut
    case unsupportedSource(String)
    case disconnectedHardware(String?)
    case staleStream(lastFrameAt: Date?)
    case recorderUnavailable(String?)
    case storageUnavailable(String?)
    case contractVersionMismatch(server: [String], client: String)
    case conflict(String)
    case notFound(String)
    case insecureRedirect
    case invalidAddress(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .authenticationFailed(detail):
            detail ?? "The username, password or token was rejected."
        case let .unsupported(reason):
            reason
        case let .networkUnavailable(detail):
            "Couldn't reach the camera or server: \(detail)"
        case .timedOut:
            "The camera or server didn't respond in time."
        case let .unsupportedSource(detail):
            "Unsupported stream or codec: \(detail)"
        case let .disconnectedHardware(detail):
            detail ?? "The camera hardware is disconnected."
        case let .staleStream(lastFrameAt):
            if let lastFrameAt {
                "The stream stopped updating (last frame \(lastFrameAt.formatted(.relative(presentation: .named))))."
            } else {
                "The stream stopped updating."
            }
        case let .recorderUnavailable(detail):
            detail ?? "The server's recorder is unavailable."
        case let .storageUnavailable(detail):
            detail ?? "The server's recording storage is unavailable."
        case let .contractVersionMismatch(server, client):
            "This server supports API version \(server.isEmpty ? "unknown" : server.joined(separator: ", ")), but this app needs version \(client). Update the server or the app."
        case let .conflict(detail):
            detail
        case let .notFound(detail):
            detail
        case .insecureRedirect:
            "The server redirected to a different address. Credentials were not sent; check the connection address."
        case let .invalidAddress(detail):
            detail
        case let .invalidResponse(detail):
            "Unexpected response: \(detail)"
        }
    }

    public var cameraState: CameraState {
        switch self {
        case .authenticationFailed: .authenticationFailed
        case .disconnectedHardware: .disconnectedHardware
        case .staleStream: .staleStream
        case .recorderUnavailable: .recorderUnavailable
        case .storageUnavailable: .storageUnavailable
        case .networkUnavailable, .timedOut: .offline
        default: .unknown
        }
    }
}

extension ProviderError {
    public static let localNetworkDeniedMessage = "Local Network access is off for Camera Monitor. Turn it on in Settings › Privacy & Security › Local Network."
}

public struct ConnectionTestReport: Hashable, Sendable {
    public var serverName: String?
    public var cameras: [CameraDescriptor]
    /// Facts discovered during the test, e.g. codecs or playlist type.
    public var notes: [String]
    public var testedAt: Date

    public init(serverName: String? = nil, cameras: [CameraDescriptor], notes: [String], testedAt: Date = Date()) {
        self.serverName = serverName
        self.cameras = cameras
        self.notes = notes
        self.testedAt = testedAt
    }
}

/// One connection's provider. Feature calls that the provider doesn't
/// supply throw `ProviderError.unsupported`; callers gate UI on
/// `CameraCapabilities` first.
public protocol CameraProvider: Sendable {
    var profile: ConnectionProfile { get }

    func testConnection() async throws -> ConnectionTestReport
    func cameras() async throws -> [CameraDescriptor]
    func liveSession(for camera: CameraID) async throws -> StreamSession

    func recordings(for camera: CameraID, cursor: String?) async throws -> RecordingPage
    func playbackSession(for recording: Recording) async throws -> StreamSession
    func export(_ recording: Recording) async throws -> RecordingExport
    func delete(_ recording: Recording) async throws
    func setArmed(_ armed: Bool, for camera: CameraID) async throws -> Bool
    /// A JPEG still for tiles and widgets.
    func snapshot(for camera: CameraID) async throws -> Data
    /// Camera-specific settings the provider exposes.
    func settings(for camera: CameraID) async throws -> [CameraSetting]
    func apply(_ setting: CameraSetting, for camera: CameraID) async throws -> CameraSetting
    /// Protects (or releases) a recording from deletion and retention.
    func setProtected(_ protected: Bool, for recording: Recording) async throws -> Recording
}

/// The outcome of deleting several recordings: what was deleted, what was
/// skipped (protected, active, read-only) and what failed.
public struct DeletionResult: Sendable, Equatable {
    public var deleted: [Recording] = []
    public var skipped: [(Recording, String)] = []
    public var failed: [(Recording, String)] = []

    public init() {}

    public static func == (lhs: DeletionResult, rhs: DeletionResult) -> Bool {
        lhs.deleted == rhs.deleted && lhs.skipped.map(\.0) == rhs.skipped.map(\.0) && lhs.failed.map(\.0) == rhs.failed.map(\.0)
    }
}

/// One camera setting the provider exposes for viewing or changing.
public struct CameraSetting: Identifiable, Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        case toggle(Bool)
        case choice(selected: String, options: [Option])
        case number(Double, range: ClosedRange<Double>, step: Double)
        case text(String)
        /// Read-only information (model, firmware, resolution...).
        case info(String)
    }

    public struct Option: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public var id: String
    public var title: String
    public var section: String
    public var value: Value
    public var detail: String?

    public init(id: String, title: String, section: String, value: Value, detail: String? = nil) {
        self.id = id
        self.title = title
        self.section = section
        self.value = value
        self.detail = detail
    }

    public var isEditable: Bool {
        if case .info = value { return false }
        return true
    }

    /// Settings with this prefix change the connection's own options and
    /// are applied by the library, not sent to the camera.
    public static let connectionPrefix = "connection."
    public static let preferredProtocolID = "connection.preferredProtocol"
    public static let preferSubstreamID = "connection.preferSubstream"
    public static let onvifProfileID = "connection.onvifProfile"
}

extension CameraProvider {
    public func recordings(for camera: CameraID, cursor: String?) async throws -> RecordingPage {
        throw ProviderError.unsupported("\(profile.kind.displayName) connections don't provide recording history.")
    }

    public func playbackSession(for recording: Recording) async throws -> StreamSession {
        throw ProviderError.unsupported("\(profile.kind.displayName) connections don't provide recording playback.")
    }

    public func export(_ recording: Recording) async throws -> RecordingExport {
        throw ProviderError.unsupported("\(profile.kind.displayName) connections don't provide recording export.")
    }

    public func delete(_ recording: Recording) async throws {
        throw ProviderError.unsupported("\(profile.kind.displayName) connections don't provide recording deletion.")
    }

    public func setArmed(_ armed: Bool, for camera: CameraID) async throws -> Bool {
        throw ProviderError.unsupported("\(profile.kind.displayName) connections have no recorder to arm.")
    }

    public func snapshot(for camera: CameraID) async throws -> Data {
        throw ProviderError.unsupported("\(profile.kind.displayName) connections don't provide still images.")
    }

    public func settings(for camera: CameraID) async throws -> [CameraSetting] {
        throw ProviderError.unsupported("\(profile.kind.displayName) connections don't expose camera settings.")
    }

    public func apply(_ setting: CameraSetting, for camera: CameraID) async throws -> CameraSetting {
        throw ProviderError.unsupported("\(profile.kind.displayName) connections don't expose camera settings.")
    }

    public func setProtected(_ protected: Bool, for recording: Recording) async throws -> Recording {
        throw ProviderError.unsupported("\(profile.kind.displayName) connections can't protect recordings.")
    }

    /// Deletes each recording in turn. Blocked recordings are skipped with
    /// their reason before anything is sent; one failure doesn't stop the
    /// rest. Callers confirm the whole set with the user first.
    public func delete(_ recordings: [Recording]) async -> DeletionResult {
        var result = DeletionResult()
        for recording in recordings {
            if let reason = recording.deletionBlockedReason {
                result.skipped.append((recording, reason))
                continue
            }
            do {
                try await delete(recording)
                result.deleted.append(recording)
            } catch {
                result.failed.append((recording, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        return result
    }

    /// Loads pages until recordings older than `range` start appear.
    /// Providers list newest first.
    public func recordings(for camera: CameraID, in range: ClosedRange<Date>, pageLimit: Int = 40) async throws -> [Recording] {
        var cursor: String?
        var found: [Recording] = []
        for _ in 0..<pageLimit {
            let page = try await recordings(for: camera, cursor: cursor)
            found += page.recordings.filter { recording in
                let end = recording.endedAt ?? recording.startedAt
                return recording.startedAt <= range.upperBound && end >= range.lowerBound
            }
            let oldest = page.recordings.map(\.startedAt).min()
            guard let next = page.nextCursor, let oldest, oldest >= range.lowerBound else { break }
            cursor = next
        }
        return found
    }
}
