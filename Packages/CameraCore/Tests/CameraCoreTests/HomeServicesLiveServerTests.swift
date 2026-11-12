import XCTest
@testable import CameraCore

/// Against a running Home Services gateway (its isolated development
/// fixtures, never a production server). Skipped unless
/// CAMERA_MONITOR_HOME_SERVICES_URL and CAMERA_MONITOR_HOME_SERVICES_TOKEN_FILE
/// (a file holding a `camera-monitor` preset token) are set.
final class HomeServicesLiveServerTests: XCTestCase {
    func testAgainstRunningGateway() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["CAMERA_MONITOR_HOME_SERVICES_URL"], let tokenFile = env["CAMERA_MONITOR_HOME_SERVICES_TOKEN_FILE"] else {
            throw XCTSkip("Set CAMERA_MONITOR_HOME_SERVICES_URL and CAMERA_MONITOR_HOME_SERVICES_TOKEN_FILE.")
        }
        let token = try String(contentsOfFile: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = HomeServicesProvider(profile: .fixture(.homeServices, address), credential: ConnectionCredential(password: token))

        let report = try await provider.testConnection()
        XCTAssertFalse(report.cameras.isEmpty)
        let camera = try XCTUnwrap(report.cameras.first { $0.id.nativeID != HomeServicesProvider.archiveNativeID })
        // Whatever the server reports must be mirrored, never invented.
        if camera.capabilities.liveView == nil {
            do {
                _ = try await provider.liveSession(for: camera.id)
                XCTFail("server refused live view in its capabilities, so the session must fail")
            } catch ProviderError.unsupported {}
        }
        if !camera.capabilities.arming.isSupported {
            XCTAssertNil(camera.status?.armed)
            do {
                _ = try await provider.setArmed(true, for: camera.id)
                XCTFail("arming must be refused")
            } catch ProviderError.unsupported {}
        }

        if camera.capabilities.snapshot.isSupported {
            let jpeg = try await provider.snapshot(for: camera.id)
            XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
            print("HS snapshot: \(jpeg.count) bytes")
        }
        if camera.capabilities.liveView != nil {
            let live = try await provider.liveSession(for: camera.id)
            var request = URLRequest(url: live.url)
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            let (playlist, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: playlist, as: UTF8.self).hasPrefix("#EXTM3U"))
        }
        if camera.capabilities.history.isSupported {
            // Read-only: lists and plays, never deletes or changes protection.
            let page = try await provider.recordings(for: camera.id, cursor: nil)
            print("HS recordings: \(page.recordings.count), kinds \(Set(page.recordings.map(\.kind)))")
            if let playable = page.recordings.first(where: { !$0.isActive && $0.metadata["playable"] != "0" }) {
                let session = try await provider.playbackSession(for: playable)
                let (data, response) = try await URLSession(configuration: .ephemeral).data(from: session.url)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("#EXT"))
            }
        }

        guard let archive = report.cameras.first(where: { $0.id.nativeID == HomeServicesProvider.archiveNativeID }) else { return }
        let page = try await provider.recordings(for: archive.id, cursor: nil)
        let event = try XCTUnwrap(page.recordings.first)
        let playback = try await provider.playbackSession(for: event)
        // The media session URL works without the token.
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: playback.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertFalse(playback.url.absoluteString.contains(token))
        let export = try await provider.export(event)
        XCTAssertTrue(ScopedCredentialDelegate.sameOrigin(export.downloadURL, URL(string: address)!))

        let wrong = HomeServicesProvider(profile: .fixture(.homeServices, address), credential: ConnectionCredential(password: "hst_tok_0.wrong"))
        do {
            _ = try await wrong.cameras()
            XCTFail("expected auth failure")
        } catch ProviderError.authenticationFailed {}
    }
}
