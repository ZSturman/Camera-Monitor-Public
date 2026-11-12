import Foundation

public struct ProviderFactory: Sendable {
    public var urlSessionConfiguration: @Sendable () -> URLSessionConfiguration

    public init(urlSessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.urlSessionConfiguration = urlSessionConfiguration
    }

    /// Each provider receives only its own profile's credential.
    public func provider(for profile: ConnectionProfile, credential: ConnectionCredential?) -> any CameraProvider {
        let configuration = urlSessionConfiguration()
        switch profile.kind {
        case .homeServices:
            return HomeServicesProvider(profile: profile, credential: credential, urlSessionConfiguration: configuration)
        case .hls, .mjpeg, .rtsp:
            return DirectStreamProvider(profile: profile, credential: credential, urlSessionConfiguration: configuration)
        case .onvif:
            return ONVIFProvider(profile: profile, credential: credential, urlSessionConfiguration: configuration)
        case .go2rtc:
            return Go2RTCProvider(profile: profile, credential: credential, urlSessionConfiguration: configuration)
        case .frigate:
            return FrigateProvider(profile: profile, credential: credential, urlSessionConfiguration: configuration)
        case .workspaceCamera:
            return WorkspaceCameraProvider(profile: profile, credential: credential, urlSessionConfiguration: configuration)
        case .localDevice:
            return LocalDeviceProvider(profile: profile)
        }
    }
}
