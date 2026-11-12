import Foundation

/// Checks one host for the camera services Camera Monitor supports by
/// their well-known ports and unauthenticated identity endpoints. Works
/// over Tailscale and routed networks, where multicast discovery can't.
/// Only reads public status endpoints; never sends credentials.
public struct ServiceProbe: Sendable {
    public struct Finding: Hashable, Sendable, Identifiable {
        public var id: String { kind.rawValue + address.absoluteString }
        public var kind: ConnectionKind
        public var address: URL
        public var detail: String
        /// Whether the service said it needs a sign-in.
        public var needsSignIn: Bool
    }

    var configuration: URLSessionConfiguration
    var timeout: TimeInterval

    public init(timeout: TimeInterval = 3, configuration: URLSessionConfiguration = .ephemeral) {
        self.timeout = timeout
        self.configuration = configuration
    }

    /// `host` may be a name, an IP or a URL; its scheme and port are
    /// ignored except for a full Home Services/Workspace HTTPS address.
    public func probe(_ host: String) async -> [Finding] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = URLComponents(string: trimmed.contains("://") ? trimmed : "http://" + trimmed)?.host ?? trimmed
        guard !name.isEmpty else { return [] }
        return await withTaskGroup(of: [Finding].self) { group in
            group.addTask { await self.go2rtc(name) }
            group.addTask { await self.frigate(name) }
            group.addTask { await self.homeServices(name) }
            group.addTask { await self.workspace(name) }
            group.addTask { await self.rtsp(name) }
            group.addTask { await self.onvif(name) }
            var all: [Finding] = []
            for await found in group { all += found }
            return all.sorted { $0.kind.rawValue < $1.kind.rawValue }
        }
    }

    private func get(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil) async -> HTTPClient.Response? {
        var client = HTTPClient(base: url, configuration: configuration)
        client.timeout = timeout
        return try? await client.send(method, url: url, body: body, contentType: contentType)
    }

    func go2rtc(_ host: String) async -> [Finding] {
        let base = URL(string: "http://\(host):1984")!
        guard let response = await get(base.appendingPathComponent("api")) else { return [] }
        if response.status == 401 { return [Finding(kind: .go2rtc, address: base, detail: "go2rtc (sign-in required)", needsSignIn: true)] }
        struct Info: Decodable { var version: String? }
        guard response.isSuccess, let info = try? JSONDecoder().decode(Info.self, from: response.data), info.version != nil else { return [] }
        return [Finding(kind: .go2rtc, address: base, detail: "go2rtc \(info.version ?? "")", needsSignIn: false)]
    }

    func frigate(_ host: String) async -> [Finding] {
        var found: [Finding] = []
        let open = URL(string: "http://\(host):5000")!
        if let response = await get(open.appendingPathComponent("api/version")), response.isSuccess, let text = String(data: response.data, encoding: .utf8), text.first?.isNumber == true {
            found.append(Finding(kind: .frigate, address: open, detail: "Frigate \(text.trimmingCharacters(in: .whitespacesAndNewlines)) (internal port, no sign-in)", needsSignIn: false))
        }
        let secure = URL(string: "https://\(host):8971")!
        if let response = await get(secure.appendingPathComponent("api/version")), response.isSuccess || response.status == 401 {
            found.append(Finding(kind: .frigate, address: secure, detail: "Frigate (sign-in port)", needsSignIn: response.status == 401))
        }
        return found
    }

    func homeServices(_ host: String) async -> [Finding] {
        let base = URL(string: "https://\(host):8443")!
        guard let response = await get(base.appendingPathComponent("healthz")), response.isSuccess,
              response.header(HomeServicesWire.contractHeader) != nil else { return [] }
        return [Finding(kind: .homeServices, address: base, detail: "Home Services (contract \(response.header(HomeServicesWire.contractHeader) ?? "?"))", needsSignIn: true)]
    }

    func workspace(_ host: String) async -> [Finding] {
        let base = URL(string: "https://\(host)")!
        guard let health = await get(base.appendingPathComponent("api/health")), health.isSuccess,
              let status = await get(base.appendingPathComponent("api/camera/status")),
              status.isSuccess || (status.status == 401 && String(decoding: status.data, as: UTF8.self).contains("X-Workspace-Token"))
        else { return [] }
        return [Finding(kind: .workspaceCamera, address: base, detail: "Workspace Sync camera dashboard", needsSignIn: status.status == 401)]
    }

    func rtsp(_ host: String) async -> [Finding] {
        var found: [Finding] = []
        for port in [554, 8554] {
            guard let url = URL(string: "rtsp://\(host):\(port)/") else { continue }
            do {
                let connection = try RTSPConnection(url: url, timeout: timeout)
                defer { connection.close() }
                try await connection.open()
                let response = try await connection.send(method: "OPTIONS", uri: url.absoluteString, headers: ["CSeq": "1", "User-Agent": "CameraMonitor/1.0"])
                let server = response.headerValues("Server").first.map { " (\($0))" } ?? ""
                found.append(Finding(kind: .rtsp, address: url, detail: "RTSP server on port \(port)\(server); you'll need the stream path", needsSignIn: response.status == 401))
            } catch {
                continue
            }
        }
        return found
    }

    func onvif(_ host: String) async -> [Finding] {
        let url = URL(string: "http://\(host)/onvif/device_service")!
        let client = ONVIFClient(deviceURL: url, credential: nil, configuration: configuration)
        guard (try? await client.systemTime()) != nil else { return [] }
        return [Finding(kind: .onvif, address: URL(string: "http://\(host)")!, detail: "ONVIF camera", needsSignIn: true)]
    }
}
