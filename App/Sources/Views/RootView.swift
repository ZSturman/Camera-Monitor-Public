import CameraCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.library.profiles.isEmpty {
                // First launch: setup is the whole screen, no empty shell.
                NavigationStack {
                    DiscoveryView(isFirstLaunch: true)
                        .toolbar {
                            ToolbarItem {
                                NavigationLink {
                                    ConnectionsView()
                                } label: {
                                    Label("Connections", systemImage: "network")
                                }
                            }
                        }
                }
            } else {
                MainSplitView()
            }
        }
        .sheet(isPresented: $model.isShowingAddConnection) {
            NavigationStack {
                ConnectionEditor(mode: model.library.profiles.isEmpty ? .firstLaunch(model.addConnectionDraft) : .add(model.addConnectionDraft))
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 600)
            #endif
        }
        .overlay(alignment: .bottom) {
            if let notice = model.library.startupNotice ?? model.loadError {
                Text(notice)
                    .font(.callout)
                    .padding(12)
                    .background(.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .padding()
            }
        }
    }
}

struct MainSplitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationTitle("Camera Monitor")
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                #endif
        } detail: {
            NavigationStack {
                switch model.selection {
                case let .camera(id):
                    if let camera = model.library.camera(id) {
                        CameraDetailView(camera: camera)
                    } else {
                        ContentUnavailableView("Camera unavailable", systemImage: "video.slash")
                    }
                case .connections:
                    ConnectionsView()
                case .discovery:
                    DiscoveryView()
                case .about:
                    AboutView()
                case .allCameras, nil:
                    CameraGridView()
                }
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("All Cameras", systemImage: "square.grid.2x2")
                .tag(AppModel.SidebarItem.allCameras)

            let favorites = model.library.orderedCameras.filter { model.library.preferences(for: $0.id).isFavorite }
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { camera in
                        CameraRow(camera: camera)
                            .tag(AppModel.SidebarItem.camera(camera.id))
                    }
                }
            }

            ForEach(model.library.profiles) { profile in
                Section {
                    let state = model.library.states[profile.id]
                    ForEach((state?.cameras ?? []).filter { !model.library.preferences(for: $0.id).isHidden && !model.library.preferences(for: $0.id).isFavorite }) { camera in
                        CameraRow(camera: camera)
                            .tag(AppModel.SidebarItem.camera(camera.id))
                    }
                    if let error = state?.error {
                        ConnectionErrorRow(error: error, lastSuccess: state?.lastSuccess)
                    } else if state?.cameras.isEmpty == true, state?.isRefreshing == false, state?.lastSuccess != nil {
                        Text("No cameras on this server yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Label(profile.name, systemImage: profile.kind.symbol)
                        if model.library.states[profile.id]?.isRefreshing == true {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
            }

            Section {
                Label("Connections", systemImage: "network")
                    .tag(AppModel.SidebarItem.connections)
                Label("Find Cameras", systemImage: "magnifyingglass")
                    .tag(AppModel.SidebarItem.discovery)
                Label("About", systemImage: "info.circle")
                    .tag(AppModel.SidebarItem.about)
            }
        }
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem {
                Button {
                    model.beginAdd()
                } label: {
                    Label("Add Connection", systemImage: "plus")
                }
            }
            #if os(macOS)
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }
            #endif
        }
    }
}

struct CameraRow: View {
    @Environment(AppModel.self) private var model
    let camera: CameraDescriptor

    var body: some View {
        HStack {
            Label(model.library.displayName(camera), systemImage: "video")
            Spacer()
            StatusDot(status: camera.status)
        }
    }
}

struct StatusDot: View {
    let status: CameraStatus?

    var body: some View {
        let state = status?.state ?? .unknown
        Image(systemName: state.symbol)
            .foregroundStyle(state.color)
            .help(status.map { "\($0.state.displayName), observed \($0.observedAt.relativeDescription)" } ?? "Status not observed yet")
            .accessibilityLabel(state.displayName)
    }
}

struct ConnectionErrorRow: View {
    let error: ProviderError
    let lastSuccess: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(error.errorDescription ?? "Couldn't refresh.", systemImage: error.cameraState.symbol)
                .foregroundStyle(error.cameraState.color)
            Text(lastSuccess.map { "Showing cameras from \($0.relativeDescription)" } ?? "Never loaded successfully")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
