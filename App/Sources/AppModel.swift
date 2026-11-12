import CameraCore
import Foundation
import HomeServicesConnection
import Observation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// App-wide state: the connection library plus navigation selection.
@MainActor
@Observable
final class AppModel {
    enum SidebarItem: Hashable {
        case allCameras
        case camera(CameraID)
        case connections
        case discovery
        case about
    }

    static let appGroup = "group.com.zacharysturman.cameramonitor"

    let library: CameraLibrary
    let storageDirectory: URL
    let isIsolated: Bool
    var selection: SidebarItem? = .allCameras
    var homePageObservedAlerts: [UUID: [NtfyClient.Message]] = [:]
    var loadError: String?
    var isShowingAddConnection = false
    /// Prefills Add Connection from discovery.
    var addConnectionDraft: ConnectionDraft?
    private var started = false

    init(library: CameraLibrary, storageDirectory: URL, isIsolated: Bool) {
        self.library = library
        self.storageDirectory = storageDirectory
        self.isIsolated = isIsolated
    }

    /// Normal runs use the shared App Group folder (falling back to the
    /// app's own Application Support) and the Keychain.
    /// `-CameraMonitorIsolatedStore YES` (UI tests, screenshots, fixture
    /// runs) uses a fresh temporary directory and in-memory credentials so
    /// real connections are never read or changed.
    static func makeDefault() -> AppModel {
        let isolated = UserDefaults.standard.bool(forKey: "CameraMonitorIsolatedStore")
        let fileURL: URL
        let credentials: CredentialStore
        if isolated {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraMonitor-isolated-\(ProcessInfo.processInfo.processIdentifier)")
            fileURL = directory.appendingPathComponent("connections.json")
            credentials = InMemoryCredentialStore()
        } else {
            fileURL = ProfileStore.sharedFileURL(appGroup: appGroup)
                ?? (try? ProfileStore.defaultFileURL())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("connections.json")
            credentials = KeychainCredentialStore()
        }
        let factory = ProviderFactory()
        let library = CameraLibrary(store: ProfileStore(fileURL: fileURL), credentials: credentials) { factory.provider(for: $0, credential: $1) }
        let model = AppModel(library: library, storageDirectory: fileURL.deletingLastPathComponent(), isIsolated: isolated)
        if isolated { model.seedFixtureConnections() }
        return model
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try library.load()
        } catch {
            loadError = "Couldn't load saved connections: \(error.localizedDescription)"
        }
        await refresh()
        if !isIsolated, let profile = UserDefaults.standard.string(forKey: "piConnection.profile.v1").flatMap(UUID.init(uuidString:)),
           let nativeID = UserDefaults.standard.string(forKey: "piConnection.defaultCamera.v1") {
            let camera = CameraID(connectionID: profile, nativeID: nativeID)
            if library.camera(camera) != nil { selection = .camera(camera) }
        }
        // Fixture/screenshot runs: `-CameraMonitorOpenCamera <index>`.
        let index = UserDefaults.standard.integer(forKey: "CameraMonitorOpenCamera")
        if UserDefaults.standard.object(forKey: "CameraMonitorOpenCamera") != nil, library.orderedCameras.indices.contains(index) {
            selection = .camera(library.orderedCameras[index].id)
        }
    }

    func refresh() async {
        if !isIsolated, UserDefaults.standard.string(forKey: "piConnection.profile.v1") != nil {
            do {
                let client = try PairingClient(expectedPreset: "camera-monitor", keychainService: "com.zacharysturman.cameramonitor.pi")
                if client.credential != nil {
                    try await client.refresh()
                    UserDefaults.standard.set(client.connection?.preferences["camera_id"], forKey: "piConnection.defaultCamera.v1")
                }
            } catch { /* Cached cameras and adapter errors remain visible. */ }
        }
        await library.refreshAll()
        reloadWidgets()
    }

    func reloadWidgets() {
        #if canImport(WidgetKit)
        guard !isIsolated else { return }
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// `cameramonitor://camera/<connection>/<id>` from widgets.
    func open(_ url: URL) {
        if url.scheme == "cameramonitor", url.host == "cameras" { selection = .allCameras; return }
        if url.scheme == "cameramonitor", url.host == "connections" { selection = .connections; return }
        guard let id = WidgetSummary.cameraID(fromDeepLink: url) else { return }
        selection = library.camera(id) != nil ? .camera(id) : .allCameras
    }

    /// Saves a still for tiles and widgets (never for isolated runs).
    func storeThumbnail(_ data: Data, for camera: CameraID) {
        guard !isIsolated else { return }
        let directory = storageDirectory.appendingPathComponent(WidgetSummary.thumbnailDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(WidgetSummary.Camera.thumbnailName(for: camera)), options: .atomic)
    }

    func thumbnailURL(for camera: CameraID) -> URL {
        storageDirectory.appendingPathComponent(WidgetSummary.thumbnailDirectory, isDirectory: true)
            .appendingPathComponent(WidgetSummary.Camera.thumbnailName(for: camera))
    }

    func beginAdd(_ draft: ConnectionDraft? = nil) {
        addConnectionDraft = draft
        isShowingAddConnection = true
    }

    /// `-CameraMonitorFixtureConnections "Name|kind|url;Name|kind|url"`
    /// adds connections to an isolated store, for fixture runs only. A
    /// fourth field supplies a token.
    private func seedFixtureConnections() {
        guard let spec = UserDefaults.standard.string(forKey: "CameraMonitorFixtureConnections") else { return }
        try? library.load()
        for entry in spec.split(separator: ";") {
            let fields = entry.split(separator: "|", maxSplits: 3).map(String.init)
            guard fields.count >= 2, let kind = ConnectionKind(rawValue: fields[1]), let parsed = try? AddressParser.parse(fields.count > 2 ? fields[2] : "", kind: kind) else { continue }
            let credential = fields.count == 4 ? ConnectionCredential(password: fields[3]) : parsed.embeddedCredential
            try? library.add(ConnectionProfile(name: fields[0], kind: kind, address: parsed.url), credential: credential)
        }
    }
}

/// Values that prefill Add Connection.
struct ConnectionDraft: Equatable {
    var kind: ConnectionKind
    var name: String = ""
    var address: String = ""
}
