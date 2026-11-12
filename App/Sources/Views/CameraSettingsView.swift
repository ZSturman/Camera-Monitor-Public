import CameraCore
import SwiftUI

/// This app's choices for a camera (name, favorite, hidden) plus whatever
/// settings its provider exposes. Read-only facts are shown as such;
/// nothing appears editable unless the provider can change it.
struct CameraSettingsView: View {
    @Environment(AppModel.self) private var model
    let camera: CameraDescriptor

    @State private var preferences = CameraPreferences()
    @State private var settings: [CameraSetting] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var applyError: String?

    var body: some View {
        Form {
            Section("In Camera Monitor") {
                TextField("Name", text: Binding(get: { preferences.customName ?? "" }, set: { preferences.customName = $0.isEmpty ? nil : $0; save() }), prompt: Text(camera.name))
                    .accessibilityIdentifier("settings.name")
                Toggle("Favorite", isOn: Binding(get: { preferences.isFavorite }, set: { preferences.isFavorite = $0; save() }))
                    .accessibilityIdentifier("settings.favorite")
                Toggle("Hide from All Cameras", isOn: Binding(get: { preferences.isHidden }, set: { preferences.isHidden = $0; save() }))
            }

            if camera.capabilities.settings.isSupported {
                if isLoading, settings.isEmpty { ProgressView() }
                if let loadError {
                    Section { Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                ForEach(sections, id: \.self) { section in
                    Section(section) {
                        ForEach(settings.filter { $0.section == section }) { setting in
                            row(setting)
                        }
                    }
                }
                if let applyError {
                    Section { Label(applyError, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
            } else if let reason = camera.capabilities.settings.reason {
                Section("Camera") { Text(reason).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            preferences = model.library.preferences(for: camera.id)
            await load()
        }
    }

    private var sections: [String] {
        var seen: [String] = []
        for setting in settings where !seen.contains(setting.section) { seen.append(setting.section) }
        return seen
    }

    @ViewBuilder
    private func row(_ setting: CameraSetting) -> some View {
        switch setting.value {
        case let .info(text):
            LabeledContent(setting.title) {
                VStack(alignment: .trailing) {
                    Text(text).textSelection(.enabled)
                    if let detail = setting.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        case let .toggle(value):
            Toggle(setting.title, isOn: Binding(get: { value }, set: { apply(setting, .toggle($0)) }))
        case let .choice(selected, options):
            VStack(alignment: .leading, spacing: 4) {
                Picker(setting.title, selection: Binding(get: { selected }, set: { apply(setting, .choice(selected: $0, options: options)) })) {
                    ForEach(options) { Text($0.title).tag($0.id) }
                }
                if let detail = setting.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        case let .number(value, range, step):
            Stepper("\(setting.title): \(value.formatted())", value: Binding(get: { value }, set: { apply(setting, .number($0, range: range, step: step)) }), in: range, step: step)
        case let .text(value):
            LabeledContent(setting.title, value: value)
        }
    }

    private func save() {
        model.library.setPreferences(preferences, for: camera.id)
        model.reloadWidgets()
    }

    private func load() async {
        guard camera.capabilities.settings.isSupported, let provider = model.library.provider(for: camera.id.connectionID) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await provider.settings(for: camera.id)
            loadError = nil
        } catch {
            loadError = describe(error)
        }
    }

    private func apply(_ setting: CameraSetting, _ value: CameraSetting.Value) {
        var changed = setting
        changed.value = value
        applyError = nil
        Task {
            do {
                let result = try await model.library.apply(changed, for: camera.id)
                if let index = settings.firstIndex(where: { $0.id == result.id }) { settings[index] = result }
            } catch {
                applyError = describe(error)
            }
        }
    }
}
