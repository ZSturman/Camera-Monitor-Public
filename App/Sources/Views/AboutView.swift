import CameraCore
import SwiftUI

/// Version, privacy and acknowledgements. Camera Monitor bundles no
/// third-party code: video decoding, networking and storage use Apple's
/// frameworks (see docs/RTSP_GATE.md for why VLCKit was dropped).
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("RTSP playback", value: "Built in (H.264, H.265)")
            }
            Section("Privacy") {
                Text("Camera Monitor talks only to the cameras and servers you add. There's no account, analytics or cloud service. Passwords and tokens stay in this device's Keychain and are sent only to their own connection's address. Video from cameras on this device stays on this device.")
            }
            Section("Acknowledgements") {
                Text("Camera Monitor contains no third-party code or libraries. It uses Apple's AVFoundation, VideoToolbox, Network and SwiftUI frameworks.")
                Text("It works with, but isn't affiliated with or endorsed by, Frigate, go2rtc, ntfy, the ONVIF consortium, or the makers of any camera. Those names belong to their owners.")
            }
            Section("What Camera Monitor doesn't do") {
                Text("Watching a stream doesn't record it. Recordings, history, motion detection and alerts come from a camera, NVR or server that runs all the time; this device is never the motion detector.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
