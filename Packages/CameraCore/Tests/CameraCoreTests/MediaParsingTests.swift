import XCTest
@testable import CameraCore

final class MJPEGParserTests: XCTestCase {
    func multipart(_ jpeg: Data, boundary: String = "myboundary", frames: Int, contentLength: Bool) -> Data {
        var data = Data()
        for _ in 0..<frames {
            var head = "--\(boundary)\r\nContent-Type: image/jpeg\r\n"
            if contentLength { head += "Content-Length: \(jpeg.count)\r\n" }
            head += "\r\n"
            data.append(Data(head.utf8))
            data.append(jpeg)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)\r\n".utf8))
        return data
    }

    func testBoundaryFromContentType() {
        XCTAssertEqual(MJPEGParser.boundary(fromContentType: "multipart/x-mixed-replace; boundary=frame"), "frame")
        XCTAssertEqual(MJPEGParser.boundary(fromContentType: "multipart/x-mixed-replace;boundary=\"--abc\""), "--abc")
        XCTAssertNil(MJPEGParser.boundary(fromContentType: "image/jpeg"))
        XCTAssertNil(MJPEGParser.boundary(fromContentType: "multipart/x-mixed-replace"))
    }

    func testFramesWithContentLength() throws {
        let jpeg = try Fixture.data("MJPEG/frame.jpg")
        var parser = MJPEGParser(boundary: "myboundary")
        let frames = try parser.append(multipart(jpeg, frames: 3, contentLength: true))
        XCTAssertEqual(frames, [jpeg, jpeg, jpeg])
    }

    func testFramesWithoutContentLengthSplitByteByByte() throws {
        let jpeg = try Fixture.data("MJPEG/frame.jpg")
        var parser = MJPEGParser(boundary: "myboundary")
        var frames: [Data] = []
        for byte in multipart(jpeg, frames: 2, contentLength: false) {
            frames += try parser.append(Data([byte]))
        }
        XCTAssertEqual(frames, [jpeg, jpeg])
    }

    func testDeclaredBoundaryAlreadyIncludingDashes() throws {
        let jpeg = try Fixture.data("MJPEG/frame.jpg")
        var parser = MJPEGParser(boundary: "--myboundary")
        XCTAssertEqual(try parser.append(multipart(jpeg, frames: 1, contentLength: true)).count, 1)
    }

    func testNonJPEGPartsAreSkipped() throws {
        let jpeg = try Fixture.data("MJPEG/frame.jpg")
        var data = Data("--b\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello\r\n".utf8)
        data.append(multipart(jpeg, boundary: "b", frames: 1, contentLength: true))
        var parser = MJPEGParser(boundary: "b")
        XCTAssertEqual(try parser.append(data), [jpeg])
    }

