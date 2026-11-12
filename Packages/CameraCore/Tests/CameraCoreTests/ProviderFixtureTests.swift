import XCTest
@testable import CameraCore

/// go2rtc, Frigate, Workspace dashboard and ONVIF providers against the
/// fakes in Scripts/fixtures/serve.py (plus rtsp.sh for stream checks).
/// The fakes follow each product's documented API; they don't certify a
/// real server. Skipped unless CAMERA_MONITOR_FIXTURE_BASE is set.
final class ProviderFixtureTests: XCTestCase {
    var base: String!
    let fixtureLogin = ConnectionCredential(username: "fixture", password: "fixture-pass")

    override func setUp() async throws {
        base = ProcessInfo.processInfo.environment["CAMERA_MONITOR_FIXTURE_BASE"]
        try XCTSkipIf(base == nil, "Set CAMERA_MONITOR_FIXTURE_BASE to run against the local fixture server.")
        var request = URLRequest(url: URL(string: base + "/_fixture/reset")!)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    func testGo2RTCListsStreamsWithoutLeakingSourcePasswords() async throws {
        let provider = Go2RTCProvider(profile: .fixture(.go2rtc, base + "/go2rtc"), credential: nil)
        let report = try await provider.testConnection()
        XCTAssertEqual(report.cameras.map(\.name), ["fixture", "fixture-h265"])
        XCTAssertTrue(report.cameras[0].capabilities.snapshot.isSupported)
        XCTAssertFalse(report.cameras[0].capabilities.history.isSupported)

        let live = try await provider.liveSession(for: report.cameras[0].id)
        XCTAssertEqual(live.streamProtocol, .rtsp)
        XCTAssertEqual(live.url.absoluteString, "rtsp://\(URL(string: base)!.host!):8554/fixture")
        let snapshot = try await provider.snapshot(for: report.cameras[0].id)
        XCTAssertEqual(snapshot.prefix(2), Data([0xFF, 0xD8]))

        let settings = try await provider.settings(for: report.cameras[0].id)
        let text = settings.map { "\($0.value)" }.joined()
        XCTAssertFalse(text.contains("secret"), "producer URLs can hold passwords")
        XCTAssertTrue(text.contains("RTSP camera"))

        var mjpegProfile = ConnectionProfile.fixture(.go2rtc, base + "/go2rtc")
        mjpegProfile.options.preferredProtocol = .mjpeg
        let mjpeg = try await Go2RTCProvider(profile: mjpegProfile, credential: nil).liveSession(for: report.cameras[0].id)
        XCTAssertEqual(mjpeg.streamProtocol, .mjpeg)
    }

    func testFrigateCamerasEventsAndDisposableDeletion() async throws {
        let provider = FrigateProvider(profile: .fixture(.frigate, base + "/frigate"), credential: nil)
        let cameras = try await provider.cameras()
        XCTAssertEqual(cameras.map(\.name), ["Back Yard", "Front Door"])
        let front = cameras[1]
        XCTAssertEqual(front.capabilities.liveView, .rtsp, "go2rtc restream exists")
        XCTAssertEqual(cameras[0].capabilities.liveView, .mjpeg)
        XCTAssertFalse(cameras[0].capabilities.motionEvents.isSupported, "detection off")
        XCTAssertEqual(front.status?.state, .online)
        XCTAssertEqual(cameras[0].status?.state, .offline)
        XCTAssertFalse(front.capabilities.arming.isSupported)

        let page = try await provider.recordings(for: front.id, cursor: nil)
        XCTAssertEqual(page.recordings.count, 13)
        XCTAssertTrue(page.recordings[0].isActive)
        XCTAssertEqual(page.recordings.filter(\.isProtected).count, 1)

        let clip = try await provider.playbackSession(for: page.recordings[1])
        XCTAssertEqual(clip.streamProtocol, .mp4)
        let downloaded = try await ExportDownloader.download(try await provider.export(page.recordings[1]))
        XCTAssertGreaterThan(try Data(contentsOf: downloaded).count, 1000)

        // Range deletion over the newest 7 hours: active and retained
        // events are skipped before any request is sent.
        let range = Date().addingTimeInterval(-7 * 3600)...Date()
        let inRange = try await provider.recordings(for: front.id, in: range)
        XCTAssertEqual(inRange.count, 4)
        let result = await provider.delete(inRange)
        XCTAssertEqual(result.deleted.count, 3)
        XCTAssertEqual(result.skipped.count, 1)
        let after = try await provider.recordings(for: front.id, cursor: nil)
        XCTAssertEqual(after.recordings.count, 10)
        let retained = try XCTUnwrap(after.recordings.first(where: \.isProtected))
        do {
            try await provider.delete(retained)
            XCTFail("retained events can't be deleted")
        } catch ProviderError.conflict {}
    }

    func testFrigateLogin() async throws {
        let anonymous = FrigateProvider(profile: .fixture(.frigate, base + "/frigate-auth"), credential: nil)
        do {
            _ = try await anonymous.cameras()
            XCTFail("expected sign-in required")
        } catch ProviderError.authenticationFailed {}
        let wrong = FrigateProvider(profile: .fixture(.frigate, base + "/frigate-auth"), credential: ConnectionCredential(username: "fixture", password: "nope"))
        do {
            _ = try await wrong.cameras()
            XCTFail("expected rejection")
        } catch ProviderError.authenticationFailed {}
        let signedIn = FrigateProvider(profile: .fixture(.frigate, base + "/frigate-auth"), credential: fixtureLogin)
        let cameras = try await signedIn.cameras()
        XCTAssertEqual(cameras.count, 2)
        let session = try await signedIn.playbackSession(for: try await signedIn.recordings(for: cameras[1].id, cursor: nil).recordings[1])
        XCTAssertEqual(session.cookies.first?.name, "frigate_token")
    }

    func testWorkspaceDashboard() async throws {
        let provider = WorkspaceCameraProvider(profile: .fixture(.workspaceCamera, base + "/workspace"), credential: ConnectionCredential(password: "fixture-token"))
        let report = try await provider.testConnection()
        let camera = report.cameras[0]
        XCTAssertEqual(camera.capabilities.liveView, .hls)
        XCTAssertFalse(camera.capabilities.deletion.isSupported)
        XCTAssertEqual(camera.status?.armed, false)

        let live = try await provider.liveSession(for: camera.id)
        XCTAssertEqual(live.cookies, [SessionCookie(name: "workspace_session", value: "fixture-token")])
        XCTAssertFalse(live.url.absoluteString.contains("fixture-token"))
        // The cookie alone authorizes the playlist, as AVPlayer will use it.
        var request = URLRequest(url: live.url)
        request.setValue("workspace_session=fixture-token", forHTTPHeaderField: "Cookie")
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let armed = try await provider.setArmed(true, for: camera.id)
        XCTAssertTrue(armed)
        let disarmed = try await provider.setArmed(false, for: camera.id)
        XCTAssertFalse(disarmed)

        let events = try await provider.recordings(for: camera.id, cursor: nil)
        XCTAssertEqual(events.recordings.count, 3)
        XCTAssertTrue(events.recordings.allSatisfy(\.isReadOnly))
        let file = try await ExportDownloader.download(try await provider.export(events.recordings[0]))
        XCTAssertGreaterThan(try Data(contentsOf: file).count, 1000)
        let still = try await provider.snapshot(for: camera.id)
        XCTAssertEqual(still.prefix(2), Data([0xFF, 0xD8]))

        let wrong = WorkspaceCameraProvider(profile: .fixture(.workspaceCamera, base + "/workspace"), credential: ConnectionCredential(password: "wrong"))
        do {
            _ = try await wrong.cameras()
            XCTFail("expected auth failure")
        } catch ProviderError.authenticationFailed {}
    }

    func testONVIFProfilesStreamsAndAuth() async throws {
        let provider = ONVIFProvider(profile: .fixture(.onvif, base), credential: fixtureLogin)
        let settings = try await provider.settings(for: CameraID(connectionID: provider.profile.id, nativeID: ONVIFProvider.nativeID))
        XCTAssertTrue(settings.contains { $0.title == "Model" && $0.value == .info("Test Camera") })
        guard case let .choice(selected, options)? = settings.first(where: { $0.id == CameraSetting.onvifProfileID })?.value else { return XCTFail() }
        XCTAssertEqual(selected, "main")
        XCTAssertEqual(options.count, 2)

        let live = try await provider.liveSession(for: CameraID(connectionID: provider.profile.id, nativeID: ONVIFProvider.nativeID))
        // The camera reported an internal address; the connected host is kept.
        XCTAssertEqual(live.url.host, URL(string: base)!.host)
        XCTAssertEqual(live.url.path, "/fixture")
        let still = try await provider.snapshot(for: CameraID(connectionID: provider.profile.id, nativeID: ONVIFProvider.nativeID))
        XCTAssertEqual(still.prefix(2), Data([0xFF, 0xD8]))

        var sub = ConnectionProfile.fixture(.onvif, base)
        sub.options.onvifProfiles = [ONVIFProvider.nativeID: "sub"]
        let subLive = try await ONVIFProvider(profile: sub, credential: fixtureLogin).liveSession(for: CameraID(connectionID: sub.id, nativeID: ONVIFProvider.nativeID))
        XCTAssertEqual(subLive.url.path, "/fixture-h265")

        let wrong = ONVIFProvider(profile: .fixture(.onvif, base), credential: ConnectionCredential(username: "fixture", password: "nope"))
        do {
            _ = try await wrong.settings(for: CameraID(connectionID: UUID(), nativeID: ONVIFProvider.nativeID))
            XCTFail("expected auth failure")
        } catch ProviderError.authenticationFailed {}
    }

    func testONVIFProbeParsing() {
        let reply = """
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><e:Body><d:ProbeMatches><d:ProbeMatch><w:EndpointReference><w:Address>urn:uuid:1234</w:Address></w:EndpointReference><d:Types>dn:NetworkVideoTransmitter</d:Types><d:Scopes>onvif://www.onvif.org/name/Porch%20Cam onvif://www.onvif.org/hardware/IPC-1</d:Scopes><d:XAddrs>http://192.168.1.20/onvif/device_service http://[fe80::1]/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>
        """
        let devices = ONVIFDiscovery.parse(Data(reply.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].endpoint, "urn:uuid:1234")
        XCTAssertEqual(devices[0].name, "Porch Cam")
        XCTAssertEqual(devices[0].hardware, "IPC-1")
        XCTAssertEqual(devices[0].host, "192.168.1.20")
    }
}
