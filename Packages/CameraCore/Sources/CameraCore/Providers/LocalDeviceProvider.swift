import AVFoundation
import Foundation

/// Cameras attached to this device: a Mac's built-in and USB cameras
/// (including Continuity Camera), or an iPad's USB-C cameras. Live view
/// is a local capture preview; nothing is recorded or sent anywhere, and
/// other devices can't watch it without a separate publishing server.
public struct LocalDeviceProvider: CameraProvider {
    public let profile: ConnectionProfile

    public init(profile: ConnectionProfile) {
        precondition(profile.kind == .localDevice)
        self.profile = profile
    }

    public struct Device: Hashable, Sendable {
        public var id: String
        public var name: String
        public var isExternal: Bool
        public var model: String
    }

    public static func devices() -> [Device] {
        var types: [AVCaptureDevice.DeviceType] = [.external, .continuityCamera]
        #if os(macOS)
        types.append(.builtInWideAngleCamera)
        types.append(.deskViewCamera)
        #else
        types.append(.builtInWideAngleCamera)
        #endif
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return session.devices.map {
            Device(id: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType == .external, model: $0.modelID)
        }
    }

    public static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    public func testConnection() async throws -> ConnectionTestReport {
        let devices = Self.devices()
        var notes = devices.isEmpty ? ["No cameras are attached to this device."] : devices.map { "\($0.name)\($0.isExternal ? " (USB)" : "")" }
        switch Self.authorization {
        case .denied, .restricted: notes.append("Camera access is off for Camera Monitor. Turn it on in System Settings › Privacy & Security › Camera.")
        case .notDetermined: notes.append("You'll be asked for camera access the first time one is viewed.")
        default: break
        }
        return ConnectionTestReport(serverName: nil, cameras: try await cameras(), notes: notes)
    }

    public func cameras() async throws -> [CameraDescriptor] {
        Self.devices().map { device in
            var capabilities = CameraCapabilities.directStream(.localDevice)
            let reason = "A camera attached to this device is viewed here only. Nothing records it while Camera Monitor is closed."
            capabilities.history = .unsupported(reason: reason)
            capabilities.serverRecording = .unsupported(reason: reason)
            capabilities.motionEvents = .unsupported(reason: reason)
            capabilities.settings = .supported
            let status = Self.authorization == .denied || Self.authorization == .restricted
                ? CameraStatus(state: .authenticationFailed, detail: "Camera access is turned off for Camera Monitor.", observedAt: Date())
                : CameraStatus(state: .online, detail: device.isExternal ? "USB camera attached" : "Attached", observedAt: Date())
            return CameraDescriptor(id: CameraID(connectionID: profile.id, nativeID: device.id), name: device.name, capabilities: capabilities, status: status)
        }
    }

    public func liveSession(for camera: CameraID) async throws -> StreamSession {
        guard Self.devices().contains(where: { $0.id == camera.nativeID }) else {
            throw ProviderError.disconnectedHardware("This camera is no longer attached.")
        }
        switch Self.authorization {
        case .denied, .restricted:
            throw ProviderError.authenticationFailed("Camera access is turned off for Camera Monitor in Privacy & Security settings.")
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw ProviderError.authenticationFailed("Camera access was not allowed.")
            }
        default:
            break
        }
        return StreamSession(url: ConnectionKind.localDeviceAddress, streamProtocol: .localDevice, deviceID: camera.nativeID)
    }

    public func settings(for camera: CameraID) async throws -> [CameraSetting] {
        guard let device = AVCaptureDevice(uniqueID: camera.nativeID) else {
            throw ProviderError.disconnectedHardware("This camera is no longer attached.")
        }
        let format = device.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return [
            CameraSetting(id: "name", title: "Name", section: "Device", value: .info(device.localizedName)),
            CameraSetting(id: "model", title: "Model", section: "Device", value: .info(device.modelID)),
            CameraSetting(id: "connection", title: "Connection", section: "Device", value: .info(device.deviceType == .external ? "USB" : device.deviceType == .continuityCamera ? "Continuity Camera" : "Built in")),
            CameraSetting(id: "format", title: "Current format", section: "Device", value: .info("\(dimensions.width)×\(dimensions.height), up to \(Int(maxRate)) fps")),
        ]
    }
}
