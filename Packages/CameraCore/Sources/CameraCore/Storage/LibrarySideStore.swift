import Foundation

/// Files kept next to connections.json: per-camera preferences, the last
/// known camera list (shown, dated, while refreshing), and the summary
/// widgets read. None of them hold secrets. Write failures are ignored;
/// they only cost a slower first screen.
final class LibrarySideStore: @unchecked Sendable {
    struct CachedConnection: Codable {
        var cameras: [CameraDescriptor]
        var lastSuccess: Date
    }

    private struct PreferenceEntry: Codable {
        var camera: CameraID
        var preferences: CameraPreferences
    }

    let directory: URL
    private let queue = DispatchQueue(label: "CameraCore.LibrarySideStore")

    init(directory: URL) {
        self.directory = directory
    }

    var preferencesURL: URL { directory.appendingPathComponent("camera-preferences.json") }
    var cacheURL: URL { directory.appendingPathComponent("camera-cache.json") }
    var widgetURL: URL { directory.appendingPathComponent(WidgetSummary.fileName) }

    func loadPreferences() -> [CameraID: CameraPreferences] {
        guard let data = try? Data(contentsOf: preferencesURL), let entries = try? Self.decoder.decode([PreferenceEntry].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.camera, $0.preferences) }, uniquingKeysWith: { $1 })
    }

    func savePreferences(_ preferences: [CameraID: CameraPreferences]) {
        let entries = preferences.map { PreferenceEntry(camera: $0.key, preferences: $0.value) }
        write(entries, to: preferencesURL)
    }

    func loadCache() -> [UUID: CachedConnection] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? Self.decoder.decode([UUID: CachedConnection].self, from: data)) ?? [:]
    }

    func saveCache(_ cache: [UUID: CachedConnection], profiles: [ConnectionProfile], preferences: [CameraID: CameraPreferences]) {
        write(cache, to: cacheURL)
        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
        var cameras: [WidgetSummary.Camera] = []
        for profile in profiles {
            guard let cached = cache[profile.id] else { continue }
            for camera in cached.cameras where preferences[camera.id]?.isHidden != true {
                let prefs = preferences[camera.id]
                cameras.append(WidgetSummary.Camera(
                    id: camera.id,
                    name: prefs?.customName.flatMap { $0.isEmpty ? nil : $0 } ?? camera.name,
                    connectionName: names[profile.id] ?? "",
                    state: camera.status?.state,
                    observedAt: camera.status?.observedAt,
                    armed: camera.status?.armed,
                    isFavorite: prefs?.isFavorite ?? false,
                    listedAt: cached.lastSuccess,
                    hasLiveView: camera.capabilities.liveView != nil
                ))
            }
        }
        cameras.sort { ($0.isFavorite ? 0 : 1, $0.name) < ($1.isFavorite ? 0 : 1, $1.name) }
        write(WidgetSummary(updatedAt: Date(), cameras: cameras), to: widgetURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? Self.encoder.encode(value) else { return }
        queue.async { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// What the widgets show: last known status per camera, with its age.
/// Written by the app into the shared container; widgets never contact
/// cameras or hold credentials.
public struct WidgetSummary: Codable, Sendable, Equatable {
    public static let fileName = "widget-summary.json"
    public static let thumbnailDirectory = "WidgetThumbnails"

    public struct Camera: Codable, Sendable, Equatable, Identifiable {
        public var id: CameraID
        public var name: String
        public var connectionName: String
        public var state: CameraState?
        public var observedAt: Date?
        public var armed: Bool?
        public var isFavorite: Bool
        public var listedAt: Date
        public var hasLiveView: Bool

        public init(id: CameraID, name: String, connectionName: String, state: CameraState?, observedAt: Date?, armed: Bool?, isFavorite: Bool, listedAt: Date, hasLiveView: Bool) {
            self.id = id
            self.name = name
            self.connectionName = connectionName
            self.state = state
            self.observedAt = observedAt
            self.armed = armed
            self.isFavorite = isFavorite
            self.listedAt = listedAt
            self.hasLiveView = hasLiveView
        }

        /// File name for this camera's thumbnail in `thumbnailDirectory`.
        public var thumbnailName: String { Self.thumbnailName(for: id) }

        public static func thumbnailName(for id: CameraID) -> String {
            let safe = id.nativeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "camera"
            return "\(id.connectionID.uuidString)-\(safe).jpg"
        }
    }

    public var updatedAt: Date
    public var cameras: [Camera]

    public init(updatedAt: Date, cameras: [Camera]) {
        self.updatedAt = updatedAt
        self.cameras = cameras
    }

    public static func load(from directory: URL) -> WidgetSummary? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? LibrarySideStore.decoder.decode(WidgetSummary.self, from: data)
    }

    /// `cameramonitor://camera/<connection>/<native id>`
    public static func deepLink(for id: CameraID) -> URL {
        var components = URLComponents()
        components.scheme = "cameramonitor"
        components.host = "camera"
        components.path = "/\(id.connectionID.uuidString)/" + (id.nativeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        return components.url!
    }

    public static func cameraID(fromDeepLink url: URL) -> CameraID? {
        guard url.scheme == "cameramonitor", url.host == "camera" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, let connection = UUID(uuidString: parts[0]), let native = parts[1].removingPercentEncoding else { return nil }
        return CameraID(connectionID: connection, nativeID: native)
    }
}
