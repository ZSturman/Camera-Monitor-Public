# Providers and compatibility

Updated October 20, 2026. What each connection type does, what it reads,
and what it was tested against. "Fake" means the local fixture server's
imitation of the documented API (`Scripts/fixtures/serve.py`), which
doesn't certify a real product.

## Sources found on this network (October 20, 2026)

| Source | Where | Status in Camera Monitor |
| --- | --- | --- |
| Logitech Brio 101 USB camera on the Pi | `pi.example.local` (Tailscale) | Plays live through Home Services on the iPhone (real hardware) |
| Home Services 0.3.0 (contract 1.1, `hls-recorder`) | `https://host.example.net:8443` | Live, recordings, archive verified read-only |
| Workspace Sync dashboard (predecessor camera system) | `https://host.example.net` | Provider implemented against its source; real test needs its dashboard token |
| go2rtc 1.9.14 (Home Platform, stream `brio`) | `pi.example.local:1984` / `:8554` | Stream list read from the real server; its source can't open the camera (`/dev/video0` busy, held by the HLS producer), so no real frames |
| Creality K2 Plus printer camera | `192.0.2.20` | WebRTC only (`/call/webrtc_local`); not supported |
| MacBook Pro camera, Desk View, iPhone Continuity Camera | this Mac | Listed by the local-device provider; lid closed, so no frames |
| ONVIF / standalone RTSP cameras | — | None on this LAN |

The "Check a host" probe found go2rtc, RTSP, Home Services and the
Workspace dashboard on `pi.example.local` (read-only status requests).

## Per provider

**RTSP** (`DirectStreamProvider` + native engine). Test Connection sends
OPTIONS/DESCRIBE and reports codecs. Live view H.264/H.265 over TCP.
Tested: mediamtx fixtures on Mac, iPhone, iPad.

**HLS / MJPEG** (`DirectStreamProvider`). Basic/Digest only to the
stream's own origin; MJPEG requires two frames (a single JPEG isn't a
stream) and goes stale after 10 s. Tested: fixtures on all devices.

**ONVIF** (`ONVIFProvider`, `ONVIFClient`, `ONVIFDiscovery`). Profile S
subset: GetSystemDateAndTime (clock offset for WS-Security), GetDeviceInformation,
GetCapabilities, GetProfiles, GetStreamUri, GetSnapshotUri, WS-Security
UsernameToken digest plus HTTP Digest fallback. Addresses the camera
reports for itself are re-hosted to the address you connected to.
Settings: device info and stream-profile choice. WS-Discovery on macOS;
on iOS it needs Apple's multicast entitlement (not requested), so the
app says so and offers "Check a host". Tested: fake ONVIF device on all
devices. **No real ONVIF camera tested.**

**go2rtc** (`Go2RTCProvider`). `/api`, `/api/streams`, `/api/frame.jpeg`,
RTSP output on the server's port, or HLS (`stream.m3u8?mp4`) / MJPEG.
Producer URLs are never displayed (they can contain passwords). Tested:
fake on all devices; real server's stream list.

**Frigate** (`FrigateProvider`). `/api/config`, `/api/stats`, `/api/events`
(paged by `before`), clips, `latest.jpg`, MJPEG feed, RTSP restream on
8554, `DELETE /api/events/{id}`, `POST|DELETE …/retain`, `POST /api/login`
→ `frigate_token` cookie. Detect/record switches are MQTT-only in Frigate,
so they're shown read-only. Tested: fake on all devices, including range
deletion of disposable events. **No real Frigate tested.**

**Home Services** — see [HOME_SERVICES_CONTRACT.md](HOME_SERVICES_CONTRACT.md).

**Workspace Sync dashboard** (`WorkspaceCameraProvider`). `/api/camera/status`,
`/api/camera/live/index.m3u8` (AVPlayer sends the dashboard's own
`workspace_session` cookie, which holds the token, to that host only),
`/api/camera/events`, event MP4s, `/api/camera/latest` then `/snapshot`,
`/api/camera/out-of-house`. The dashboard has no deletion API, so events
are read-only. Tested: fake on Mac (HTTPS is required on a LAN address, so
the http fake can't run against a phone). **Real dashboard untested:
needs its token.**

**Cameras on this device** (`LocalDeviceProvider`, `LocalCameraView`).
AVCaptureDevice discovery (built-in, external/USB, Continuity, Desk View)
and preview. Reports "playing" only once frames arrive. On this Mac it
lists the built-in camera, Desk View and the iPhone (Continuity); the lid
was closed, so no frames were seen and the app said so. iPhone doesn't
offer it.

## Alerts (ntfy)

`NtfyClient` posts a test message and reads `/<topic>/json?poll=1`.
Configured per connection; available only when a camera there has motion
events. The token is in the Keychain. Tested: local ntfy server (Docker).
Locked-phone delivery verified on the iPhone (ntfy app subscribed to an
ntfy.sh topic; test alert appeared on the lock screen).
