# RTSP playback decision

Updated October 20, 2026. Camera Monitor plays RTSP with its own native
engine, not VLCKit. Native AVPlayer does not play RTSP, so CameraCore
implements the RTSP client and RTP depacketizing, and Apple's VideoToolbox
decodes the video in hardware.

## Decision

| | Native engine (shipping) | VLCKit 3.7 (evaluated, removed) |
| --- | --- | --- |
| License | This project's own code; no third-party notices | LGPL-2.1: license text, source offer and the ability to relink are required. Whether App Store distribution terms are compatible with those obligations is disputed and would need a legal review; VideoLAN's own App Store apps don't settle it for third parties |
| Size | iOS Release app 2.4 MB total (measured, `xcodebuild archive`) | +~100 MB (105 MB debug build) |
| Architectures | arm64 only | MobileVLCKit includes armv7/armv7s slices to strip before submission |
| macOS sandbox | Client networking only (RTP interleaved over TCP) | Needed `network.server`: live555 binds local RTP sockets |
| Credential logging | Never logged; credentials go only in auth headers | live555 prints `Authorization` headers at verbosity > 0 |
| Codecs | H.264, H.265 video | Nearly everything, including MJPEG-over-RTSP, MPEG-4 Part 2, audio |
| Audio | Not played | Played |

Native covers what real IP cameras and NVR restreams send (H.264/H.265),
removes the licensing question and the size, and needs no extra
entitlement. VLCKit was removed from the project. Its build manifest and
fetch script are in Git history (commit 1b0c578) if a codec gap ever
justifies it.

## How it works

`Packages/CameraCore/Sources/CameraCore/Media/`:

- `RTSPProbe` / `RTSPRequester`: OPTIONS and DESCRIBE with Basic or MD5
  Digest auth (re-signed per request), RTSPS over TLS.
- `RTSPPlayerSession`: SETUP with `RTP/AVP/TCP;interleaved=0-1`, PLAY,
  keep-alive (GET_PARAMETER or OPTIONS at half the session timeout),
  TEARDOWN on stop. Picks the first H.264/H.265 video track and resolves
  relative track controls against Content-Base.
- `RTSPConnection`: one TCP stream carrying responses and `$`-framed
  interleaved packets, with a byte queue that doesn't copy per packet.
- `RTPDepacketizer`: RFC 6184 (single NAL, STAP-A, FU-A) and RFC 7798
  (single, AP, FU); drops fragments after packet loss; 8 MB frame cap.
- `VideoSampleFactory`: parameter sets from SDP `sprop-*` or in band,
  AVCC samples, holds frames until the first keyframe, resynchronizes
  after decoder errors.

`App/Sources/Players/RTSPPlayerView.swift` enqueues samples on an
`AVSampleBufferDisplayLayer` (hardware decode), shows codec/size/fps, and
reports a stale stream after 10 s without frames. `LivePlayerContainer`
reconnects with backoff (3, 6, 12, 24, 30 s) and stops in the background.

## Evidence

| Check | Result |
| --- | --- |
| Depacketizer, SDP, framing unit tests (FU-A loss, STAP-A, H.265 AP/FU, CSRC/extension/padding) | Pass (`NativeRTSPTests`) |
| mediamtx fixture on the Mac: H.264, H.265, authenticated stream; frames decoded by VideoToolbox at 1280×720; wrong password rejected | Pass (`testNativePlaybackAgainstFixture`) |
| Physical iPhone 16 Pro Max (iOS 27.0.1) over Wi-Fi to the Mac's fixtures: H.264, H.265, auth, wrong password, go2rtc and ONVIF-supplied streams | Pass (`PlaybackUITests`) |
| Physical iPad Pro 12.9" 5th gen: same set | Pass |
| Background → foreground on both devices | Resumes playing (`testBackgroundAndForegroundResumesRTSP`) |
| Memory over 2 minutes of RTSP on device | Flat: iPhone 30 MB every sample, iPad 32 MB |
| Real network camera over RTSP | **Not tested.** No standalone RTSP camera is on this network; the Pi's go2rtc RTSP output can't currently open the camera (held by the HLS producer) |

Screenshots: `docs/images/iphone-rtsp-h264.png`, `iphone-rtsp-h265.png`,
`ipad-go2rtc.png`, `ipad-onvif.png`.

## Known limits

- Video only. H.264/H.265 only; other codecs get a clear "choose an H.264
  or H.265 stream" message.
- TCP interleaved transport only (no UDP); works through NAT, firewalls and
  Tailscale, and is what every tested server accepts.
- No RTSP redirect (3xx) handling.
