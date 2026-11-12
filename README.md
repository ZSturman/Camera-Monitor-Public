# Camera Monitor

A standalone native camera client with protocol adapters, bounded streaming and local fixture tests.

**Status:** Beta. Real cameras, background behavior and permissions require device acceptance. Configure your own signing team. No private camera addresses, recordings or live credentials are supplied.

[Project portfolio](https://zacharysturman.com/projects/camera-monitor)

## Quick start

```sh
xcodegen generate
open CameraMonitor.xcodeproj
```

## Usage

Open the CameraMonitor scheme in Xcode, choose your destination, configure your signing team and run.

## How it works

SwiftUI clients use independent provider adapters for camera protocols and recording servers. Optional Home Services support does not impose a backend dependency. Fixture scripts generate local test patterns.

## Testing

```sh
swift test --package-path Packages/CameraCore
```

See [validation and next steps](docs/NEXT_STEPS.md) for the checks performed on this snapshot. Automated fixture tests do not establish physical-device compatibility.

## Configuration and privacy

This is a curated source snapshot, published November 12, 2026. Configure your own endpoints, credentials and signing identities. Private development history, local environment files, personal recordings, runtime databases, signing materials and deployment automation are excluded. Deployment and device installation are explicit operator actions.

## Further reading

- [Providers](docs/PROVIDERS.md)
- [Rtsp Gate](docs/RTSP_GATE.md)
- [Home Services Contract](docs/HOME_SERVICES_CONTRACT.md)

## License and attribution

Existing licenses and third-party notices apply to the files they cover. Publication of this snapshot does not grant a new license to original material; no additional license is granted where none is supplied.
