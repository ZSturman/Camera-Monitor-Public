import CameraCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension CameraState {
    var color: Color {
        switch self {
        case .online: .green
        case .unknown: .secondary
        case .staleStream, .recorderUnavailable, .storageUnavailable: .orange
        case .offline, .authenticationFailed, .disconnectedHardware: .red
        }
    }

    var symbol: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .unknown: "questionmark.circle"
        case .offline: "wifi.slash"
        case .authenticationFailed: "lock.slash"
        case .disconnectedHardware: "cable.connector.slash"
        case .staleStream: "clock.badge.exclamationmark"
        case .recorderUnavailable: "record.circle"
        case .storageUnavailable: "externaldrive.badge.exclamationmark"
        }
    }
}

extension ConnectionKind {
    var symbol: String {
        switch self {
        case .homeServices: "server.rack"
        case .hls: "play.rectangle"
        case .mjpeg: "photo.stack"
        case .rtsp: "video"
        case .onvif: "web.camera"
        case .go2rtc: "arrow.triangle.branch"
        case .frigate: "externaldrive.connected.to.line.below"
        case .workspaceCamera: "house"
        case .localDevice: "camera"
        }
    }
}

extension Date {
    var relativeDescription: String {
        formatted(.relative(presentation: .named))
    }
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

extension ConnectionKind {
    /// Kinds offered in Add Connection. iPhones can't take external
    /// cameras, so "Cameras on this device" is Mac and iPad only.
    static var offered: [ConnectionKind] {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { return allCases.filter { $0 != .localDevice } }
        #endif
        return allCases
    }
}
