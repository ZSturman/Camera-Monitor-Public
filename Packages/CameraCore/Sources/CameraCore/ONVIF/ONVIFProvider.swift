import Foundation

/// An ONVIF (Profile S) network camera: ONVIF describes the device and its
/// media profiles and hands out RTSP stream and snapshot addresses; video
/// plays through the native RTSP player. ONVIF is discovery and control,
/// not recording, so there is no history unless the camera is also added
/// to an NVR.
public struct ONVIFProvider: CameraProvider {
    public let profile: ConnectionProfile
    let credential: ConnectionCredential?
    let configuration: URLSessionConfiguration

    static let nativeID = "device"
    static let clockOffsets = ClockOffsets()

    public init(profile: ConnectionProfile, credential: ConnectionCredential?, urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        precondition(profile.kind == .onvif)
        self.profile = profile
        self.credential = credential?.isEmpty == false ? credential : nil
        configuration = urlSessionConfiguration
    }

    /// `host` or `http://host` becomes the standard device service path.
    static func deviceURL(for address: URL) -> URL {
        guard address.path.isEmpty || address.path == "/" else { return address }
        return address.appendingPathComponent("onvif/device_service")
    }

    func client() async -> ONVIFClient {
        var client = ONVIFClient(deviceURL: Self.deviceURL(for: profile.address), credential: credential, configuration: configuration)
        client.clockOffset = await Self.clockOffsets.offset(for: profile.id) ?? 0
        return client
    }

    /// Reads the camera's clock once so WS-Security timestamps match it.
    func synchronizedClient() async -> ONVIFClient {
        var client = await client()
        if await Self.clockOffsets.offset(for: profile.id) == nil, let cameraTime = try? await client.systemTime() {
            let offset = cameraTime.timeIntervalSinceNow
            await Self.clockOffsets.set(abs(offset) > 5 ? offset : 0, for: profile.id)
            client.clockOffset = abs(offset) > 5 ? offset : 0
        }
        return client
    }

    var cameraID: CameraID { CameraID(connectionID: profile.id, nativeID: Self.nativeID) }

    // MARK: CameraProvider

    public func testConnection() async throws -> ConnectionTestReport {
        let client = await synchronizedClient()
        let info = try await client.deviceInformation()
        let media = try await client.mediaURL()
        let profiles = try await client.profiles(media: media)
        guard !profiles.isEmpty else { throw ProviderError.unsupportedSource("The camera reported no media profiles.") }
        var notes = [[info.manufacturer, info.model].compactMap { $0 }.joined(separator: " ") + (info.firmware.map { ", firmware \($0)" } ?? "")]
        notes.append("\(profiles.count) stream profile\(profiles.count == 1 ? "" : "s"): " + profiles.map(\.summary).joined(separator: "; "))
        let chosen = chooseProfile(profiles)
        let stream = try await client.streamURI(media: media, profile: chosen.token)
        let probe = try await RTSPProbe().probe(stream, credential: credential)
        notes.append("Live view uses \"\(chosen.name)\": \(probe.description.summary).")
        if !chosen.isPlayable { notes.append("This profile isn't H.264/H.265; choose another in camera settings.") }
        return ConnectionTestReport(serverName: info.model, cameras: [descriptor(status: CameraStatus(state: .online, observedAt: Date()))], notes: notes)
    }

    public func cameras() async throws -> [CameraDescriptor] {
        [descriptor(status: nil)]
    }

    func descriptor(status: CameraStatus?) -> CameraDescriptor {
        var capabilities = CameraCapabilities.directStream(.rtsp)
        capabilities.snapshot = .supported
        capabilities.settings = .supported
        let reason = "ONVIF finds and describes the camera's streams; recordings and motion alerts need an NVR such as Frigate."
        capabilities.history = .unsupported(reason: reason)
        capabilities.motionEvents = .unsupported(reason: reason)
        return CameraDescriptor(id: cameraID, name: profile.name, capabilities: capabilities, status: status)
    }

    public func liveSession(for camera: CameraID) async throws -> StreamSession {
        let client = await synchronizedClient()
        let media = try await client.mediaURL()
        let chosen = chooseProfile(try await client.profiles(media: media))
        return StreamSession(url: try await client.streamURI(media: media, profile: chosen.token), streamProtocol: .rtsp, credential: credential)
    }

    public func snapshot(for camera: CameraID) async throws -> Data {
        let client = await synchronizedClient()
        let media = try await client.mediaURL()
        let chosen = chooseProfile(try await client.profiles(media: media))
        guard let url = try await client.snapshotURI(media: media, profile: chosen.token) else {
            throw ProviderError.unsupported("This camera doesn't offer ONVIF snapshots.")
        }
        let http = HTTPClient(base: url, credential: credential, configuration: configuration)
        let response = try await http.send("GET", url: url, extraHeaders: ["Accept": "image/jpeg"])
        guard response.isSuccess else { throw HTTPClient.defaultError(response) }
        return response.data
    }

    public func settings(for camera: CameraID) async throws -> [CameraSetting] {
        let client = await synchronizedClient()
        let device = try await client.deviceInformation()
        let media = try await client.mediaURL()
        let profiles = try await client.profiles(media: media)
        let chosen = chooseProfile(profiles)
        var settings: [CameraSetting] = []
        func info(_ id: String, _ title: String, _ value: String?) {
            if let value, !value.isEmpty { settings.append(CameraSetting(id: id, title: title, section: "Device", value: .info(value))) }
        }
        info("manufacturer", "Manufacturer", device.manufacturer)
        info("model", "Model", device.model)
        info("firmware", "Firmware", device.firmware)
        info("serial", "Serial number", device.serial)
        settings.append(CameraSetting(
            id: CameraSetting.onvifProfileID, title: "Stream profile", section: "Live view",
            value: .choice(selected: chosen.token, options: profiles.map { .init(id: $0.token, title: $0.summary) }),
            detail: "Lower-resolution profiles use less bandwidth on cellular or Tailscale."
        ))
        return settings
    }

    /// The saved choice, else the first H.264/H.265 profile (main stream),
    /// or the last one when substreams are preferred.
    func chooseProfile(_ profiles: [ONVIFClient.Profile]) -> ONVIFClient.Profile {
        if let saved = profile.options.onvifProfiles?[Self.nativeID], let match = profiles.first(where: { $0.token == saved }) { return match }
        let playable = profiles.filter(\.isPlayable)
        let candidates = playable.isEmpty ? profiles : playable
        return (profile.options.preferSubstream == true ? candidates.last : candidates.first) ?? profiles[0]
    }

    actor ClockOffsets {
        private var offsets: [UUID: TimeInterval] = [:]
        func offset(for id: UUID) -> TimeInterval? { offsets[id] }
        func set(_ offset: TimeInterval, for id: UUID) { offsets[id] = offset }
    }
}
