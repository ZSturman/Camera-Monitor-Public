import CameraCore
import SwiftUI

/// ntfy alerts for one connection. The camera server (or an automation
/// next to it) publishes to the topic; the ntfy app delivers to a locked
/// phone. Camera Monitor records where alerts go, sends a test, and shows
/// recent alerts. It never claims your server is sending them.
struct AlertsView: View {
    @Environment(AppModel.self) private var model
    let profile: ConnectionProfile

    @State private var server = "https://ntfy.sh"
    @State private var topic = ""
    @State private var token = ""
    @State private var tokenEdited = false
    @State private var status: String?
    @State private var error: String?
    @State private var messages: [NtfyClient.Message] = []
    @State private var isWorking = false

    private var subscription: NotificationSubscription? { model.library.profile(profile.id)?.options.notifications }

    var body: some View {
        Form {
            Section {
                Text("Alerts come from an always-on sender, such as your camera server or an automation beside it, posting to an ntfy topic. Install the ntfy app on your iPhone and subscribe to the same topic for alerts on a locked phone. This device doesn't detect motion.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Topic") {
                TextField("Server", text: $server)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("Topic", text: $topic, prompt: Text("e.g. home-cameras-7f3k2"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("alerts.topic")
                SecureField("Access token (optional)", text: $token)
                    .onChange(of: token) { tokenEdited = true }
                Button("Save") { save() }
                    .disabled(topic.isEmpty)
                    .accessibilityIdentifier("alerts.save")
                if subscription != nil {
                    Button("Stop Using Alerts", role: .destructive) { remove() }
                }
            }

            if let subscription {
                Section {
                    Button {
                        Task { await sendTest() }
                    } label: {
                        Label("Send Test Alert", systemImage: "bell.badge")
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("alerts.test")
                    Link(destination: subscription.topicURL) {
                        Label("Open Topic in Browser", systemImage: "safari")
                    }
                    ShareLink(item: subscription.topicURL) {
                        Label("Share Topic Link", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("In the ntfy app, tap + and enter \(subscription.topic)\(subscription.server.host == "ntfy.sh" ? "" : " with server \(subscription.server.absoluteString)"). Then lock the phone and send a test.")
                }

                Section("Recent alerts") {
                    if messages.isEmpty {
                        Text("No alerts in the last 24 hours.").foregroundStyle(.secondary)
                    }
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.title ?? message.message ?? "Alert").font(.headline)
                            if message.title != nil, let body = message.message { Text(body).font(.callout) }
                            Text(message.time.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Refresh") { Task { await loadRecent() } }
                }
            }

            if let status { Section { Label(status, systemImage: "checkmark.circle").foregroundStyle(.green) } }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Alerts")
        .task {
            if let subscription {
                server = subscription.server.absoluteString
                topic = subscription.topic
                if subscription.hasToken { token = "••••••••"; tokenEdited = false }
                await loadRecent()
            } else {
                topic = "camera-monitor-" + UUID().uuidString.prefix(8).lowercased()
            }
        }
    }

    private func save() {
        error = nil
        status = nil
        if let problem = NtfyClient.validate(topic: topic) { error = problem; return }
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.scheme == "https" || url.scheme == "http", url.host != nil else {
            error = "Enter the ntfy server's address, e.g. https://ntfy.sh."
            return
        }
        do {
            try model.library.setNotificationSubscription(NotificationSubscription(server: url, topic: topic, hasToken: subscription?.hasToken ?? false), token: tokenEdited ? token : nil, for: profile.id)
            status = "Saved."
        } catch {
            self.error = describe(error)
        }
    }

    private func remove() {
        try? model.library.setNotificationSubscription(nil, token: nil, for: profile.id)
        messages = []
        status = nil
    }

    private func sendTest() async {
        guard let client = model.library.notificationService(for: profile.id) else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try await client.sendTest(from: deviceName)
            status = "Test alert sent to \(client.subscription.topic)."
            await loadRecent()
        } catch {
            self.error = describe(error)
        }
    }

    private func loadRecent() async {
        guard let client = model.library.notificationService(for: profile.id) else { return }
        do {
            messages = try await client.recent()
            model.homePageObservedAlerts[profile.id] = messages
        } catch {
            self.error = describe(error)
        }
    }

    private var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}
