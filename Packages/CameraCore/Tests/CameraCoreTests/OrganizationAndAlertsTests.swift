import XCTest
@testable import CameraCore

@MainActor
final class OrganizationAndAlertsTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrgTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeLibrary(credentials: InMemoryCredentialStore = InMemoryCredentialStore()) -> CameraLibrary {
        let factory = ProviderFactory()
        return CameraLibrary(store: ProfileStore(fileURL: directory.appendingPathComponent("connections.json")), credentials: credentials) { factory.provider(for: $0, credential: $1) }
    }

    func testFavoritesOrderHiddenAndRenamesPersist() async throws {
        let library = makeLibrary()
        let a = ConnectionProfile.fixture(.hls, "https://a.example/live.m3u8", name: "Alpha")
        let b = ConnectionProfile.fixture(.mjpeg, "http://b.local/video", name: "Bravo")
        let c = ConnectionProfile.fixture(.rtsp, "rtsp://c.local/s", name: "Charlie")
        for profile in [a, b, c] { try library.add(profile, credential: nil) }
        await library.refreshAll()
        let ids = library.allCameras.map(\.id)
        XCTAssertEqual(library.orderedCameras.map(\.name), ["Alpha", "Bravo", "Charlie"])

        library.setPreferences(CameraPreferences(customName: "Front gate", isFavorite: true), for: ids[2])
        library.setPreferences(CameraPreferences(isHidden: true), for: ids[0])
        XCTAssertEqual(library.orderedCameras.map(library.displayName), ["Front gate", "Bravo"])
        XCTAssertEqual(library.hiddenCameras.map(\.name), ["Alpha"])

        library.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(library.orderedCameras.map(library.displayName), ["Front gate", "Bravo"], "favorites stay first")

        try await Task.sleep(for: .milliseconds(200)) // side-store writes are async
        let reloaded = makeLibrary()
        try reloaded.load()
        XCTAssertEqual(reloaded.preferences(for: ids[2]).customName, "Front gate")
        XCTAssertEqual(reloaded.allCameras.count, 3, "cached cameras appear before the first refresh")
        let summary = try XCTUnwrap(WidgetSummary.load(from: directory))
        XCTAssertEqual(summary.cameras.map(\.name), ["Front gate", "Bravo"])
        XCTAssertTrue(summary.cameras[0].isFavorite)

        try reloaded.remove(c.id)
        XCTAssertEqual(reloaded.preferences(for: ids[2]), CameraPreferences())
    }

    func testDeepLinkRoundTrip() {
        let id = CameraID(connectionID: UUID(), nativeID: "garage/side door")
        XCTAssertEqual(WidgetSummary.cameraID(fromDeepLink: WidgetSummary.deepLink(for: id)), id)
        XCTAssertNil(WidgetSummary.cameraID(fromDeepLink: URL(string: "https://example.com/camera/x/y")!))
    }

    func testConnectionSettingChangesProfileOptions() async throws {
        let library = makeLibrary()
        let profile = ConnectionProfile.fixture(.go2rtc, "http://go2rtc.local:1984")
        try library.add(profile, credential: nil)
        let camera = CameraID(connectionID: profile.id, nativeID: "porch")
        let setting = CameraSetting(id: CameraSetting.preferredProtocolID, title: "", section: "", value: .choice(selected: "mjpeg", options: []))
        _ = try await library.apply(setting, for: camera)
        XCTAssertEqual(library.profile(profile.id)?.options.preferredProtocol, .mjpeg)
        let session = try await library.provider(for: profile.id)!.liveSession(for: camera)
        XCTAssertEqual(session.streamProtocol, .mjpeg)
    }

    func testAlertsOnlyForCamerasWithEventsAndTokenInKeychain() async throws {
        let credentials = InMemoryCredentialStore()
        let library = makeLibrary(credentials: credentials)
        let stream = ConnectionProfile.fixture(.rtsp, "rtsp://cam.local/s")
        try library.add(stream, credential: nil)
        await library.refreshAll()
        XCTAssertFalse(library.supportsAlerts(stream.id), "a bare stream has no event source")

        try library.setNotificationSubscription(NotificationSubscription(topic: "cm-test"), token: "tk_secret", for: stream.id)
        XCTAssertEqual(library.profile(stream.id)?.options.notifications?.hasToken, true)
        XCTAssertFalse(library.allCameras[0].capabilities.notifications.isSupported, "no motion events, so no alerts claimed")
        let file = try String(contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("tk_secret"))
        XCTAssertEqual(library.notificationService(for: stream.id)?.token, "tk_secret")

        try library.setNotificationSubscription(nil, token: nil, for: stream.id)
        XCTAssertNil(library.notificationService(for: stream.id))
        XCTAssertEqual(credentials.count, 0)
    }

    func testNtfyValidationAndParsing() {
        XCTAssertNil(NtfyClient.validate(topic: "camera_alerts-7f3k"))
        XCTAssertNotNil(NtfyClient.validate(topic: ""))
        XCTAssertNotNil(NtfyClient.validate(topic: "has space"))
        let lines = """
        {"id":"a","time":100,"event":"open","topic":"t"}
        {"id":"b","time":200,"event":"message","topic":"t","title":"Motion","message":"Front door","tags":["camera"]}
        {"id":"c","time":300,"event":"message","topic":"t","message":"Later"}
        """
        let messages = NtfyClient.parse(Data(lines.utf8))
        XCTAssertEqual(messages.map(\.id), ["c", "b"])
        XCTAssertEqual(messages[1].title, "Motion")
    }

    /// Against a local ntfy server (docker run -p 8797:80 binwiederhier/ntfy serve).
    func testNtfyAgainstLocalServer() async throws {
        guard let server = ProcessInfo.processInfo.environment["CAMERA_MONITOR_NTFY_FIXTURE"] else {
            throw XCTSkip("Set CAMERA_MONITOR_NTFY_FIXTURE to a local ntfy server URL.")
        }
        let topic = ProcessInfo.processInfo.environment["CAMERA_MONITOR_NTFY_TOPIC"] ?? "cm-test-\(UUID().uuidString.prefix(8))"
        let client = NtfyClient(subscription: NotificationSubscription(server: URL(string: server)!, topic: topic), token: nil)
        try await client.sendTest(from: "unit tests")
        let messages = try await client.recent()
        XCTAssertEqual(messages.first?.title, "Camera Monitor test")
    }
}
