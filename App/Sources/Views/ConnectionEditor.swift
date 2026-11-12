import CameraCore
import SwiftUI

/// Add Connection (also the first-launch screen) and Edit Connection.
/// Test Connection reports what the provider actually offers before Save.
struct ConnectionEditor: View {
    enum Mode: Equatable {
        case firstLaunch(ConnectionDraft?)
        case add(ConnectionDraft?)
        case edit(ConnectionProfile)

        var draft: ConnectionDraft? {
            switch self {
            case let .firstLaunch(draft), let .add(draft): draft
            case .edit: nil
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var kind: ConnectionKind = .rtsp
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var credentialEdited = false
    @State private var isTesting = false
    @State private var report: ConnectionTestReport?
    @State private var testError: String?
    @State private var saveError: String?
    @State private var loaded = false

    private var editingProfile: ConnectionProfile? {
        if case let .edit(profile) = mode { return profile }
        return nil
    }

    var body: some View {
        Form {
            Section("Connection type") {
                Picker("Type", selection: $kind) {
                    ForEach(ConnectionKind.offered) { kind in
                        Label(kind.displayName, systemImage: kind.symbol).tag(kind)
                    }
                }
                .disabled(editingProfile != nil)
                .accessibilityIdentifier("connection.kind")
                Text(kind.summary).font(.caption).foregroundStyle(.secondary)
            }

            Section("Details") {
                TextField("Name", text: $name, prompt: Text(kind.isDirectStream || kind == .onvif ? "Front door" : kind.displayName))
                    .accessibilityIdentifier("connection.name")
                if kind != .localDevice {
                    TextField("Address", text: $address, prompt: Text(kind.addressPlaceholder))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .accessibilityIdentifier("connection.address")
                }
            }

            if kind.credentialStyle != .none {
            Section {
                if kind.credentialStyle == .usernamePassword {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onChange(of: username) { credentialEdited = true }
                    SecureField("Password", text: $secret)
                        .onChange(of: secret) { credentialEdited = true }
                } else {
                    SecureField(kind.tokenLabel, text: $secret)
                        .onChange(of: secret) { credentialEdited = true }
                        .accessibilityIdentifier("connection.token")
                }
            } header: {
                Text("Sign-in")
            } footer: {
                Text(signInFooter)
            }
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        if isTesting { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTesting || needsAddress)
                .accessibilityIdentifier("connection.test")

                if let testError {
                    Label(testError, systemImage: "xmark.octagon").foregroundStyle(.red)
                        .accessibilityIdentifier("connection.testError")
                }
                if let report {
                    TestReportView(report: report)
                }
            }

            if let saveError {
                Section { Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }

            if case let .edit(profile) = mode {
                Section {
                    RemoveConnectionButton(profile: profile) { dismiss() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(editingProfile == nil ? "Add Connection" : "Edit Connection")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(report == nil ? "Save Without Testing" : "Save") { save() }
                    .disabled(needsAddress)
                    .accessibilityIdentifier("connection.save")
            }
        }
        .onChange(of: kind) { report = nil; testError = nil }
        .onChange(of: address) { report = nil }
        .onAppear(perform: loadExisting)
    }

    private var needsAddress: Bool {
        kind != .localDevice && address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var signInFooter: String {
        switch kind {
        case .homeServices: "Use a token issued for Camera Monitor (home-services tokens create --preset camera-monitor). It's stored in this device's Keychain."
        case .workspaceCamera: "The dashboard token configured on the Pi, if it has one. Stored in this device's Keychain and only sent to this address."
        case .frigate: "Needed for Frigate's sign-in port (8971); leave blank for its internal port (5000). Stored in this device's Keychain."
        case .onvif: "The camera's ONVIF user. Also used for its RTSP stream and snapshots. Stored in this device's Keychain."
        default: "Leave blank if the camera doesn't require a sign-in. Credentials are stored in this device's Keychain and only sent to this address."
        }
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        if let draft = mode.draft {
            kind = draft.kind
            name = draft.name
            address = draft.address
            return
        }
        guard let profile = editingProfile else { return }
        kind = profile.kind
        name = profile.name
        address = profile.kind == .localDevice ? "" : profile.address.absoluteString
        if let credential = model.library.credential(for: profile.id) {
            username = credential.username ?? ""
            secret = credential.password
        }
        credentialEdited = false
    }

    private struct Draft {
        var profile: ConnectionProfile
        var credential: ConnectionCredential?
    }

    private func makeDraft() throws -> Draft {
        let parsed = try AddressParser.parse(address, kind: kind)
        var credential: ConnectionCredential? = ConnectionCredential(
            username: kind.credentialStyle == .usernamePassword && !username.isEmpty ? username : nil,
            // Pasted tokens often carry a trailing newline or space.
            password: kind.credentialStyle == .token ? secret.trimmingCharacters(in: .whitespacesAndNewlines) : secret
        )
        if credential?.isEmpty == true { credential = parsed.embeddedCredential }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let profile = ConnectionProfile(
            id: editingProfile?.id ?? UUID(),
            name: trimmedName.isEmpty ? (kind == .localDevice ? kind.displayName : parsed.url.host ?? kind.displayName) : trimmedName,
            kind: kind,
            address: parsed.url,
            hasCredential: !(credential?.isEmpty ?? true),
            createdAt: editingProfile?.createdAt ?? Date(),
            options: editingProfile?.options ?? ConnectionOptions()
        )
        return Draft(profile: profile, credential: credential)
    }

    private func test() async {
        testError = nil
        report = nil
        do {
            let draft = try makeDraft()
            // Show the cleaned address (any embedded credentials moved out).
            if let embedded = try? AddressParser.parse(address, kind: kind).embeddedCredential, username.isEmpty, secret.isEmpty {
                username = embedded.username ?? ""
                secret = embedded.password
            }
            if kind != .localDevice { address = draft.profile.address.absoluteString }
            isTesting = true
            defer { isTesting = false }
            report = try await model.library.previewProvider(for: draft.profile, credential: draft.credential).testConnection()
        } catch {
            testError = describe(error)
        }
    }

    private func save() {
        saveError = nil
        do {
            let draft = try makeDraft()
            if editingProfile != nil {
                try model.library.update(draft.profile, credential: credentialEdited ? .replace(draft.credential) : .keep)
            } else {
                try model.library.add(draft.profile, credential: draft.credential)
            }
            let id = draft.profile.id
            Task { await model.refresh() }
            if let first = report?.cameras.first {
                model.selection = .camera(CameraID(connectionID: id, nativeID: first.id.nativeID))
            }
            dismiss()
        } catch {
            saveError = describe(error)
        }
    }
}

struct TestReportView: View {
    let report: ConnectionTestReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(report.serverName.map { "Connected to \($0)" } ?? "Connected", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.headline)
            ForEach(report.notes, id: \.self) { note in
                Text(note).font(.callout)
            }
            if report.cameras.count > 1 || report.serverName != nil {
                Text("\(report.cameras.count) camera\(report.cameras.count == 1 ? "" : "s")").font(.callout.bold())
            }
            ForEach(report.cameras) { camera in
                DisclosureGroup(camera.name) {
                    CapabilityList(capabilities: camera.capabilities)
                }
            }
        }
        .accessibilityIdentifier("connection.report")
    }
}

struct RemoveConnectionButton: View {
    @Environment(AppModel.self) private var model
    let profile: ConnectionProfile
    var onRemoved: () -> Void = {}
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        Button("Remove Connection", role: .destructive) { confirming = true }
            .confirmationDialog("Remove \(profile.name)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Remove Connection", role: .destructive) {
                    do {
                        try model.library.remove(profile.id)
                        if case let .camera(id) = model.selection, id.connectionID == profile.id { model.selection = .allCameras }
                        onRemoved()
                    } catch {
                        self.error = describe(error)
                    }
                }
            } message: {
                Text(profile.kind.isDirectStream || profile.kind == .onvif || profile.kind == .localDevice
                     ? "This removes the connection and its saved sign-in from this device. Nothing on the camera is changed."
                     : "This removes the connection and its sign-in from this device. Recordings and settings on the server are not deleted.")
            }
        if let error { Text(error).foregroundStyle(.red).font(.caption) }
    }
}
