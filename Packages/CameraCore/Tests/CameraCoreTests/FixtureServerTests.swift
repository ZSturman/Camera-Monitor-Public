import XCTest
@testable import CameraCore

/// Exercises the providers over real sockets against Scripts/fixtures/serve.py
/// (and Scripts/fixtures/rtsp.sh for RTSP). Skipped unless
/// CAMERA_MONITOR_FIXTURE_BASE is set, e.g. http://127.0.0.1:8796.
final class FixtureServerTests: XCTestCase {
    var base: String!

    override func setUpWithError() throws {
        base = ProcessInfo.processInfo.environment["CAMERA_MONITOR_FIXTURE_BASE"]
        try XCTSkipIf(base == nil, "Set CAMERA_MONITOR_FIXTURE_BASE to run against the local fixture server.")
    }

    func direct(_ kind: ConnectionKind, _ path: String, credential: ConnectionCredential? = nil) -> DirectStreamProvider {
        DirectStreamProvider(profile: .fixture(kind, base + path), credential: credential)
    }

    func testLiveHLS() async throws {
        let report = try await direct(.hls, "/hls/index.m3u8").testConnection()
        XCTAssertTrue(report.notes[0].hasPrefix("Live media playlist"), report.notes[0])
    }

    func testHLSBasicAuth() async throws {
        _ = try await direct(.hls, "/hls-auth/index.m3u8", credential: ConnectionCredential(username: "fixture", password: "fixture-pass")).testConnection()
        do {
            _ = try await direct(.hls, "/hls-auth/index.m3u8", credential: ConnectionCredential(username: "fixture", password: "wrong")).testConnection()
            XCTFail("expected auth failure")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testMJPEG() async throws {
        let report = try await direct(.mjpeg, "/mjpeg").testConnection()
        XCTAssertTrue(report.notes[0].contains("JPEG frame"), report.notes[0])
    }

    func testMJPEGBasicAuth() async throws {
        _ = try await direct(.mjpeg, "/mjpeg-auth", credential: ConnectionCredential(username: "fixture", password: "fixture-pass")).testConnection()
        do {
            _ = try await direct(.mjpeg, "/mjpeg-auth").testConnection()
            XCTFail("expected auth failure")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testMJPEGStallEndsWithoutNewFrames() async throws {
        let stream = MJPEGStream(url: URL(string: base + "/mjpeg-stall")!, credential: nil)
        var count = 0
        let deadline = Date().addingTimeInterval(6)
        for try await _ in stream.frames() {
            count += 1
            if Date() > deadline { break }
            if count > 10 { break }
        }
        stream.cancel()
        XCTAssertLessThanOrEqual(count, 5, "the stall endpoint stops sending frames")
    }

    func testRTSPFixture() async throws {
        let rtsp = ProcessInfo.processInfo.environment["CAMERA_MONITOR_RTSP_FIXTURE"] ?? "rtsp://127.0.0.1:8554"
        let open = DirectStreamProvider(profile: .fixture(.rtsp, rtsp + "/fixture"), credential: nil)
        do {
            let report = try await open.testConnection()
            XCTAssertTrue(report.notes[0].contains("H264"), report.notes[0])
        } catch ProviderError.networkUnavailable {
            throw XCTSkip("Start Scripts/fixtures/rtsp.sh to include RTSP.")
        }
        let secure = DirectStreamProvider(profile: .fixture(.rtsp, rtsp + "/secure"), credential: ConnectionCredential(username: "fixture", password: "fixture-pass"))
        _ = try await secure.testConnection()
        let denied = DirectStreamProvider(profile: .fixture(.rtsp, rtsp + "/secure"), credential: ConnectionCredential(username: "fixture", password: "nope"))
        do {
            _ = try await denied.testConnection()
            XCTFail("expected auth failure")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else { return XCTFail("\(error)") }
        }
    }
}
