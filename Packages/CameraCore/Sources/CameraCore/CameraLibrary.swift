import Foundation
import Observation

/// Owns the user's connections: nonsecret profiles on disk, secrets in the
/// credential store, and per-connection cached camera lists. Connections
/// refresh independently; one failing provider never hides another's
/// cameras, and a failed refresh keeps the cached list with its age.
@MainActor
@Observable
public final class CameraLibrary {
    public struct ConnectionState: Sendable {
        public var cameras: [CameraDescriptor] = []
        public var lastSuccess: Date?
        public var error: ProviderError?
        public var isRefreshing = false
    }

    public enum CredentialChange: Sendable {
        case keep
        case replace(ConnectionCredential?)
    }

    public private(set) var profiles: [ConnectionProfile] = []
    public private(set) var states: [UUID: ConnectionState] = [:]
    public private(set) var preferences: [CameraID: CameraPreferences] = [:]
    /// Set when an unreadable connections file was preserved at load.
    public private(set) var startupNotice: String?

    public typealias ProviderMaker = @Sendable (ConnectionProfile, ConnectionCredential?) -> any CameraProvider

    @ObservationIgnored private let store: ProfileStore
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let makeProvider: ProviderMaker
    @ObservationIgnored private let sideStore: LibrarySideStore

    public init(store: ProfileStore, credentials: CredentialStore, makeProvider: @escaping ProviderMaker) {
        self.store = store
        self.credentials = credentials
        self.makeProvider = makeProvider
        sideStore = LibrarySideStore(directory: store.fileURL.deletingLastPathComponent())
    }

    public func load() throws {
        let result = try store.load()
        profiles = result.profiles
        if let preserved = result.preservedCorruptFile {
            startupNotice = "Your saved connections couldn't be read. The original file was kept as \(preserved.lastPathComponent)."
        }
        preferences = sideStore.loadPreferences()
        let cache = sideStore.loadCache()
        for profile in profiles where states[profile.id] == nil {
            var state = ConnectionState()
            // Show last-known cameras right away, clearly dated, until the
            // first refresh finishes.
            if let cached = cache[profile.id] {
                state.cameras = cached.cameras
                state.lastSuccess = cached.lastSuccess
            }
            states[profile.id] = state
        }
    }

    // MARK: Profiles

    public func add(_ profile: ConnectionProfile, credential: ConnectionCredential?) throws {
        var profile = profile
        try credentials.setCredential(credential, for: profile.id)
        profile.hasCredential = !(credential?.isEmpty ?? true)
        do {
            try store.save(profiles + [profile])
        } catch {
            try? credentials.setCredential(nil, for: profile.id)
            throw error
        }
        profiles.append(profile)
        states[profile.id] = ConnectionState()
    }

