import XCTest
@testable import CameraCore

final class DirectStreamProviderTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testBareStreamsOnlyClaimLiveView() async throws {
        for kind in [ConnectionKind.hls, .mjpeg, .rtsp] {
            let provider = DirectStreamProvider(profile: .fixture(kind, kind == .rtsp ? "rtsp://cam.local/s" : "http://cam.local/s"), credential: nil)
            let camera = try await provider.cameras()[0]
            let caps = camera.capabilities
            XCTAssertNotNil(caps.liveView)
            for feature in [caps.history, caps.playback, caps.export, caps.deletion, caps.serverRecording, caps.motionEvents, caps.notifications, caps.arming, caps.settings] {
                XCTAssertFalse(feature.isSupported, "\(kind)")
                XCTAssertNotNil(feature.reason)
            }
            XCTAssertNil(camera.status?.armed)
            do {
                _ = try await provider.recordings(for: camera.id, cursor: nil)
                XCTFail("history must be unsupported, not empty")
            } catch let error as ProviderError {
                guard case .unsupported = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testRTSPPlaysNativelyWithoutExtraEngine() async throws {
        let provider = DirectStreamProvider(profile: .fixture(.rtsp, "rtsp://cam.local/s"), credential: ConnectionCredential(username: "u", password: "p"))
        let camera = try await provider.cameras()[0]
        XCTAssertEqual(camera.capabilities.liveView, .rtsp)
        let session = try await provider.liveSession(for: camera.id)
        XCTAssertEqual(session.streamProtocol, .rtsp)
        XCTAssertEqual(session.credential?.username, "u")
        XCTAssertFalse(session.url.absoluteString.contains("p@"), "credentials stay out of the URL")
    }

    func testHLSTestConnection() async throws {
        StubURLProtocol.register(host: "hls.fixture") { _ in
            .response(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], chunks: [(try? Fixture.data("HLS/live.m3u8"))!])
        }
        let provider = DirectStreamProvider(profile: .fixture(.hls, "https://hls.fixture/live.m3u8"), credential: nil, urlSessionConfiguration: StubURLProtocol.configuration())
        let report = try await provider.testConnection()
        XCTAssertEqual(report.cameras.first?.status?.state, .online)
        XCTAssertTrue(report.notes[0].hasPrefix("Live media playlist"))
    }

    func testHLSLoginPageIsUnsupportedSourceNotSuccess() async throws {
        StubURLProtocol.register(host: "hls.fixture") { _ in .response(status: 200, headers: ["Content-Type": "text/html"], chunks: [Data("<html>".utf8)]) }
        let provider = DirectStreamProvider(profile: .fixture(.hls, "https://hls.fixture/live.m3u8"), credential: nil, urlSessionConfiguration: StubURLProtocol.configuration())
        do {
            _ = try await provider.testConnection()
            XCTFail("expected failure")
        } catch let error as ProviderError {
            guard case .unsupportedSource = error else { return XCTFail("\(error)") }
        }
    }

    func testMJPEGStreamDeliversFramesAcrossChunks() async throws {
        let jpeg = try Fixture.data("MJPEG/frame.jpg")
        var body = Data()
        for _ in 0..<3 {
            body.append(Data("--frame\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(jpeg)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--frame\r\n".utf8))
        let chunks = stride(from: 0, to: body.count, by: 97).map { body.subdata(in: $0..<min($0 + 97, body.count)) }
        StubURLProtocol.register(host: "mjpeg.fixture") { _ in
            .response(status: 200, headers: ["Content-Type": "multipart/x-mixed-replace; boundary=frame"], chunks: chunks)
        }
        let stream = MJPEGStream(url: URL(string: "http://mjpeg.fixture/video")!, credential: nil, configuration: StubURLProtocol.configuration())
        var received: [Data] = []
        do {
            for try await frame in stream.frames() { received.append(frame) }
            XCTFail("a finished stream reports stale, not success")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .staleStream(lastFrameAt: nil))
        }
        XCTAssertFalse(received.isEmpty)
        XCTAssertTrue(received.allSatisfy { $0 == jpeg })
    }

    /// URLSession's per-part delivery of real multipart streams is covered
    /// by FixtureServerTests over real sockets; a URLProtocol stub can't
    /// emit repeated responses. A single JPEG response must not pass as a
    /// stream.
    func testSingleSnapshotIsNotAStream() async throws {
        let jpeg = try Fixture.data("MJPEG/frame.jpg")
        StubURLProtocol.register(host: "parts.fixture") { _ in .replacingParts([jpeg]) }
        let still = DirectStreamProvider(profile: .fixture(.mjpeg, "http://parts.fixture/still.jpg"), credential: nil, urlSessionConfiguration: StubURLProtocol.configuration())
        do {
            _ = try await still.testConnection()
            XCTFail("a single snapshot is not a stream")
        } catch let error as ProviderError {
            guard case .unsupportedSource = error else { return XCTFail("\(error)") }
        }
    }

    func testMJPEGWrongContentTypeAndAuth() async throws {
        StubURLProtocol.register(host: "mjpeg.fixture") { request in
            request.url!.path == "/locked"
                ? .response(status: 401, headers: [:], chunks: [])
                : .response(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [Data([0xFF, 0xD8])])
        }
        let config = StubURLProtocol.configuration()
        let provider = DirectStreamProvider(profile: .fixture(.mjpeg, "http://mjpeg.fixture/still.jpg"), credential: nil, urlSessionConfiguration: config)
        do {
            _ = try await provider.testConnection()
            XCTFail("expected failure")
        } catch let error as ProviderError {
            guard case .unsupportedSource = error else { return XCTFail("\(error)") }
        }
        let locked = DirectStreamProvider(profile: .fixture(.mjpeg, "http://mjpeg.fixture/locked"), credential: nil, urlSessionConfiguration: config)
        do {
            _ = try await locked.testConnection()
            XCTFail("expected failure")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else { return XCTFail("\(error)") }
        }
    }
}

final class ScopedCredentialDelegateTests: XCTestCase {
    final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    func challenge(host: String, port: Int, failures: Int = 0) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: host, port: port, protocol: "http", realm: "cam", authenticationMethod: NSURLAuthenticationMethodHTTPDigest)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: failures, failureResponse: nil, error: nil, sender: Sender())
    }

    func answer(_ delegate: ScopedCredentialDelegate, _ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        var result: (URLSession.AuthChallengeDisposition, URLCredential?) = (.performDefaultHandling, nil)
        delegate.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "http://x")!), didReceive: challenge) { result = ($0, $1) }
        return result
    }

    func testCredentialOnlyAnswersItsOwnOriginOnce() {
        let delegate = ScopedCredentialDelegate(origin: URL(string: "http://cam.local/video")!, credential: ConnectionCredential(username: "u", password: "p"))
        let own = answer(delegate, challenge(host: "cam.local", port: 80))
        XCTAssertEqual(own.0, .useCredential)
        XCTAssertEqual(own.1?.password, "p")
        XCTAssertEqual(own.1?.persistence, URLCredential.Persistence.none)

        XCTAssertEqual(answer(delegate, challenge(host: "other.local", port: 80)).0, .cancelAuthenticationChallenge)
        XCTAssertEqual(answer(delegate, challenge(host: "cam.local", port: 8080)).0, .cancelAuthenticationChallenge)
        XCTAssertEqual(answer(delegate, challenge(host: "cam.local", port: 80, failures: 1)).0, .cancelAuthenticationChallenge)
    }
}
