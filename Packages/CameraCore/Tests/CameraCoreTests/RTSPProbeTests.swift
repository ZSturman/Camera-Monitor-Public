import XCTest
@testable import CameraCore

final class RTSPProbeTests: XCTestCase {
    func reply(_ status: String, cseq: String?, headers: [String] = [], body: String = "") -> String {
        var lines = ["RTSP/1.0 \(status)", "CSeq: \(cseq ?? "0")"] + headers
        if !body.isEmpty { lines.append("Content-Length: \(body.utf8.count)") }
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    /// A camera that requires Digest auth for every request.
    func digestCamera(sdp: String) throws -> FakeRTSPServer {
        try FakeRTSPServer { request in
            let cseq = FakeRTSPServer.header("CSeq", in: request)
            guard let auth = FakeRTSPServer.header("Authorization", in: request), auth.hasPrefix("Digest ") else {
                return self.reply("401 Unauthorized", cseq: cseq, headers: [#"WWW-Authenticate: Digest realm="IP Camera", nonce="0123abcd""#])
            }
            let method = String(request.prefix { $0 != " " })
            let uri = String(request.split(separator: " ")[1])
            let expected = RTSPAuthChallenge.digest(realm: "IP Camera", nonce: "0123abcd", qop: nil, opaque: nil, algorithm: nil)
                .authorization(method: method, uri: uri, credential: ConnectionCredential(username: "admin", password: "correct"))
            guard auth == expected else {
                return self.reply("401 Unauthorized", cseq: cseq, headers: [#"WWW-Authenticate: Digest realm="IP Camera", nonce="0123abcd""#])
            }
            if method == "OPTIONS" {
                return self.reply("200 OK", cseq: cseq, headers: ["Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN", "Server: FixtureCam/2.1"])
            }
            return self.reply("200 OK", cseq: cseq, headers: ["Content-Type: application/sdp"], body: sdp)
        }
    }

    func testDigestAuthenticatedDescribe() async throws {
        let server = try digestCamera(sdp: try Fixture.text("RTSP/describe.sdp"))
        let port = try await server.start()
        defer { server.stop() }
        let result = try await RTSPProbe().probe(URL(string: "rtsp://127.0.0.1:\(port)/stream1")!, credential: ConnectionCredential(username: "admin", password: "correct"))
        XCTAssertEqual(result.description.videoCodecs, ["H264"])
        XCTAssertEqual(result.server, "FixtureCam/2.1")
        XCTAssertTrue(result.methods.contains("PLAY"))
        // Request URIs must never carry userinfo.
        XCTAssertFalse(server.requests.joined().contains("admin@"))
        XCTAssertFalse(server.requests.joined().contains("correct"), "password must not be sent in clear with Digest")
    }

    func testWrongPasswordIsAuthenticationFailure() async throws {
        let server = try digestCamera(sdp: "v=0\r\nm=video 0 RTP/AVP 96\r\n")
        let port = try await server.start()
        defer { server.stop() }
        do {
            _ = try await RTSPProbe().probe(URL(string: "rtsp://127.0.0.1:\(port)/s")!, credential: ConnectionCredential(username: "admin", password: "wrong"))
            XCTFail("expected failure")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testMissingCredentialExplainsWhatIsNeeded() async throws {
        let server = try digestCamera(sdp: "")
        let port = try await server.start()
        defer { server.stop() }
        do {
            _ = try await RTSPProbe().probe(URL(string: "rtsp://127.0.0.1:\(port)/s")!, credential: nil)
            XCTFail("expected failure")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .authenticationFailed("This camera requires a username and password."))
        }
    }

    func testNonRTSPServerIsUnsupportedSource() async throws {
        let server = try FakeRTSPServer { _ in "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n" }
        let port = try await server.start()
        defer { server.stop() }
        do {
            _ = try await RTSPProbe().probe(URL(string: "rtsp://127.0.0.1:\(port)/s")!, credential: nil)
            XCTFail("expected failure")
        } catch let error as ProviderError {
            guard case .unsupportedSource = error else { return XCTFail("\(error)") }
        }
    }

    func testSilentServerTimesOut() async throws {
        let server = try FakeRTSPServer { _ in nil }
        let port = try await server.start()
        defer { server.stop() }
        let started = Date()
        do {
            _ = try await RTSPProbe(timeout: 1).probe(URL(string: "rtsp://127.0.0.1:\(port)/s")!, credential: nil)
            XCTFail("expected timeout")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testStreamNotFound() async throws {
        let server = try FakeRTSPServer { request in
            let cseq = FakeRTSPServer.header("CSeq", in: request)
            return request.hasPrefix("OPTIONS") ? self.reply("200 OK", cseq: cseq) : self.reply("404 Not Found", cseq: cseq)
        }
        let port = try await server.start()
        defer { server.stop() }
        do {
            _ = try await RTSPProbe().probe(URL(string: "rtsp://127.0.0.1:\(port)/missing")!, credential: nil)
            XCTFail("expected failure")
        } catch let error as ProviderError {
            guard case .notFound = error else { return XCTFail("\(error)") }
        }
    }
}