    public func update(_ profile: ConnectionProfile, credential: CredentialChange) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var profile = profile
        if case let .replace(newCredential) = credential {
            try credentials.setCredential(newCredential, for: profile.id)
            profile.hasCredential = !(newCredential?.isEmpty ?? true)
        }
        var updated = profiles
        updated[index] = profile
        try store.save(updated)
        profiles = updated
        // Different address or credentials: cached cameras may be stale.
        states[profile.id] = ConnectionState()
    }

    /// Removes the profile and this app's stored credential. It never asks
    /// the provider to delete anything: recordings stay on the camera/server.
    public func remove(_ profileID: UUID) throws {
        let remaining = profiles.filter { $0.id != profileID }
        try store.save(remaining)
        profiles = remaining
        states[profileID] = nil
        try credentials.setCredential(nil, for: profileID)
        try? credentials.setCredential(nil, for: Self.notificationCredentialID(profileID))
        preferences = preferences.filter { $0.key.connectionID != profileID }
        sideStore.savePreferences(preferences)
        saveCache()
    }

    public func credential(for profileID: UUID) -> ConnectionCredential? {
        try? credentials.credential(for: profileID)
    }

    public func provider(for profileID: UUID) -> (any CameraProvider)? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return nil }
        return makeProvider(profile, credential(for: profileID))
    }

    /// For Add Connection's Test button before anything is saved.
    public func previewProvider(for profile: ConnectionProfile, credential: ConnectionCredential?) -> any CameraProvider {
        makeProvider(profile, credential)
    }

    // MARK: Cameras

    public var allCameras: [CameraDescriptor] {
        profiles.flatMap { states[$0.id]?.cameras ?? [] }
    }

    public func camera(_ id: CameraID) -> CameraDescriptor? {
        states[id.connectionID]?.cameras.first { $0.id == id }
    }

    public func profile(_ id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { await self.refresh(profile.id) }
            }
        }
    }

    public func refresh(_ profileID: UUID) async {
        guard let provider = provider(for: profileID) else { return }
        states[profileID, default: ConnectionState()].isRefreshing = true
        do {
            let cameras = try await provider.cameras()
            guard states[profileID] != nil else { return } // removed meanwhile
            states[profileID]?.cameras = cameras.map { applyingAlerts($0) }
            states[profileID]?.lastSuccess = Date()
            states[profileID]?.error = nil
            saveCache()
        } catch {
            guard states[profileID] != nil else { return }
            states[profileID]?.error = (error as? ProviderError) ?? HTTPStatusMapping.map(error)
        }
        states[profileID]?.isRefreshing = false
    }

    /// Records a camera status change observed by a player or control.
    public func updateStatus(_ status: CameraStatus, for camera: CameraID) {
        guard let index = states[camera.connectionID]?.cameras.firstIndex(where: { $0.id == camera }) else { return }
        states[camera.connectionID]?.cameras[index].status = status
        saveCache()
    }

    // MARK: Organization

    public func preferences(for camera: CameraID) -> CameraPreferences {
        preferences[camera] ?? CameraPreferences()
    }

    public func setPreferences(_ value: CameraPreferences, for camera: CameraID) {
        preferences[camera] = value.isDefault ? nil : value
        sideStore.savePreferences(preferences)
        saveCache()
    }

    public func displayName(_ camera: CameraDescriptor) -> String {
        preferences[camera.id]?.customName.flatMap { $0.isEmpty ? nil : $0 } ?? camera.name
    }

    /// Visible cameras: favorites first, then the user's order, then by
    /// connection and name. Hidden cameras stay listed under Connections.
    public var orderedCameras: [CameraDescriptor] {
        let order = Dictionary(uniqueKeysWithValues: profiles.enumerated().map { ($1.id, $0) })
        return allCameras.filter { preferences[$0.id]?.isHidden != true }.sorted { a, b in
            let pa = preferences[a.id] ?? CameraPreferences(), pb = preferences[b.id] ?? CameraPreferences()
            if pa.isFavorite != pb.isFavorite { return pa.isFavorite }
            if pa.sortIndex != pb.sortIndex { return (pa.sortIndex ?? .max) < (pb.sortIndex ?? .max) }
            if a.id.connectionID != b.id.connectionID { return (order[a.id.connectionID] ?? 0) < (order[b.id.connectionID] ?? 0) }
            return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
        }
    }

    public var hiddenCameras: [CameraDescriptor] {
        allCameras.filter { preferences[$0.id]?.isHidden == true }
    }

    /// Moves cameras within the ordered list (drag to reorder).
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = orderedCameras.map(\.id)
        let moving = source.map { ordered[$0] }
        for index in source.sorted(by: >) { ordered.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        ordered.insert(contentsOf: moving, at: max(0, min(insertAt, ordered.count)))
        for (index, id) in ordered.enumerated() {
            var value = preferences[id] ?? CameraPreferences()
            value.sortIndex = index
            preferences[id] = value
        }
        sideStore.savePreferences(preferences)
    }

    // MARK: Connection settings

    /// Applies a setting from a provider's settings list. Connection-level
    /// settings change this app's profile; others go to the provider.
    public func apply(_ setting: CameraSetting, for camera: CameraID) async throws -> CameraSetting {
        guard setting.id.hasPrefix(CameraSetting.connectionPrefix) else {
            guard let provider = provider(for: camera.connectionID) else { throw ProviderError.notFound("This connection was removed.") }
            return try await provider.apply(setting, for: camera)
        }
        guard var profile = profile(camera.connectionID) else { throw ProviderError.notFound("This connection was removed.") }
        switch (setting.id, setting.value) {
        case let (CameraSetting.preferredProtocolID, .choice(selected, _)):
            profile.options.preferredProtocol = StreamProtocol(rawValue: selected)
        case let (CameraSetting.onvifProfileID, .choice(selected, _)):
            profile.options.onvifProfiles = (profile.options.onvifProfiles ?? [:]).merging([camera.nativeID: selected]) { $1 }
        case let (CameraSetting.preferSubstreamID, .toggle(value)):
            profile.options.preferSubstream = value
        default:
            throw ProviderError.unsupported("That setting can't be changed here.")
        }
        try saveProfileKeepingState(profile)
        return setting
    }

    private func saveProfileKeepingState(_ profile: ConnectionProfile) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profiles
        updated[index] = profile
        try store.save(updated)
        profiles = updated
    }

    // MARK: Alerts (ntfy)

    static func notificationCredentialID(_ profileID: UUID) -> UUID {
        // A stable, distinct Keychain item per connection for its ntfy token.
        var bytes = profileID.uuid
        bytes.15 ^= 0x5A
        bytes.14 ^= 0xA5
        return UUID(uuid: bytes)
    }

    /// Whether any camera on the connection has an event source that an
    /// always-on sender could alert about.
    public func supportsAlerts(_ profileID: UUID) -> Bool {
        states[profileID]?.cameras.contains { $0.capabilities.motionEvents.isSupported } ?? false
    }

    public func setNotificationSubscription(_ subscription: NotificationSubscription?, token: String?, for profileID: UUID) throws {
        guard var profile = profile(profileID) else { return }
        var subscription = subscription
        if let token {
            try credentials.setCredential(token.isEmpty ? nil : ConnectionCredential(password: token), for: Self.notificationCredentialID(profileID))
            subscription?.hasToken = !token.isEmpty
        }
        if subscription == nil { try credentials.setCredential(nil, for: Self.notificationCredentialID(profileID)) }
        profile.options.notifications = subscription
        try saveProfileKeepingState(profile)
        if let cameras = states[profileID]?.cameras {
            states[profileID]?.cameras = cameras.map { applyingAlerts($0) }
        }
    }

    public func notificationService(for profileID: UUID) -> NtfyClient? {
        guard let subscription = profile(profileID)?.options.notifications else { return nil }
        let token = (try? credentials.credential(for: Self.notificationCredentialID(profileID)))?.password
        return NtfyClient(subscription: subscription, token: token)
    }

    /// A configured topic marks alerts available for cameras that have
    /// motion events; the server is the sender, never this device.
    private func applyingAlerts(_ camera: CameraDescriptor) -> CameraDescriptor {
        guard let subscription = profile(camera.id.connectionID)?.options.notifications,
              camera.capabilities.motionEvents.isSupported,
              !camera.capabilities.notifications.isSupported
        else { return camera }
        var camera = camera
        camera.capabilities.notifications = .supported
        camera.capabilities.notificationTransport = "ntfy topic \(subscription.topic)"
        return camera
    }

    // MARK: Cache

    private func saveCache() {
        var cache: [UUID: LibrarySideStore.CachedConnection] = [:]
        for profile in profiles {
            guard let state = states[profile.id], let lastSuccess = state.lastSuccess else { continue }
            cache[profile.id] = LibrarySideStore.CachedConnection(cameras: state.cameras, lastSuccess: lastSuccess)
        }
        sideStore.saveCache(cache, profiles: profiles, preferences: preferences)
    }
}

/// Per-camera choices that belong to this app, not the provider.
public struct CameraPreferences: Codable, Hashable, Sendable {
    public var customName: String?
    public var isFavorite = false
    public var isHidden = false
    public var sortIndex: Int?
    /// Shown in widgets (favorites are included by default).
    public var showInWidget: Bool?

    public init(customName: String? = nil, isFavorite: Bool = false, isHidden: Bool = false, sortIndex: Int? = nil, showInWidget: Bool? = nil) {
        self.customName = customName
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.sortIndex = sortIndex
        self.showInWidget = showInWidget
    }

    public var isDefault: Bool { self == CameraPreferences() }
}
