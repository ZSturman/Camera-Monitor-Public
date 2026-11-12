@preconcurrency import AVFoundation
import CameraCore
import SwiftUI

/// Live preview of a camera attached to this device (Mac built-in/USB,
/// Continuity Camera, iPad USB-C). Preview only: nothing is recorded.
@MainActor
@Observable
final class LocalCameraPlayback {
    enum State: Equatable {
        case starting
        case running
        case failed(String)
    }

    private(set) var state: State = .starting
    let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "CameraMonitor.LocalCamera")
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// "Running" means frames are arriving, not just that the session started.
    @ObservationIgnored private let frames = FrameWatcher()
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    func start(deviceID: String?) {
        state = .starting
        guard let deviceID, let device = AVCaptureDevice(uniqueID: deviceID) else {
            state = .failed(ProviderError.disconnectedHardware("This camera is no longer attached.").errorDescription!)
            return
        }
        let session = self.session
        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                MainActor.assumeIsolated { self?.state = .failed(error?.localizedDescription ?? "The camera stopped.") }
            },
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.state = .failed("The camera was disconnected.") }
            },
        ]
        frames.reset()
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                if self.frames.count > 0 {
                    if self.state == .starting { self.state = .running }
                    return
                }
            }
            guard let self, self.state == .starting else { return }
            self.state = .failed("The camera isn't sending video. On a MacBook the lid may be closed, or another app may be using the camera.")
        }
        queue.async { [weak self] in
            do {
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw ProviderError.unsupportedSource("The camera can't be opened; another app may be using it.") }
                session.addInput(input)
                if session.outputs.isEmpty {
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self?.frames, queue: DispatchQueue(label: "CameraMonitor.LocalCamera.frames"))
                    if session.canAddOutput(output) { session.addOutput(output) }
                }
                session.commitConfiguration()
                session.startRunning()
                let running = session.isRunning
                Task { @MainActor in
                    if !running { self?.state = .failed("The camera didn't start; another app may be using it.") }
                }
            } catch {
                session.commitConfiguration()
                Task { @MainActor in self?.state = .failed(describe(error)) }
            }
        }
    }

    func stop() {
        watchdog?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let session = self.session
        queue.async { session.stopRunning() }
    }
}

final class FrameWatcher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0

    var count: Int { lock.withLock { frames } }
    func reset() { lock.withLock { frames = 0 } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.withLock { frames += 1 }
    }
}

struct LocalCameraView: View {
    let session: StreamSession
    var onStateChange: (LocalCameraPlayback.State) -> Void = { _ in }
    @State private var playback = LocalCameraPlayback()

    var body: some View {
        ZStack {
            Color.black
            PreviewLayerView(session: playback.session)
            switch playback.state {
            case .starting: ProgressView().controlSize(.large).tint(.white)
            case let .failed(message): PlayerMessage(symbol: "exclamationmark.triangle", message: message)
            case .running: PlayerBadge(text: "On this device · not recorded")
            }
        }
        .onAppear { playback.start(deviceID: session.deviceID) }
        .onDisappear { playback.stop() }
        .onChange(of: playback.state) { _, state in onStateChange(state) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.local")
        .accessibilityValue(playback.state == .running ? "playing" : "not playing")
    }
}

#if os(iOS)
private struct PreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#else
private struct PreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
