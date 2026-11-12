@testable import CameraCore
import CoreMedia
import VideoToolbox
import XCTest

final class NativeRTSPTests: XCTestCase {
    // MARK: SDP

    func testSDPTrackDetails() {
        let sdp = SessionDescription.parse("""
        v=0
        s=Stream
        a=control:*
        m=video 0 RTP/AVP 96
        a=rtpmap:96 H264/90000
        a=fmtp:96 packetization-mode=1; profile-level-id=64001F; sprop-parameter-sets=Z2QAH6zZQFAFuwEQAAADABAAAAMDKPGDGWA,aOvjyyLA
        a=control:trackID=1
        m=audio 0 RTP/AVP 97
        a=rtpmap:97 MPEG4-GENERIC/16000/1
        a=control:trackID=2
        """)
        XCTAssertEqual(sdp.control, "*")
        let video = try! XCTUnwrap(sdp.playableVideoTrack)
        XCTAssertEqual(video.payloadType, 96)
        XCTAssertEqual(video.control, "trackID=1")
        XCTAssertEqual(video.formatParameters["packetization-mode"], "1")
        let sets = VideoCodec.h264.parameterSets(from: video.formatParameters)
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets[0].first.map { $0 & 0x1F }, 7)
        XCTAssertEqual(sets[1].first.map { $0 & 0x1F }, 8)
    }

    func testControlResolution() {
        let base = URL(string: "rtsp://cam.local:554/live/main")!
        XCTAssertEqual(SessionDescription.resolve(control: "trackID=1", base: base).absoluteString, "rtsp://cam.local:554/live/main/trackID=1")
        XCTAssertEqual(SessionDescription.resolve(control: "*", base: base), base)
        XCTAssertEqual(SessionDescription.resolve(control: nil, base: base), base)
        XCTAssertEqual(SessionDescription.resolve(control: "rtsp://other/x", base: base).absoluteString, "rtsp://other/x")
        XCTAssertEqual(SessionDescription.resolve(control: "track1", base: URL(string: "rtsp://cam/live/")!).absoluteString, "rtsp://cam/live/track1")
    }

    func testUnplayableCodecIsNotChosen() {
        let sdp = SessionDescription.parse("m=video 0 RTP/AVP 26\nm=video 0 RTP/AVP 97\na=rtpmap:97 H265/90000\n")
        XCTAssertEqual(sdp.videoCodecs, ["JPEG", "H265"])
        XCTAssertEqual(sdp.playableVideoTrack?.codec, "H265")
    }

    func testInterleavedChannelParsing() {
        XCTAssertEqual(RTSPPlayerSession.rtpChannel(from: "RTP/AVP/TCP;unicast;interleaved=2-3;ssrc=1234"), 2)
        XCTAssertNil(RTSPPlayerSession.rtpChannel(from: "RTP/AVP;unicast;client_port=5000-5001"))
    }

    // MARK: RTP

    func rtp(_ payload: [UInt8], seq: UInt16, ts: UInt32 = 1000, marker: Bool = false, extra header: [UInt8] = []) -> RTPPacket {
        var bytes: [UInt8] = [0x80, (marker ? 0x80 : 0) | 96, UInt8(seq >> 8), UInt8(seq & 0xFF),
                              UInt8(ts >> 24), UInt8((ts >> 16) & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF), 0, 0, 0, 1]
        bytes += header
        bytes += payload
        return RTPPacket(Data(bytes))!
    }

    func testRTPHeaderWithCSRCExtensionAndPadding() {
        // V=2 P=1 X=1 CC=1
        var bytes: [UInt8] = [0xB1, 0x60, 0, 7, 0, 0, 0, 9, 0, 0, 0, 1]
        bytes += [0xDE, 0xAD, 0xBE, 0xEF] // CSRC
        bytes += [0xBE, 0xDE, 0, 1, 1, 2, 3, 4] // extension, 1 word
        bytes += [0x65, 0xAA] // payload
        bytes += [0, 0, 3] // 3 bytes padding
        let packet = RTPPacket(Data(bytes))
        XCTAssertEqual(packet?.payload, Data([0x65, 0xAA]))
        XCTAssertEqual(packet?.sequence, 7)
        XCTAssertEqual(packet?.timestamp, 9)
        XCTAssertNil(RTPPacket(Data([0x40, 0, 0])))
    }

    func testH264FragmentationAndAggregation() {
        var depacketizer = RTPDepacketizer(codec: .h264)
        // STAP-A carrying SPS and PPS.
        XCTAssertTrue(depacketizer.push(rtp([24, 0, 2, 0x67, 0x01, 0, 2, 0x68, 0x02], seq: 1)).isEmpty)
        // IDR (type 5, NRI 3) split into three FU-A packets.
        XCTAssertTrue(depacketizer.push(rtp([0x7C, 0x85, 0xA1], seq: 2)).isEmpty)
        XCTAssertTrue(depacketizer.push(rtp([0x7C, 0x05, 0xA2], seq: 3)).isEmpty)
        let units = depacketizer.push(rtp([0x7C, 0x45, 0xA3], seq: 4, marker: true))
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].nalUnits, [Data([0x67, 0x01]), Data([0x68, 0x02]), Data([0x65, 0xA1, 0xA2, 0xA3])])
        XCTAssertTrue(units[0].isKeyframe)

        // A lost middle fragment drops that NAL rather than corrupting it.
        _ = depacketizer.push(rtp([0x5C, 0x81, 0xB1], seq: 5, ts: 2000))
        let afterLoss = depacketizer.push(rtp([0x5C, 0x41, 0xB3], seq: 7, ts: 2000, marker: true))
        XCTAssertTrue(afterLoss.isEmpty)
        XCTAssertEqual(depacketizer.droppedPackets, 1)

        // A timestamp change completes a frame whose marker was lost.
        _ = depacketizer.push(rtp([0x41, 0x01], seq: 8, ts: 3000))
        let next = depacketizer.push(rtp([0x41, 0x02], seq: 9, ts: 4000, marker: true))
        XCTAssertEqual(next.map(\.timestamp), [3000, 4000])
        XCTAssertFalse(next[0].isKeyframe)
    }

    func testH265FragmentationAndAggregation() {
        var depacketizer = RTPDepacketizer(codec: .h265)
        // AP (type 48) with VPS (32), SPS (33), PPS (34).
        let ap: [UInt8] = [48 << 1, 1, 0, 2, 32 << 1, 1, 0, 2, 33 << 1, 1, 0, 2, 34 << 1, 1]
        XCTAssertTrue(depacketizer.push(rtp(ap, seq: 10)).isEmpty)
        // IDR_W_RADL (19) as FU (49).
        XCTAssertTrue(depacketizer.push(rtp([49 << 1, 1, 0x80 | 19, 0xC1], seq: 11)).isEmpty)
        let units = depacketizer.push(rtp([49 << 1, 1, 0x40 | 19, 0xC2], seq: 12, marker: true))
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].nalUnits.count, 4)
        XCTAssertEqual(units[0].nalUnits[3], Data([19 << 1, 1, 0xC1, 0xC2]))
        XCTAssertTrue(units[0].isKeyframe)
    }

    // MARK: Connection framing

    func testInterleavedAndResponseFraming() throws {
        let connection = RTSPConnection(host: "127.0.0.1", port: 1, useTLS: false, timeout: 1)
        var queue = ByteQueue()
        queue.append(Data([0x24, 0, 0, 3, 9, 8, 7]))
        let response = Data("RTSP/1.0 200 OK\r\nCSeq: 5\r\nContent-Length: 2\r\n\r\nhi".utf8)
        queue.append(response)
        queue.append(Data([0x24, 1, 0, 1]))
        XCTAssertEqual(queue.count, 7 + response.count + 4)
        XCTAssertEqual(queue.slice(4, 3), Data([9, 8, 7]))
        queue.consume(7)
        XCTAssertEqual(queue[0], UInt8(ascii: "R"))
        XCTAssertNotNil(queue.firstRange(of: Data("\r\n\r\n".utf8), maxScan: 100))
        connection.close()
    }

    // MARK: Fixture playback (mediamtx)

    func testNativePlaybackAgainstFixture() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CAMERA_MONITOR_FIXTURE_BASE"] == nil, "Needs Scripts/fixtures/rtsp.sh.")
        let base = ProcessInfo.processInfo.environment["CAMERA_MONITOR_RTSP_FIXTURE"] ?? "rtsp://127.0.0.1:8554"
        try await assertDecodes(URL(string: base + "/fixture")!, credential: nil, codec: .h264)
        try await assertDecodes(URL(string: base + "/fixture-h265")!, credential: nil, codec: .h265)
        try await assertDecodes(URL(string: base + "/secure")!, credential: ConnectionCredential(username: "fixture", password: "fixture-pass"), codec: .h264)

        let denied = RTSPPlayerSession(url: URL(string: base + "/secure")!, credential: ConnectionCredential(username: "fixture", password: "wrong"))
        do {
            for try await _ in denied.events() {}
            XCTFail("expected authentication failure")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else { return XCTFail("\(error)") }
        }
    }

    private func assertDecodes(_ url: URL, credential: ConnectionCredential?, codec expected: VideoCodec, file: StaticString = #filePath, line: UInt = #line) async throws {
        let session = RTSPPlayerSession(url: url, credential: credential)
        var factory: VideoSampleFactory?
        var decoder: VTDecompressionSession?
        defer { decoder.map(VTDecompressionSessionInvalidate) }
        var decoded = 0
        var frames = 0
        let started = Date()
        for try await event in session.events() {
            switch event {
            case let .started(codec, parameterSets, _):
                XCTAssertEqual(codec, expected, file: file, line: line)
                factory = VideoSampleFactory(codec: codec, parameterSets: parameterSets)
            case let .accessUnit(unit):
                frames += 1
                if let sample = try factory?.sampleBuffer(for: unit) {
                    if decoder == nil {
                        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: CMSampleBufferGetFormatDescription(sample)!, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder), noErr)
                    }
                    let dimensions = decode(sample, with: decoder!)
                    XCTAssertEqual(dimensions.width, 1280, file: file, line: line)
                    XCTAssertEqual(dimensions.height, 720, file: file, line: line)
                    decoded += 1
                }
            }
            if decoded >= 5 || Date().timeIntervalSince(started) > 15 { break }
        }
        session.stop()
        XCTAssertGreaterThanOrEqual(decoded, 5, "decoded \(decoded) of \(frames) frames from \(url.path)", file: file, line: line)
    }

    /// Decodes one sample with VideoToolbox, as the display layer would.
    private func decode(_ sample: CMSampleBuffer, with session: VTDecompressionSession) -> CMVideoDimensions {
        var size = CMVideoDimensions(width: 0, height: 0)
        var decodeStatus: OSStatus = -1
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            decodeStatus = status
            if let image { size = CMVideoDimensions(width: Int32(CVPixelBufferGetWidth(image)), height: Int32(CVPixelBufferGetHeight(image))) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(decodeStatus, noErr)
        return size
    }
}
