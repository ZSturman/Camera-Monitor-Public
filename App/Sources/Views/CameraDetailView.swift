import CameraCore
import SwiftUI

struct CameraDetailView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    let camera: CameraDescriptor

    @State private var armingError: String?
    @State private var isChangingArming = false

    var body: some View {
        let connection = model.library.profile(camera.id.connectionID)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if camera.capabilities.liveView != nil {
                    LivePlayerContainer(camera: camera)
                } else {
                    PlayerMessage(symbol: "video.slash", message: camera.capabilities.liveViewUnavailableReason ?? "Live view isn't available for this camera.")
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                StatusSummary(status: camera.status, isDirectStream: connection?.kind.playerReportsStatus == true)

                if camera.capabilities.arming.isSupported {
                    armingControl
                }

                if camera.capabilities.history.isSupported {
                    NavigationLink {
                        RecordingsView(camera: camera)
                    } label: {
                        Label("Recordings", systemImage: "film.stack")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("detail.recordings")
                }

                HStack {
                    NavigationLink {
                        CameraSettingsView(camera: camera)
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("detail.settings")
                    if let connection, model.library.supportsAlerts(connection.id) || connection.options.notifications != nil {
                        NavigationLink {
                            AlertsView(profile: connection)
                        } label: {
                            Label("Alerts", systemImage: "bell")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("detail.alerts")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                GroupBox("What this connection provides") {
                    CapabilityList(capabilities: camera.capabilities)
                }

                if let connection {
                    LabeledContent("Connection", value: "\(connection.name) · \(connection.kind.displayName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(model.library.displayName(camera))
        .toolbar {
            ToolbarItem {
                let preferences = model.library.preferences(for: camera.id)
                Button {
                    var updated = preferences
                    updated.isFavorite.toggle()
                    model.library.setPreferences(updated, for: camera.id)
                    model.reloadWidgets()
                } label: {
                    Label(preferences.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: preferences.isFavorite ? "star.fill" : "star")
                }
                .accessibilityIdentifier("detail.favorite")
            }
            #if os(macOS)
            ToolbarItem {
                Button {
                    openWindow(id: "camera", value: camera.id)
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
                .disabled(camera.capabilities.liveView == nil)
            }
            #endif
        }
    }

    @ViewBuilder
    private var armingControl: some View {
        let armed = camera.status?.armed ?? false
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { armed }, set: { setArmed($0) })) {
                Label(armed ? (connectionKind == .workspaceCamera ? "Out-of-house mode on" : "Armed — server records motion") : (connectionKind == .workspaceCamera ? "Out-of-house mode off" : "Disarmed"), systemImage: armed ? "shield.fill" : "shield.slash")
            }
            .disabled(isChangingArming)
            if let effect = camera.capabilities.armingEffect {
                Text("Arming: \(effect).").font(.caption).foregroundStyle(.secondary)
            }
            if let armingError {
                Text(armingError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var connectionKind: ConnectionKind? { model.library.profile(camera.id.connectionID)?.kind }

    private func setArmed(_ armed: Bool) {
        guard let provider = model.library.provider(for: camera.id.connectionID) else { return }
        isChangingArming = true
        armingError = nil
        Task {
            defer { isChangingArming = false }
            do {
                let result = try await provider.setArmed(armed, for: camera.id)
                var status = camera.status ?? CameraStatus(state: .unknown, observedAt: Date())
                status.armed = result
                status.observedAt = Date()
                model.library.updateStatus(status, for: camera.id)
            } catch {
                armingError = describe(error)
            }
        }
    }
}

struct StatusSummary: View {
    let status: CameraStatus?
    let isDirectStream: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 2) {
                if let status {
                    Text(status.state.displayName).font(.headline)
                    if let detail = status.detail { Text(detail).font(.callout) }
                    Text("Observed \(status.observedAt.relativeDescription)")
                        .font(.caption).foregroundStyle(.secondary)
                    if status.recording == true {
                        Label("Server is recording now", systemImage: "record.circle").font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Text(isDirectStream ? "Status comes from live playback" : "Status not reported yet").font(.headline)
                    if isDirectStream {
                        Text("A direct stream reports nothing while you aren't watching it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct CapabilityList: View {
    let capabilities: CameraCapabilities

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Live view", capabilities.liveView.map { _ in FeatureSupport.supported } ?? .unsupported(reason: capabilities.liveViewUnavailableReason ?? "Unavailable"), detail: capabilities.liveView?.displayName)
            row("Recording while the app is closed", capabilities.serverRecording)
            row("Recording history", capabilities.history)
            row("Playback of recordings", capabilities.playback)
            row("Export", capabilities.export)
            row("Deletion", capabilities.deletion, detail: capabilities.deletionGranularity?.displayName)
            row("Motion events", capabilities.motionEvents)
            row("Motion notifications", capabilities.notifications, detail: capabilities.notificationTransport.map { "via \($0) from the server" })
            row("Arming", capabilities.arming)
            row("Camera settings", capabilities.settings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ support: FeatureSupport, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: support.isSupported ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(support.isSupported ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, support.isSupported {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = support.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
