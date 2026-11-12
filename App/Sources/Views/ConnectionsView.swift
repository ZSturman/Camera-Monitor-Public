import CameraCore
import SwiftUI

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ConnectionProfile?

    var body: some View {
        List {
            Section("Raspberry Pi") {
                NavigationLink("Pi Connection · Scan or Paste") { CameraPiConnection() }
            }
            HomePageExportSettings()
            ForEach(model.library.profiles) { profile in
                let state = model.library.states[profile.id]
                Button {
                    editing = profile
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: profile.kind.symbol).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(.headline)
                            Text("\(profile.kind.displayName) · \(AddressParser.redacted(profile.address))")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let error = state?.error {
                                ConnectionErrorRow(error: error, lastSuccess: state?.lastSuccess)
                            } else if let lastSuccess = state?.lastSuccess {
                                Text("\(state?.cameras.count ?? 0) camera\(state?.cameras.count == 1 ? "" : "s") · updated \(lastSuccess.relativeDescription)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !model.library.hiddenCameras.isEmpty {
                Section("Hidden cameras") {
                    ForEach(model.library.hiddenCameras) { camera in
                        HStack {
                            Text(model.library.displayName(camera))
                            Spacer()
                            Button("Show") {
                                var preferences = model.library.preferences(for: camera.id)
                                preferences.isHidden = false
                                model.library.setPreferences(preferences, for: camera.id)
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    model.beginAdd()
                } label: {
                    Label("Add Connection", systemImage: "plus")
                }
            } footer: {
                Text("Each connection is independent. If one server is unavailable, cameras on other connections keep working.")
            }
        }
        .navigationTitle("Connections")
        .refreshable { await model.refresh() }
        .sheet(item: $editing) { profile in
            NavigationStack {
                ConnectionEditor(mode: .edit(profile))
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 600)
            #endif
        }
    }
}
