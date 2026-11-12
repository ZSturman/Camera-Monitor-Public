import CameraCore
import ImageIO
import SwiftUI

/// Renders an MJPEG stream by decoding only the newest frame. If no frame
/// arrives for `staleAfter`, the stream is reported stale rather than
/// leaving the last image on screen as if it were live.
@MainActor
@Observable
final class MJPEGPlayback {
    enum State: Equatable {
        case connecting
        case live
        case stale(lastFrameAt: Date?)
        case failed(String)
    }

    private(set) var image: CGImage?
    private(set) var state: State = .connecting
    private(set) var lastFrameAt: Date?
    private(set) var framesPerSecond: Double = 0
    @ObservationIgnored private(set) var latestJPEG: Data?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var stream: MJPEGStream?
    @ObservationIgnored private var recentFrames: [Date] = []
    let staleAfter: Duration = .seconds(10)

    func start(_ session: StreamSession) {
        stop()
        state = .connecting
        let stream = MJPEGStream(url: session.url, credential: session.credential, headers: session.headers)
        self.stream = stream
        task = Task { [weak self] in
            do {
                for try await frame in stream.frames() {
                    guard let decoded = await Self.decode(frame) else { continue }
                    self?.latestJPEG = frame
                    self?.show(decoded)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.checkStale()
            }
        }
    }

    func stop() {
        task?.cancel()
        watchdog?.cancel()
        stream?.cancel()
        stream = nil
    }

    private func show(_ image: CGImage) {
        self.image = image
        let now = Date()
        lastFrameAt = now
        recentFrames.append(now)
        recentFrames.removeAll { now.timeIntervalSince($0) > 3 }
        framesPerSecond = Double(recentFrames.count) / 3
        state = .live
    }

    private func fail(_ error: Error) {
        if case ProviderError.staleStream = error {
            state = .stale(lastFrameAt: lastFrameAt)
        } else {
            state = .failed(describe(error))
        }
    }

    private func checkStale() {
        guard case .live = state, let lastFrameAt else { return }
        if Date().timeIntervalSince(lastFrameAt) > Double(staleAfter.components.seconds) {
            state = .stale(lastFrameAt: lastFrameAt)
        }
    }

    nonisolated private static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

struct MJPEGPlayerView: View {
    let session: StreamSession
    var onStateChange: (MJPEGPlayback.State) -> Void = { _ in }
    var onStill: (Data) -> Void = { _ in }
    @State private var playback = MJPEGPlayback()

    var body: some View {
        ZStack {
            Color.black
            if let image = playback.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(playback.state == .live ? 1 : 0.4)
            }
            switch playback.state {
            case .connecting:
                ProgressView().controlSize(.large).tint(.white)
            case let .failed(message):
                PlayerMessage(symbol: "exclamationmark.triangle", message: message)
            case let .stale(lastFrameAt):
                PlayerMessage(symbol: "clock.badge.exclamationmark", message: ProviderError.staleStream(lastFrameAt: lastFrameAt).errorDescription!)
            case .live:
                PlayerBadge(text: String(format: "MJPEG · %.0f fps", playback.framesPerSecond))
            }
        }
        .onAppear { playback.start(session) }
        .onDisappear { playback.stop() }
        .onChange(of: session) { _, newSession in playback.start(newSession) }
        .onChange(of: playback.state) { _, state in onStateChange(state) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.mjpeg")
        .task(id: playback.state == .live) {
            guard playback.state == .live else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if let still = playback.latestJPEG { onStill(still) }
                try? await Task.sleep(for: .seconds(FrameThumbnail.interval))
            }
        }
        .accessibilityValue(playback.state == .live ? "playing" : "not playing")
    }
}
