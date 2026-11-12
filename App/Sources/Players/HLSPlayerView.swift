import AVKit
import CameraCore
import SwiftUI

/// Native AVPlayer playback for HLS. Stream credentials are answered only
/// for the stream's own host through the asset's resource loader, so they
/// are never embedded in the URL or placed in shared credential storage.
@MainActor
@Observable
final class HLSPlayback {
    enum State: Equatable {
        case loading
        case playing
        case stalled(since: Date)
        case failed(String)
    }

    let player = AVPlayer()
    private(set) var state: State = .loading
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var authDelegate: HLSAuthDelegate?
    @ObservationIgnored private var stallTask: Task<Void, Never>?

    func start(_ session: StreamSession) {
        stop()
        state = .loading
        var options: [String: Any] = [:]
        if !session.cookies.isEmpty, let host = session.url.host {
            // AVPlayer can't add headers; cookies scoped to the session's
            // own host carry auth for servers that accept them.
            options[AVURLAssetHTTPCookiesKey] = session.cookies.compactMap { cookie in
                HTTPCookie(properties: [.name: cookie.name, .value: cookie.value, .domain: host, .path: "/", .secure: session.url.scheme == "https" ? "TRUE" : "FALSE"])
            }
        }
        let asset = AVURLAsset(url: session.url, options: options)
        let delegate = HLSAuthDelegate(origin: session.url, credential: session.credential)
        authDelegate = delegate
        asset.resourceLoader.setDelegate(delegate, queue: .global(qos: .userInitiated))
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        videoOutput = output
        observations = [
            item.observe(\.status) { [weak self] item, _ in
                Task { @MainActor in self?.itemStatusChanged(item, delegate: delegate) }
            },
            player.observe(\.timeControlStatus) { [weak self] player, _ in
                Task { @MainActor in self?.timeControlChanged(player.timeControlStatus) }
            },
        ]
        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()
    }

    /// The frame on screen now, as a small JPEG.
    func currentFrameJPEG() -> Data? {
        guard let output = videoOutput else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        return FrameThumbnail.jpeg(from: buffer)
    }

    func stop() {
        stallTask?.cancel()
        observations = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        authDelegate = nil
    }

    private func itemStatusChanged(_ item: AVPlayerItem, delegate: HLSAuthDelegate) {
        guard item.status == .failed else { return }
        if delegate.authenticationRejected {
            state = .failed(ProviderError.authenticationFailed().errorDescription!)
        } else {
            state = .failed(Self.describe(item.error))
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        if case .failed = state { return }
        switch status {
        case .playing:
            stallTask?.cancel()
            state = .playing
        case .waitingToPlayAtSpecifiedRate:
            guard case .playing = state else { return }
            let since = Date()
            stallTask?.cancel()
            stallTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.state = .stalled(since: since)
            }
        default:
            break
        }
    }

    static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "The stream couldn't be played." }
        if error.domain == NSURLErrorDomain {
            return ProviderError.networkUnavailable(error.localizedDescription).errorDescription!
        }
        if error.domain == AVFoundationErrorDomain, error.code == AVError.Code.fileFormatNotRecognized.rawValue || error.code == AVError.Code.decoderNotFound.rawValue {
            return ProviderError.unsupportedSource("The stream's format or codec isn't supported by this device.").errorDescription!
        }
        return error.localizedDescription
    }
}

final class HLSAuthDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let origin: URL
    let credential: ConnectionCredential?
    private(set) var authenticationRejected = false

    init(origin: URL, credential: ConnectionCredential?) {
        self.origin = origin
        self.credential = credential
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge) -> Bool {
        let space = authenticationChallenge.protectionSpace
        let method = space.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else { return false }
        let defaultPort = origin.scheme == "https" ? 443 : 80
        guard let credential,
              space.host.caseInsensitiveCompare(origin.host ?? "") == .orderedSame,
              space.port == (origin.port ?? defaultPort),
              authenticationChallenge.previousFailureCount == 0
        else {
            authenticationRejected = true
            authenticationChallenge.sender?.cancel(authenticationChallenge)
            return true
        }
        authenticationChallenge.sender?.use(URLCredential(user: credential.username ?? "", password: credential.password, persistence: .forSession), for: authenticationChallenge)
        return true
    }
}

struct HLSPlayerView: View {
    let session: StreamSession
    var onStateChange: (HLSPlayback.State) -> Void = { _ in }
    var onStill: (Data) -> Void = { _ in }
    @State private var playback = HLSPlayback()

    var body: some View {
        ZStack {
            VideoPlayer(player: playback.player)
            switch playback.state {
            case .loading:
                ProgressView().controlSize(.large).tint(.white)
            case let .failed(message):
                PlayerMessage(symbol: "exclamationmark.triangle", message: message)
            case let .stalled(since):
                PlayerBadge(text: "Waiting for stream since \(since.formatted(date: .omitted, time: .standard))")
            case .playing:
                EmptyView()
            }
        }
        .onAppear { playback.start(session) }
        .onDisappear { playback.stop() }
        .onChange(of: session) { _, newSession in playback.start(newSession) }
        .onChange(of: playback.state) { _, state in onStateChange(state) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.hls")
        .task(id: playback.state == .playing) {
            guard playback.state == .playing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if let still = playback.currentFrameJPEG() { onStill(still) }
                try? await Task.sleep(for: .seconds(FrameThumbnail.interval))
            }
        }
        .accessibilityValue(playback.state == .playing ? "playing" : "not playing")
    }
}

struct PlayerMessage: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }
}

struct PlayerBadge: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
    }
}