    func testOversizedFrameIsRejectedInsteadOfBuffered() throws {
        var parser = MJPEGParser(boundary: "b", maxFrameBytes: 1024)
        XCTAssertThrowsError(try parser.append(Data("--b\r\nContent-Length: 999999\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? MJPEGParser.ParserError, .frameTooLarge(limit: 1024))
        }
        var unbounded = MJPEGParser(boundary: "b", maxFrameBytes: 1024)
        XCTAssertThrowsError(try unbounded.append(Data("--b\r\n\r\n".utf8) + Data(repeating: 0xAB, count: 8192)))
    }
}

final class HLSPlaylistTests: XCTestCase {
    func testMultivariant() throws {
        let playlist = try HLSPlaylist.parse(Fixture.text("HLS/multivariant.m3u8"))
        XCTAssertEqual(playlist.kind, .multivariant(variantCount: 2))
        XCTAssertEqual(playlist.codecs, ["avc1.64001f", "mp4a.40.2", "avc1.64001e"])
        XCTAssertEqual(playlist.resolutions, ["1280x720", "640x360"])
    }

    func testLiveMediaPlaylist() throws {
        let playlist = try HLSPlaylist.parse(Fixture.text("HLS/live.m3u8"))
        XCTAssertEqual(playlist.kind, .media(segmentCount: 3, isLive: true, targetDuration: 2))
    }

    func testVODIsNotLive() throws {
        let playlist = try HLSPlaylist.parse(Fixture.text("HLS/vod.m3u8"))
        XCTAssertEqual(playlist.kind, .media(segmentCount: 2, isLive: false, targetDuration: 4))
    }

    func testNotAPlaylist() {
        XCTAssertThrowsError(try HLSPlaylist.parse("<html>login</html>")) { XCTAssertEqual($0 as? HLSPlaylist.ParseError, .notAPlaylist) }
        XCTAssertThrowsError(try HLSPlaylist.parse("#EXTM3U\n")) { XCTAssertEqual($0 as? HLSPlaylist.ParseError, .empty) }
    }
}

final class RTSPAuthTests: XCTestCase {
    /// RFC 2617 section 3.5 example.
    func testDigestMatchesRFC2617Vector() {
        let challenge = RTSPAuthChallenge.parse([#"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#])
        XCTAssertEqual(challenge, .digest(realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093", qop: "auth", opaque: "5ccc069c403ebaf9f0171e9517f40e41", algorithm: nil))
        let header = challenge!.authorization(method: "GET", uri: "/dir/index.html", credential: ConnectionCredential(username: "Mufasa", password: "Circle Of Life"), nonceCount: 1, cnonce: "0a4f113b")
        XCTAssertTrue(header.contains(#"response="6629fae49393a05397450978507c4ef1""#), header)
        XCTAssertTrue(header.contains("nc=00000001"))
    }

    func testDigestWithoutQop() {
        let challenge = RTSPAuthChallenge.digest(realm: "r", nonce: "n", qop: nil, opaque: nil, algorithm: nil)
        let header = challenge.authorization(method: "DESCRIBE", uri: "rtsp://c/s", credential: ConnectionCredential(username: "u", password: "p"))
        let ha1 = RTSPAuthChallenge.md5Hex("u:r:p"), ha2 = RTSPAuthChallenge.md5Hex("DESCRIBE:rtsp://c/s")
        XCTAssertTrue(header.contains("response=\"\(RTSPAuthChallenge.md5Hex("\(ha1):n:\(ha2)"))\""))
        XCTAssertFalse(header.contains("qop"))
    }

    func testPrefersDigestOverBasicAndBasicEncoding() {
        let challenge = RTSPAuthChallenge.parse([#"Basic realm="cam""#, #"Digest realm="cam", nonce="abc""#])
        XCTAssertEqual(challenge, .digest(realm: "cam", nonce: "abc", qop: nil, opaque: nil, algorithm: nil))
        let basic = RTSPAuthChallenge.basic(realm: "cam").authorization(method: "OPTIONS", uri: "x", credential: ConnectionCredential(username: "Aladdin", password: "open sesame"))
        XCTAssertEqual(basic, "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
    }

    func testUnsupportedDigestAlgorithmIsIgnored() {
        XCTAssertNil(RTSPAuthChallenge.parse([#"Digest realm="r", nonce="n", algorithm=SHA-512-256"#]))
    }
}

final class SDPTests: XCTestCase {
    func testDescribeFixture() throws {
        let sdp = SessionDescription.parse(try Fixture.text("RTSP/describe.sdp"))
        XCTAssertEqual(sdp.sessionName, "Front Door")
        XCTAssertEqual(sdp.videoCodecs, ["H264"])
        XCTAssertEqual(sdp.audioCodecs, ["MPEG4-GENERIC"])
        XCTAssertEqual(sdp.media.first?.clockRate, 90000)
        XCTAssertEqual(sdp.summary, "video H264; audio MPEG4-GENERIC")
    }

    func testStaticPayloadType() {
        let sdp = SessionDescription.parse("v=0\r\ns=-\r\nm=video 0 RTP/AVP 26\r\n")
        XCTAssertEqual(sdp.videoCodecs, ["JPEG"])
        XCTAssertNil(sdp.sessionName)
    }
}
