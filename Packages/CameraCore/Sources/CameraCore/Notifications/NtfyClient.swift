import Foundation

/// Reads and tests an ntfy topic (https://ntfy.sh or a self-hosted server).
/// Camera Monitor doesn't detect motion or send alerts itself: the camera
/// server publishes to the topic, and the ntfy app delivers it to a locked
/// phone. This client sends a test message and lists recent alerts.
public struct NtfyClient: Sendable {
    public let subscription: NotificationSubscription
    let token: String?
    var configuration: URLSessionConfiguration = .ephemeral

    public init(subscription: NotificationSubscription, token: String?) {
        self.subscription = subscription
        self.token = token?.isEmpty == false ? token : nil
    }

    public struct Message: Decodable, Identifiable, Sendable, Equatable {
        public var id: String
        public var time: Date
        public var event: String
        public var title: String?
        public var message: String?
        public var tags: [String]?
        public var click: String?

        enum CodingKeys: String, CodingKey { case id, time, event, title, message, tags, click }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            time = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .time))
            event = try c.decode(String.self, forKey: .event)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            message = try c.decodeIfPresent(String.self, forKey: .message)
            tags = try c.decodeIfPresent([String].self, forKey: .tags)
            click = try c.decodeIfPresent(String.self, forKey: .click)
        }
    }

    /// Topic names act as passwords on public servers; reject guessable ones.
    public static func validate(topic: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if topic.isEmpty { return "Enter the topic your server publishes to." }
        if topic.count > 64 || topic.unicodeScalars.contains(where: { !allowed.contains($0) }) { return "Topics use letters, numbers, - and _ (up to 64)." }
        return nil
    }

    var client: HTTPClient {
        HTTPClient(base: subscription.server, headers: token.map { ["Authorization": "Bearer \($0)"] } ?? [:], configuration: configuration)
    }

    public func sendTest(from deviceName: String) async throws {
        let body = Data("Test alert from Camera Monitor on \(deviceName). If this arrived on a locked phone, delivery works.".utf8)
        let response = try await client.send("POST", subscription.topic, body: body, contentType: "text/plain",
                                             extraHeaders: ["Title": "Camera Monitor test", "Tags": "white_check_mark", "Priority": "default"])
        guard response.isSuccess else { throw Self.error(response) }
    }

    /// Cached messages from the last `since` (ntfy keeps 12 h by default).
    public func recent(since: String = "24h") async throws -> [Message] {
        let response = try await client.send("GET", "\(subscription.topic)/json", query: [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: since)], extraHeaders: ["Accept": "application/x-ndjson"])
        guard response.isSuccess else { throw Self.error(response) }
        return Self.parse(response.data)
    }

    static func parse(_ data: Data) -> [Message] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONDecoder().decode(Message.self, from: Data($0.utf8))
        }.filter { $0.event == "message" }.sorted { $0.time > $1.time }
    }

    static func error(_ response: HTTPClient.Response) -> ProviderError {
        switch response.status {
        case 401, 403: .authenticationFailed("The ntfy server refused access to this topic. Check the access token.")
        case 429: .conflict("The ntfy server is rate-limiting this device. Try again later.")
        default: HTTPClient.defaultError(response)
        }
    }
}
