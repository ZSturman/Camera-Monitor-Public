import AVFoundation
import CameraCore
import SwiftUI

/// Native RTSP live view: CameraCore's RTSP client and RTP depacketizer
/// feed H.264/H.265 samples to AVSampleBufferDisplayLayer, which decodes
/// them in hardware. No third-party media library (see docs/RTSP_GATE.md).
enum RTSPPlaybackEngine {
    static let isAvailable = true
    static let name = "Native"
}

enum RTSPPlaybackState: Equatable {
    case opening
    case playing
    case stale(lastFrameAt: Date?)
    case ended
    case failed(String)
}

@MainActor
@Observable
final class RTSPPlayback {
    private(set) var state: RTSPPlaybackState = .opening
    private(set) var codec: VideoCodec?
    private(set) var dimensions: CMVideoDimensions?
    private(set) var framesPerSecond: Double = 0
    let displayLayer = AVSampleBufferDisplayLayer()
    static let staleAfter: TimeInterval = 10

    @ObservationIgnored private var session: RTSPPlayerSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private let frameClock = FrameClock()
    /// Called with a still from a keyframe, at most once per interval.
    @ObservationIgnored var onStill: (Data) -> Void = { _ in }

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func start(_ stream: StreamSession) {
        stop()
        state = .opening
        let session = RTSPPlayerSession(url: stream.url, credential: stream.credential)
        self.session = session
        let renderer = displayLayer.sampleBufferRenderer
        let clock = frameClock
        clock.reset()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var factory: VideoSampleFactory?
            var announcedFirstFrame = false
            var lastStill = Date.distantPast
            do {
                for try await event in session.events() {
                    switch event {
                    case let .started(codec, parameterSets, _):
                        factory = VideoSampleFactory(codec: codec, parameterSets: parameterSets)
                        await self?.started(codec)
                    case let .accessUnit(unit):
                        guard factory != nil else { continue }
                        if renderer.status == .failed {
                            // Decoder error: flush and wait for the next keyframe.
                            renderer.flush()
                            factory?.resynchronize()
                        }
                        guard let sample = try factory?.sampleBuffer(for: unit) else { continue }
                        renderer.enqueue(sample)
                        clock.tick()
                        if unit.isKeyframe, Date().timeIntervalSince(lastStill) > FrameThumbnail.interval, let still = FrameThumbnail.jpeg(fromKeyframe: sample) {
                            lastStill = Date()
                            await self?.deliverStill(still)
                        }
                        if !announcedFirstFrame {
                            announcedFirstFrame = true
                            await self?.firstFrame(factory?.dimensions)
                        }
                    }
                }
                await self?.finished(nil)
            } catch is CancellationError {
            } catch {
                await self?.finished(error)
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.checkFrames()
            }
        }
    }

    func stop() {
        task?.cancel()
        watchdog?.cancel()
        session?.stop()
        session = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    private func deliverStill(_ data: Data) {
        onStill(data)
    }

    private func started(_ codec: VideoCodec) {
        self.codec = codec
    }

    private func firstFrame(_ dimensions: CMVideoDimensions?) {
        self.dimensions = dimensions
        state = .playing
    }

    private func finished(_ error: Error?) {
        if let error {
            state = .failed(describe(error))
        } else if case .playing = state {
            state = .ended
        } else {
            state = .failed("The camera closed the stream before any video arrived. Check the credentials and stream path.")
        }
    }

    private func checkFrames() {
        let (last, fps) = frameClock.sample()
        framesPerSecond = fps
        switch state {
        case .playing:
            if let last, Date().timeIntervalSince(last) > Self.staleAfter { state = .stale(lastFrameAt: last) }
        case .stale:
            if let last, Date().timeIntervalSince(last) <= Self.staleAfter { state = .playing }
        default:
            break
        }
    }
}

/// Frame timing shared between the decode task and the main actor.
private final class FrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date?
    private var recent: [Date] = []

    func reset() {
        lock.withLock { last = nil; recent = [] }
    }

    func tick() {
        let now = Date()
        lock.withLock {
            last = now
            recent.append(now)
            if recent.count > 120 { recent.removeFirst(recent.count - 120) }
        }
    }

    func sample() -> (Date?, Double) {
        lock.withLock {
            let now = Date()
            recent.removeAll { now.timeIntervalSince($0) > 3 }
            return (last, Double(recent.count) / 3)
        }
    }
}

struct RTSPPlayerView: View {
    let session: StreamSession
    var onStateChange: (RTSPPlaybackState) -> Void = { _ in }
    var onStill: (Data) -> Void = { _ in }
    @State private var playback = RTSPPlayback()

    var body: some View {
        ZStack {
            Color.black
            SampleBufferView(layer: playback.displayLayer)
                .opacity(playback.state == .playing ? 1 : 0.4)
            switch playback.state {
            case .opening:
                ProgressView().controlSize(.large).tint(.white)
            case let .stale(lastFrameAt):
                PlayerMessage(symbol: "clock.badge.exclamationmark", message: ProviderError.staleStream(lastFrameAt: lastFrameAt).errorDescription!)
            case .ended:
                PlayerMessage(symbol: "stop.circle", message: "The camera ended the stream.")
            case let .failed(message):
                PlayerMessage(symbol: "exclamationmark.triangle", message: message)
            case .playing:
                PlayerBadge(text: badge)
            }
        }
        .onAppear {
            playback.onStill = onStill
            playback.start(session)
        }
        .onDisappear { playback.stop() }
        .onChange(of: session) { _, newSession in playback.start(newSession) }
        .onChange(of: playback.state) { _, state in onStateChange(state) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.rtsp")
        .accessibilityValue(playback.state == .playing ? "playing" : "not playing")
    }

    private var badge: String {
        var parts = ["RTSP"]
        if let codec = playback.codec { parts.append(codec.displayName) }
        if let size = playback.dimensions { parts.append("\(size.width)×\(size.height)") }
        parts.append(String(format: "%.0f fps", playback.framesPerSecond))
        return parts.joined(separator: " · ")
    }
}

#if os(iOS)
private struct SampleBufferView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerHostView {
        LayerHostView(hosted: layer)
    }

    func updateUIView(_ view: LayerHostView, context: Context) {}

    final class LayerHostView: UIView {
        let hosted: CALayer

        init(hosted: CALayer) {
            self.hosted = hosted
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(hosted)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}
#else
private struct SampleBufferView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> LayerHostView {
        LayerHostView(hosted: layer)
    }

    func updateNSView(_ view: LayerHostView, context: Context) {}

    final class LayerHostView: NSView {
        let hosted: CALayer

        init(hosted: CALayer) {
            self.hosted = hosted
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = .black
            layer?.addSublayer(hosted)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif
