import XCTest
@testable import CameraCore

@MainActor
final class CameraLibraryTests: XCTestCase {
    var directory: URL!
    var credentials: InMemoryCredentialStore!

    override func setUp() async throws {
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraLibraryTests-\(UUID().uuidString)")
        credentials = InMemoryCredentialStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeLibrary() -> CameraLibrary {
        let factory = ProviderFactory(urlSessionConfiguration: { StubURLProtocol.configuration() })
        return CameraLibrary(store: ProfileStore(fileURL: directory.appendingPathComponent("connections.json")), credentials: credentials) { factory.provider(for: $0, credential: $1) }
    }

    func testDirectCamerasKeepWorkingWhenHomeServicesIsUnavailable() async throws {
        StubURLProtocol.register(host: "host.example.net") { _ in .failure(.cannotConnectToHost) }
        let library = makeLibrary()
        try library.load()
        let hs = ConnectionProfile.fixture(.homeServices, "https://host.example.net", name: "Pi")
        let hls = ConnectionProfile.fixture(.hls, "https://hls.fixture/live.m3u8", name: "Porch")
        let rtsp = ConnectionProfile.fixture(.rtsp, "rtsp://cam.local/s", name: "Drive")
        try library.add(hs, credential: ConnectionCredential(password: "token"))
        try library.add(hls, credential: nil)
        try library.add(rtsp, credential: ConnectionCredential(username: "admin", password: "pw"))

        await library.refreshAll()

        guard case .networkUnavailable = library.states[hs.id]?.error else { return XCTFail("Home Services failure must be reported") }
        XCTAssertEqual(library.allCameras.map(\.name), ["Porch", "Drive"])
        let session = try await library.provider(for: hls.id)!.liveSession(for: CameraID(connectionID: hls.id, nativeID: "stream"))
        XCTAssertEqual(session.streamProtocol, .hls)
    }

    func testFailedRefreshKeepsCachedCamerasWithTheirAge() async throws {
        nonisolated(unsafe) var online = true
        StubURLProtocol.register(host: "host.example.net") { _ in online ? StubURLProtocol.json("HomeServices/v1/cameras.json") : .failure(.timedOut) }
        let library = makeLibrary()
        let hs = ConnectionProfile.fixture(.homeServices, "https://host.example.net")
        try library.add(hs, credential: ConnectionCredential(password: "token"))
        await library.refresh(hs.id)
        let firstSuccess = try XCTUnwrap(library.states[hs.id]?.lastSuccess)
        online = false
        await library.refresh(hs.id)
        XCTAssertEqual(library.states[hs.id]?.cameras.count, 1, "cached cameras are not hidden")
        XCTAssertEqual(library.states[hs.id]?.lastSuccess, firstSuccess)
        XCTAssertEqual(library.states[hs.id]?.error, .timedOut)
    }

    func testCredentialsAreIsolatedPerConnection() async throws {
        StubURLProtocol.register(host: "host.example.net") { _ in StubURLProtocol.json("HomeServices/v1/cameras.json") }
        StubURLProtocol.register(host: "host.example.net") { _ in StubURLProtocol.json("HomeServices/v1/cameras.json") }
        let library = makeLibrary()
        let a = ConnectionProfile.fixture(.homeServices, "https://host.example.net")
        let b = ConnectionProfile.fixture(.homeServices, "https://host.example.net")
        try library.add(a, credential: ConnectionCredential(password: "token-a"))
        try library.add(b, credential: ConnectionCredential(password: "token-b"))
        await library.refreshAll()
        XCTAssertEqual(Set(StubURLProtocol.recordedRequests(host: "host.example.net").map { $0.value(forHTTPHeaderField: "Authorization") }), ["Bearer token-a"])
        XCTAssertEqual(Set(StubURLProtocol.recordedRequests(host: "host.example.net").map { $0.value(forHTTPHeaderField: "Authorization") }), ["Bearer token-b"])
    }

    func testRemovingAProfileDeletesOnlyLocalStateAndCredential() async throws {
        StubURLProtocol.register(host: "host.example.net") { _ in StubURLProtocol.json("HomeServices/v1/cameras.json") }
        let library = makeLibrary()
        let hs = ConnectionProfile.fixture(.homeServices, "https://host.example.net")
        try library.add(hs, credential: ConnectionCredential(password: "token"))
        await library.refresh(hs.id)
        let before = StubURLProtocol.recordedRequests().count

        try library.remove(hs.id)

        XCTAssertEqual(StubURLProtocol.recordedRequests().count, before, "removal never contacts the server")
        XCTAssertNil(try credentials.credential(for: hs.id))
        XCTAssertTrue(library.profiles.isEmpty)
        let reloaded = makeLibrary()
        try reloaded.load()
        XCTAssertTrue(reloaded.profiles.isEmpty)
    }

    func testProfilesPersistWithoutSecrets() throws {
        let library = makeLibrary()
        let rtsp = ConnectionProfile.fixture(.rtsp, "rtsp://cam.local/s")
        try library.add(rtsp, credential: ConnectionCredential(username: "admin", password: "super-secret"))
        let text = try String(contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("super-secret"))
        XCTAssertFalse(text.contains("admin"))
        let reloaded = makeLibrary()
        try reloaded.load()
        XCTAssertEqual(reloaded.profiles.first?.hasCredential, true)
        XCTAssertEqual(reloaded.credential(for: rtsp.id)?.password, "super-secret")
    }
}
