import CameraCore
import SwiftUI

/// Requests a stream session from the camera's provider and hands it to
/// the player for its protocol. Session-request failures (auth, server
/// down, unsupported) are shown with a retry rather than a blank view.
///
/// Live view reconnects by itself after network failures and stale
/// streams (backing off to 30 s), stops while the app is in the
/// background, and starts a fresh session on return. Sign-in and
/// unsupported-stream failures wait for the user instead of retrying.
struct LivePlayerContainer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let camera: CameraDescriptor
    /// When set, plays this session (e.g. a recording) instead of live view.
    var fixedSession: StreamSession?

    @State private var session: StreamSession?
    @State private var error: String?
    @State private var attempt = 0
    @State private var retryCount = 0
    @State private var retryTask: Task<Void, Never>?
    @State private var retryingAt: Date?
    @State private var isSuspended = false

    var body: some View {
        ZStack {
            Color.black
            if isSuspended {
                PlayerMessage(symbol: "pause.circle", message: "Paused while Camera Monitor is in the background.")
            } else if let session {
                player(for: session)
                    .id(attempt)
            } else if let error {
                VStack(spacing: 12) {
                    PlayerMessage(symbol: "video.slash", message: error)
                        .frame(maxHeight: 180)
                    if let retryingAt {
                        Text("Retrying \(retryingAt, style: .relative)…").font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    Button("Try Again") { reconnect(userInitiated: true) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            if session != nil {
                Button {
                    reconnect(userInitiated: true)
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Reconnect")
                .accessibilityIdentifier("player.reconnect")
            }
        }
        .overlay(alignment: .topLeading) {
            if DiagnosticsBadge.isEnabled { DiagnosticsBadge().padding(8) }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: TaskKey(camera: camera.id, attempt: attempt, suspended: isSuspended)) {
            guard !isSuspended else { return }
            await load()
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            // iOS suspends sockets in the background; drop the stream and
            // start a fresh session when the app returns.
            if phase == .background {
                retryTask?.cancel()
                isSuspended = true
                session = nil
            } else if phase == .active, isSuspended {
                isSuspended = false
                retryCount = 0
                attempt += 1
            }
            #endif
        }
        .onDisappear { retryTask?.cancel() }
    }

    private struct TaskKey: Hashable {
        var camera: CameraID
        var attempt: Int
        var suspended: Bool
    }

    @ViewBuilder
    private func player(for session: StreamSession) -> some View {
        switch session.streamProtocol {
        case .hls, .mp4:
            HLSPlayerView(session: session, onStateChange: { state in
                switch state {
                case .playing: playing()
                case let .failed(message): report(.unknown, detail: message); scheduleRetry()
                case .stalled: report(.staleStream); scheduleRetry()
                case .loading: break
                }
            }, onStill: storeStill)
        case .mjpeg:
            MJPEGPlayerView(session: session, onStateChange: { state in
                switch state {
                case .live: playing()
                case .stale: report(.staleStream); scheduleRetry()
                case let .failed(message): report(.unknown, detail: message); scheduleRetry()
                case .connecting: break
                }
            }, onStill: storeStill)
        case .rtsp:
            RTSPPlayerView(session: session, onStateChange: { state in
                switch state {
                case .playing: playing()
                case .stale: report(.staleStream); scheduleRetry()
                case .ended: scheduleRetry()
                case let .failed(message): report(.unknown, detail: message); scheduleRetry()
                case .opening: break
                }
            }, onStill: storeStill)
        case .localDevice:
            LocalCameraView(session: session) { state in
                switch state {
                case .running: playing()
                case let .failed(message): report(.disconnectedHardware, detail: message)
                case .starting: break
                }
            }
        }
    }

    /// Live stills become the tile and widget image; recordings don't.
    private func storeStill(_ data: Data) {
        guard fixedSession == nil else { return }
        model.storeThumbnail(data, for: camera.id)
        model.reloadWidgets()
    }

    private func playing() {
        retryCount = 0
        retryingAt = nil
        retryTask?.cancel()
        report(.online)
    }

    /// Live view only: recordings don't reconnect by themselves.
    private func scheduleRetry() {
        guard fixedSession == nil, !isSuspended else { return }
        retryTask?.cancel()
        let delay = min(30, 3 * pow(2, Double(min(retryCount, 4))))
        retryCount += 1
        retryingAt = Date().addingTimeInterval(delay)
        retryTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            reconnect(userInitiated: false)
        }
    }

    private func reconnect(userInitiated: Bool) {
        retryTask?.cancel()
        retryingAt = nil
        if userInitiated { retryCount = 0 }
        attempt += 1
    }

    /// Direct streams have no server status; the player is the observer.
    private func report(_ state: CameraState, detail: String? = nil) {
        guard fixedSession == nil, model.library.profile(camera.id.connectionID)?.kind.playerReportsStatus == true else { return }
        model.library.updateStatus(CameraStatus(state: state, detail: detail, observedAt: Date()), for: camera.id)
    }

    private func load() async {
        if let fixedSession {
            session = fixedSession
            return
        }
        session = nil
        error = nil
        guard let provider = model.library.provider(for: camera.id.connectionID) else {
            error = "This camera's connection was removed."
            return
        }
        do {
            session = try await provider.liveSession(for: camera.id)
        } catch is CancellationError {
        } catch {
            self.error = describe(error)
            let providerError = error as? ProviderError
            if let providerError, providerError.cameraState != .unknown {
                report(providerError.cameraState, detail: describe(error))
            }
            if providerError?.isTransient ?? true { scheduleRetry() }
        }
    }
}

extension ProviderError {
    /// Failures worth retrying without the user: the network or server may
    /// come back. Sign-in and unsupported-stream errors won't fix themselves.
    var isTransient: Bool {
        switch self {
        case .networkUnavailable, .timedOut, .staleStream, .recorderUnavailable, .disconnectedHardware: true
        default: false
        }
    }
}
