import CameraCore
import SwiftUI

/// Helps find cameras: ones attached to this device, ONVIF cameras on the
/// local network, and services on a host the user names (works over
/// Tailscale). Every result opens Add Connection prefilled; nothing is
/// saved until the user tests and saves it. Manual entry is always there.
struct DiscoveryView: View {
    @Environment(AppModel.self) private var model
    var isFirstLaunch = false

    @State private var localDevices: [LocalDeviceProvider.Device] = []
    @State private var onvifDevices: [ONVIFDiscovery.Device] = []
    @State private var onvifState: ScanState = .idle
    @State private var host = ""
    @State private var findings: [ServiceProbe.Finding] = []
    @State private var probeState: ScanState = .idle

    enum ScanState: Equatable {
        case idle, scanning, done, failed(String)
    }

    var body: some View {
        Form {
            if isFirstLaunch {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add your first camera").font(.title2.bold())
                        Text("Find cameras below or add one by address. Direct cameras need no account or server; camera servers such as Frigate or Home Services are optional.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Button {
                    model.beginAdd()
                } label: {
                    Label("Add by Address…", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("discovery.manual")
            } footer: {
                Text("RTSP, HLS and MJPEG URLs, ONVIF cameras, go2rtc, Frigate, Home Services and the Workspace Sync camera dashboard.")
            }

            if ConnectionKind.offered.contains(.localDevice) {
                Section("On this device") {
                    if localDevices.isEmpty {
                        Text("No cameras attached.").foregroundStyle(.secondary)
                    } else {
                        ForEach(localDevices, id: \.id) { device in
                            Label("\(device.name)\(device.isExternal ? " · USB" : "")", systemImage: device.isExternal ? "cable.connector" : "camera")
                        }
                        if !model.library.profiles.contains(where: { $0.kind == .localDevice }) {
                            Button("Add Cameras on This Device") {
                                model.beginAdd(ConnectionDraft(kind: .localDevice, name: ConnectionKind.localDevice.displayName))
                            }
                        } else {
                            Text("Already added.").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                HStack {
                    TextField("Host name or IP address", text: $host, prompt: Text("192.168.1.10 or host.example.net"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { Task { await probe() } }
                        .accessibilityIdentifier("discovery.host")
                    Button("Check") { Task { await probe() } }
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || probeState == .scanning)
                        .accessibilityIdentifier("discovery.check")
                }
                if probeState == .scanning { ProgressView("Checking common camera ports…") }
                if probeState == .done, findings.isEmpty {
                    Text("Nothing Camera Monitor recognizes answered on that host's usual ports. You can still add it by address.").foregroundStyle(.secondary)
                }
                ForEach(findings) { finding in
                    Button {
                        model.beginAdd(ConnectionDraft(kind: finding.kind, address: finding.address.absoluteString))
                    } label: {
                        HStack {
                            Label(finding.detail, systemImage: finding.kind.symbol)
                            Spacer()
                            if finding.needsSignIn { Image(systemName: "lock").foregroundStyle(.secondary) }
                        }
                    }
                }
            } header: {
                Text("Check a host")
            } footer: {
                Text("Looks for go2rtc, Frigate, Home Services, the Workspace Sync dashboard, RTSP and ONVIF on their usual ports. Only public status endpoints are read; no passwords are sent.")
            }

            Section {
                Button {
                    Task { await scanONVIF() }
                } label: {
                    HStack {
                        Label("Search for ONVIF Cameras", systemImage: "dot.radiowaves.left.and.right")
                        if onvifState == .scanning { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(onvifState == .scanning)
                if case let .failed(message) = onvifState {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if onvifState == .done, onvifDevices.isEmpty {
                    Text("No ONVIF cameras answered on this network.").foregroundStyle(.secondary)
                }
                ForEach(onvifDevices) { device in
                    Button {
                        let address = device.serviceURLs.first { $0.host?.contains(":") == false }?.absoluteString ?? device.serviceURLs[0].absoluteString
                        model.beginAdd(ConnectionDraft(kind: .onvif, name: device.name ?? "", address: address))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(device.name ?? device.host ?? "ONVIF camera")
                            Text([device.hardware, device.host].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Local network")
            } footer: {
                Text("Uses ONVIF WS-Discovery on this Wi-Fi or Ethernet network. It can't see cameras over Tailscale; use Check a Host for those.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isFirstLaunch ? "Welcome" : "Find Cameras")
        .task { localDevices = LocalDeviceProvider.devices() }
    }

    private func probe() async {
        probeState = .scanning
        findings = await ServiceProbe().probe(host)
        probeState = .done
    }

    private func scanONVIF() async {
        onvifState = .scanning
        do {
            onvifDevices = try await ONVIFDiscovery.discover()
            onvifState = .done
        } catch {
            onvifState = .failed(describe(error))
        }
    }
}
