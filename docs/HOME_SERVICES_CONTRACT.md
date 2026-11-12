# Home Services client notes

Updated October 20, 2026. Home Services owns its API: the authoritative
contract is `contracts/v1/openapi.json` and the recorded examples in the
Home Services repository (contract 1.2, additive to major 1). This file
records only what Camera Monitor's `HomeServicesProvider` uses and how it
maps it. Nothing here requires a Home Services checkout; the response
bodies the tests use are copied into
`Packages/CameraCore/Tests/CameraCoreTests/Fixtures/HomeServices/v1/`
(provenance in that folder's README).

## Transport and auth

- Base address: the HTTPS URL the owner configures (e.g.
  `https://<pi>.<tailnet>.ts.net:8443`). Plain `http://` only for loopback.
- Every request: `Authorization: Bearer hst_…` and `Home-Services-Contract: 1`.
  The token comes from `home-services tokens create --preset camera-monitor`
  (scopes cameras:read, cameras:control, media:read, jobs:read) and is kept
  in this device's Keychain.
- Redirects to another origin are refused. Cookies and credential storage
  are off. Media plays from opaque, expiring session URLs (`/api/v1/media/sessions/<secret>/…`)
  that need no token; they must be same-origin and HTTPS.

## Endpoints used

| Request | Use |
| --- | --- |
| `GET /api/v1/bootstrap` | `contract.supported_majors` must include 1; a token without `cameras:read` is reported with the fix |
| `GET /api/v1/cameras` | cameras, `armed`, `status{state, reason, observed_at, recording}`, `capabilities.<name>{state, reason, message, …}` |
| `GET /api/v1/capabilities` | `media.legacy_events` → the read-only "Archived events" entry |
| `POST /cameras/{id}/live-sessions` | `{url, protocol, expires_at}` (sliding expiry) |
| `GET /cameras/{id}/snapshot?width=640` | JPEG still for tiles and widgets (contract 1.2, when `capabilities.snapshot` is available) |
| `PUT /cameras/{id}/armed` | `{armed}`; `capabilities.arming.effect` is shown next to the switch |
| `GET /cameras/{id}/recordings?limit&cursor` | `{recordings[{id, kind, started_at, ended_at, size_bytes, protected, active, playable}], next_cursor}` |
| `POST …/recordings/{rid}/playback-sessions` | HLS VOD/EVENT session |
| `POST …/recordings/{rid}/exports` | `{download_url, filename, content_type}` (same-origin, no token) |
| `PUT …/recordings/{rid}/protected` | Protect / Unprotect |
| `DELETE …/recordings/{rid}` | 204; 409 `recording_active`/`recording_protected` |
| `GET /media/legacy/events`, `POST /media/sessions` | archived predecessor events, read-only, MP4 via session |

A capability is used only when its `state` is `available`; otherwise its
`message` (or a description of its `reason`) is shown. Status `recording`
(and online/idle/streaming) shows as online; `stale`, `offline`,
`recorder_unavailable`, `storage_unavailable` map to their own states;
`not_managed` shows as unknown with the reason.

Errors use `{"error": {"code", "message", "details"}}`: `unauthenticated`,
`forbidden` (+`details.required_scope`), `contract_version_unsupported`
(+`details.supported_majors`), `capability_unavailable`, `not_found`,
`media_session_expired`, `volume_unavailable`, `recording_active`,
`recording_protected`.

## Verified against the real server

On the Pi (`pi.example.local`, Home Services 0.3.0–0.4.0, contracts 1.1–1.2,
`hls-recorder` engine), read-only: bootstrap, cameras, capabilities, live
session and its playlist, snapshot (20 KB JPEG), recordings list, playback
session, 13 archived events with MP4
media sessions (`HomeServicesLiveServerTests`). On the physical iPhone the
real Pi camera played live through Home Services and its recordings
listed (`testRealHomeServicesLiveAndRecordings`). Arming, protection and
deletion were tested only against recorded examples and stubs. No real
recording was changed, and arming stayed off because it sends motion
alerts to the owner's ntfy topic.
