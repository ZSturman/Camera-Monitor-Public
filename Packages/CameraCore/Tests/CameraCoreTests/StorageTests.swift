import XCTest
@testable import CameraCore

final class AddressParserTests: XCTestCase {
    func testEmbeddedCredentialsAreLiftedOutOfTheAddress() throws {
        let parsed = try AddressParser.parse("rtsp://admin:p%40ss@192.168.1.20:554/stream1", kind: .rtsp)
        XCTAssertEqual(parsed.url.absoluteString, "rtsp://192.168.1.20:554/stream1")
        XCTAssertEqual(parsed.embeddedCredential, ConnectionCredential(username: "admin", password: "p@ss"))
    }

    func testMissingSchemeDefaultsPerKind() throws {
        XCTAssertEqual(try AddressParser.parse("cam.local/stream", kind: .rtsp).url.scheme, "rtsp")
        XCTAssertEqual(try AddressParser.parse("cam.local/live.m3u8", kind: .hls).url.scheme, "https")
    }

    func testWrongSchemeIsRejected() {
        XCTAssertThrowsError(try AddressParser.parse("http://cam.local/x", kind: .rtsp))
        XCTAssertThrowsError(try AddressParser.parse("rtsp://cam.local/x", kind: .mjpeg))
        XCTAssertThrowsError(try AddressParser.parse("   ", kind: .hls))
    }

    func testHomeServicesRequiresHTTPSExceptLoopback() throws {
        XCTAssertThrowsError(try AddressParser.parse("http://pi.local:8443", kind: .homeServices))
        XCTAssertNoThrow(try AddressParser.parse("http://127.0.0.1:8765", kind: .homeServices))
        XCTAssertNoThrow(try AddressParser.parse("https://host.example.net", kind: .homeServices))
    }

    func testRedactedAddressNeverShowsSecrets() {
        let url = URL(string: "https://user:secret@cam.local/live.m3u8?token=abc")!
        let redacted = AddressParser.redacted(url)
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("abc"))
        XCTAssertFalse(redacted.contains("user"))
    }

    func testCredentialDescriptionIsRedacted() {
        let credential = ConnectionCredential(username: "admin", password: "hunter2")
        XCTAssertFalse("\(credential)".contains("hunter2"))
        XCTAssertFalse(String(reflecting: credential).contains("hunter2"))
    }
}

final class ProfileStoreTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTrip() throws {
        let store = ProfileStore(fileURL: directory.appendingPathComponent("connections.json"))
        XCTAssertEqual(try store.load().profiles, [])
        let profiles = [
            ConnectionProfile.fixture(.hls, "https://cam.local/a.m3u8", name: "A"),
            ConnectionProfile.fixture(.homeServices, "https://host.example.net", name: "B"),
        ]
        try store.save(profiles)
        XCTAssertEqual(try store.load().profiles, profiles)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\" : 1"))
    }

    func testUnreadableFileIsPreservedNotOverwritten() throws {
        let file = directory.appendingPathComponent("connections.json")
        try Data("{not json".utf8).write(to: file)
        let result = try ProfileStore(fileURL: file).load()
        XCTAssertEqual(result.profiles, [])
        let preserved = try XCTUnwrap(result.preservedCorruptFile)
        XCTAssertEqual(try Data(contentsOf: preserved), Data("{not json".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("{not json".utf8), "original stays until the user saves")
    }

    func testNewerFileVersionIsPreserved() throws {
        let file = directory.appendingPathComponent("connections.json")
        try Data(#"{"version": 99, "profiles": []}"#.utf8).write(to: file)
        XCTAssertNotNil(try ProfileStore(fileURL: file).load().preservedCorruptFile)
    }
}

final class KeychainCredentialStoreTests: XCTestCase {
    /// Writes to the login keychain under a throwaway service name, so it
    /// only runs when explicitly requested.
    func testRoundTripAndDelete() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAMERA_MONITOR_KEYCHAIN_TESTS"] == "1", "Set CAMERA_MONITOR_KEYCHAIN_TESTS=1 to exercise the real Keychain.")
        let store = KeychainCredentialStore(service: "com.zacharysturman.cameramonitor.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.setCredential(nil, for: id) }
        XCTAssertNil(try store.credential(for: id))
        try store.setCredential(ConnectionCredential(username: "u", password: "p1"), for: id)
        try store.setCredential(ConnectionCredential(username: "u", password: "p2"), for: id)
        XCTAssertEqual(try store.credential(for: id)?.password, "p2")
        try store.setCredential(nil, for: id)
        XCTAssertNil(try store.credential(for: id))
    }
}
