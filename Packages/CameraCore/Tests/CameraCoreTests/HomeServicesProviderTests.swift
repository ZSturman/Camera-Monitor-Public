import XCTest
@testable import CameraCore

/// Against response bodies recorded from the real Home Services gateway
/// (see Fixtures/HomeServices/v1/README.md).
final class HomeServicesProviderTests: XCTestCase {
    let host = "host.example.net"
    let token = ConnectionCredential(password: "hst_tok_0000000000000002.fixture-secret-0002")

    override func setUp() { StubURLProtocol.reset() }

    func provider(credential: ConnectionCredential? = nil, address: String? = nil) -> HomeServicesProvider {
        HomeServicesProvider(profile: .fixture(.homeServices, address ?? "https://\(host):8443"), credential: credential ?? token, urlSessionConfiguration: StubURLProtocol.configuration())
    }

    func route(_ routes: [String: StubURLProtocol.Reply]) {
        StubURLProtocol.register(host: host) { request in
            let key = "\(request.httpMethod ?? "GET") \(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath)"
            return routes[key] ?? .response(status: 404, headers: [:], chunks: [Data(#"{"error":{"code":"not_found","message":"not found","details":{}}}"#.utf8)])
        }
    }

    static let standardRoutes: [String: StubURLProtocol.Reply] = [
        "GET /api/v1/bootstrap": StubURLProtocol.json("HomeServices/v1/bootstrap.json"),
        "GET /api/v1/cameras": StubURLProtocol.json("HomeServices/v1/cameras.json"),
        "GET /api/v1/capabilities": StubURLProtocol.json("HomeServices/v1/capabilities.json"),
    ]

    func testEngineGatePendingIsReportedHonestly() async throws {
        route(Self.standardRoutes)
        let report = try await provider().testConnection()
        XCTAssertEqual(report.cameras.map(\.name), ["Workspace Pi Camera", "Archived events"])
        let camera = report.cameras[0]
        let caps = camera.capabilities
        XCTAssertNil(caps.liveView)
        XCTAssertEqual(caps.liveViewUnavailableReason, "No recording engine is configured on this host (cameras.engine = \"none\").")
        for feature in [caps.history, caps.playback, caps.export, caps.deletion, caps.serverRecording, caps.motionEvents, caps.notifications, caps.arming] {
            XCTAssertFalse(feature.isSupported)
        }
        // Arming unavailable: the stored `armed: false` isn't presented.
        XCTAssertNil(camera.status?.armed)
        XCTAssertEqual(camera.status?.state, .unknown)
        XCTAssertEqual(camera.status?.detail, "Home Services has no recording engine on this host yet.")
        XCTAssertTrue(report.notes.contains { $0.contains("no live view or recording") }, "\(report.notes)")

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests(host: host).first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Home-Services-Contract"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token.password)")
    }

    func testLiveAndArmingRefusalsCarryServerReason() async throws {
        var routes = Self.standardRoutes
        routes["POST /api/v1/cameras/workspace-pi-camera/live-sessions"] = StubURLProtocol.json("HomeServices/v1/error-live-unavailable.json", status: 409)
        routes["PUT /api/v1/cameras/workspace-pi-camera/armed"] = StubURLProtocol.json("HomeServices/v1/error-arm-unavailable.json", status: 409)
        route(routes)
        let id = CameraID(connectionID: UUID(), nativeID: "workspace-pi-camera")
        do {
            _ = try await provider().liveSession(for: id)
            XCTFail("expected unsupported")
        } catch ProviderError.unsupported(let reason) {
            XCTAssertTrue(reason.contains("engine"), reason)
        }
        do {
            _ = try await provider().setArmed(true, for: id)
            XCTFail("expected unsupported")
        } catch ProviderError.unsupported {}
        let arm = try XCTUnwrap(StubURLProtocol.recordedRequests(host: host).first { $0.httpMethod == "PUT" })
        XCTAssertEqual(arm.url?.path, "/api/v1/cameras/workspace-pi-camera/armed")
    }

    func testEngineReadyServerEnablesFeatures() async throws {
        var routes = Self.standardRoutes
        routes["GET /api/v1/cameras"] = StubURLProtocol.json("HomeServices/v1/cameras-engine-ready.json")
        routes["POST /api/v1/cameras/workspace-pi-camera/live-sessions"] = StubURLProtocol.json("HomeServices/v1/live-session.json", status: 201)
        route(routes)
        let cameras = try await provider().cameras()
        let caps = cameras[0].capabilities
        XCTAssertEqual(caps.liveView, .hls)
        XCTAssertTrue(caps.arming.isSupported)
        XCTAssertEqual(cameras[0].status?.armed, false)
        XCTAssertEqual(cameras[0].status?.state, .online)
        XCTAssertEqual(caps.notificationTransport, "ntfy")
        XCTAssertEqual(caps.deletionGranularity, .recording)
        XCTAssertTrue(caps.history.isSupported)

        let session = try await provider().liveSession(for: cameras[0].id)
        XCTAssertEqual(session.url.absoluteString, "https://\(host):8443/api/v1/media/sessions/fixture-secret-0007/index.m3u8")
        XCTAssertEqual(caps.armingEffect, "motion notifications only; recording continues while disarmed")
        XCTAssertTrue(caps.protection.isSupported)
        XCTAssertNil(session.credential)
        XCTAssertFalse(session.url.absoluteString.contains("fixture-secret-0002"), "token never in a media URL")
    }

    func testCameraRecordingsDeletionRules() async throws {
        var routes = Self.standardRoutes
        routes["GET /api/v1/cameras"] = StubURLProtocol.json("HomeServices/v1/cameras-engine-ready.json")
        routes["GET /api/v1/cameras/workspace-pi-camera/recordings"] = StubURLProtocol.json("HomeServices/v1/recordings.json")
        routes["DELETE /api/v1/cameras/workspace-pi-camera/recordings/evt_workspace-pi-camera_fixture_1"] = .response(status: 204, headers: [:], chunks: [])
        routes["PUT /api/v1/cameras/workspace-pi-camera/recordings/evt_workspace-pi-camera_fixture_1/protected"] = StubURLProtocol.json("HomeServices/v1/recording-protected.json")
        route(routes)
        let camera = try await provider().cameras()[0]
        let page = try await provider().recordings(for: camera.id, cursor: nil)
        XCTAssertEqual(page.recordings.map(\.id), ["evt_workspace-pi-camera_fixture_2", "evt_workspace-pi-camera_fixture_1", "hr_2026102008"])
        XCTAssertEqual(page.recordings[2].kind, .continuous)
        do {
            _ = try await provider().playbackSession(for: page.recordings[0])
            XCTFail("a recording that isn't playable yet must say so")
        } catch ProviderError.notFound {}
        let protected = try await provider().setProtected(true, for: page.recordings[1])
        XCTAssertTrue(protected.isProtected)
        let result = await provider().delete(page.recordings)
        XCTAssertEqual(result.deleted.map(\.id), ["evt_workspace-pi-camera_fixture_1"])
        XCTAssertEqual(result.skipped.count, 2, "both active recordings are skipped")
        XCTAssertEqual(StubURLProtocol.recordedRequests(host: host).filter { $0.httpMethod == "DELETE" }.count, 1)
    }

    func testSnapshotWhenAdvertised() async throws {
        var routes = Self.standardRoutes
        let advertised = try String(contentsOf: Fixture.url("HomeServices/v1/cameras-engine-ready.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"capabilities\": {", with: "\"capabilities\": {\"snapshot\": {\"state\": \"available\", \"format\": \"jpeg\", \"max_width\": 1280},")
        routes["GET /api/v1/cameras"] = .response(status: 200, headers: [:], chunks: [Data(advertised.utf8)])
        routes["GET /api/v1/cameras/workspace-pi-camera/snapshot"] = .response(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [Data([0xFF, 0xD8, 0xFF, 0xD9])])
        route(routes)
        let camera = try await provider().cameras()[0]
        XCTAssertTrue(camera.capabilities.snapshot.isSupported)
        let jpeg = try await provider().snapshot(for: camera.id)
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests(host: host).last)
        XCTAssertEqual(request.url?.query, "width=640")

        route(Self.standardRoutes)
        let old = try await provider().cameras()[0]
        XCTAssertFalse(old.capabilities.snapshot.isSupported, "1.1 servers don't advertise snapshots")
    }

    func testArchivedEventsAreReadOnlyHistory() async throws {
        var routes = Self.standardRoutes
        routes["GET /api/v1/media/legacy/events"] = StubURLProtocol.json("HomeServices/v1/legacy-events.json")
        routes["POST /api/v1/media/sessions"] = StubURLProtocol.json("HomeServices/v1/media-session.json", status: 201)
        route(routes)
        let provider = provider()
        let archive = try await provider.cameras().last!
        XCTAssertEqual(archive.id.nativeID, HomeServicesProvider.archiveNativeID)
        XCTAssertNil(archive.capabilities.liveView)
        XCTAssertTrue(archive.capabilities.history.isSupported)
        XCTAssertFalse(archive.capabilities.deletion.isSupported)

        let page = try await provider.recordings(for: archive.id, cursor: nil)
        XCTAssertEqual(page.recordings.count, 1)
        let event = page.recordings[0]
        XCTAssertEqual(event.id, "20260910T123045-7d79a4")
        XCTAssertEqual(event.startedAt, ISO8601DateFormatter().date(from: "2026-09-10T12:30:45Z"))
        XCTAssertTrue(event.isReadOnly)
        XCTAssertNotNil(event.deletionBlockedReason)
        XCTAssertNil(page.nextCursor)

        let playback = try await provider.playbackSession(for: event)
        XCTAssertEqual(playback.streamProtocol, .mp4)
        XCTAssertEqual(playback.url.absoluteString, "https://\(host):8443/api/v1/media/sessions/fixture-secret-0005")
        let body = try XCTUnwrap(StubURLProtocol.recordedRequests(host: host).last { $0.httpMethod == "POST" }?.httpBodyStreamData)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(json, ["kind": "legacy_event_media", "event_id": "20260910T123045-7d79a4", "name": "recording.mp4"])

        let result = await provider.delete([event])
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertFalse(StubURLProtocol.recordedRequests(host: host).contains { $0.httpMethod == "DELETE" })
    }

    func testAuthErrors() async throws {
        route(["GET /api/v1/bootstrap": StubURLProtocol.json("HomeServices/v1/error-unauthenticated.json", status: 401)])
        do {
            _ = try await provider().testConnection()
            XCTFail("expected auth failure")
        } catch ProviderError.authenticationFailed(let detail) {
            XCTAssertTrue(detail?.contains("missing bearer token") == true, detail ?? "")
        }

        route(["GET /api/v1/bootstrap": StubURLProtocol.json("HomeServices/v1/bootstrap-files-token.json")])
        do {
            _ = try await provider().testConnection()
            XCTFail("a token without cameras:read must be rejected")
        } catch ProviderError.authenticationFailed(let detail) {
            XCTAssertTrue(detail?.contains("camera-monitor") == true, detail ?? "")
        }

        route(["GET /api/v1/cameras": StubURLProtocol.json("HomeServices/v1/error-forbidden.json", status: 403)])
        do {
            _ = try await provider().cameras()
            XCTFail("expected forbidden")
        } catch ProviderError.authenticationFailed(let detail) {
            XCTAssertTrue(detail?.contains("storage:read") == true, detail ?? "")
        }

        do {
            _ = try await provider(credential: ConnectionCredential(password: "")).cameras()
            XCTFail("expected missing token")
        } catch ProviderError.authenticationFailed {}
    }

    func testContractVersionMismatch() async throws {
        route(["GET /api/v1/bootstrap": StubURLProtocol.json("HomeServices/v1/error-contract-version.json", status: 400)])
        do {
            _ = try await provider().testConnection()
            XCTFail("expected mismatch")
        } catch let ProviderError.contractVersionMismatch(server, client) {
            XCTAssertEqual(server, ["1"])
            XCTAssertEqual(client, "1")
        }
    }

    func testExpiredMediaSession() {
        let response = HTTPClient.Response(data: try! Fixture.data("HomeServices/v1/error-media-session-expired.json"), http: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        guard case .notFound = HomeServicesProvider.error(response) else { return XCTFail() }
    }

    func testRedirectToAnotherOriginDoesNotForwardToken() async throws {
        StubURLProtocol.register(host: "evil.example.com") { _ in StubURLProtocol.json("HomeServices/v1/cameras.json") }
        route(["GET /api/v1/cameras": .redirect(to: URL(string: "https://evil.example.com/api/v1/cameras")!)])
        do {
            _ = try await provider().cameras()
            XCTFail("expected redirect refusal")
        } catch ProviderError.insecureRedirect {}
        XCTAssertTrue(StubURLProtocol.recordedRequests(host: "evil.example.com").isEmpty)
    }

    func testCrossOriginMediaSessionRejected() async throws {
        var routes = Self.standardRoutes
        routes["POST /api/v1/cameras/workspace-pi-camera/live-sessions"] = .response(status: 201, headers: [:], chunks: [Data(#"{"url":"https://elsewhere.example.com/live.m3u8","kind":"live"}"#.utf8)])
        route(routes)
        do {
            _ = try await provider().liveSession(for: CameraID(connectionID: UUID(), nativeID: "workspace-pi-camera"))
            XCTFail("expected rejection")
        } catch ProviderError.invalidResponse {}
    }

    func testSubpathIsPreserved() {
        let client = HTTPClient(base: URL(string: "https://\(host)/home/")!)
        XCTAssertEqual(client.url("api/v1/cameras").absoluteString, "https://\(host)/home/api/v1/cameras")
    }
}

extension URLRequest {
    /// URLProtocol sees bodies as streams.
    var httpBodyStreamData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
