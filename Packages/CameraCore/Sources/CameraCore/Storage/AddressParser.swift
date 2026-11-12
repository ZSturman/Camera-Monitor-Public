import Foundation

public enum AddressParser {
    public struct Parsed: Equatable, Sendable {
        /// The address with any embedded user:password removed.
        public var url: URL
        /// Credentials that were embedded in the pasted address, if any.
        public var embeddedCredential: ConnectionCredential?
    }

    /// Validates a typed or pasted address for a connection kind. Embedded
    /// credentials are lifted out so they are stored in the Keychain rather
    /// than in the profile file or any URL handed to a player.
    public static func parse(_ text: String, kind: ConnectionKind) throws -> Parsed {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .localDevice { return Parsed(url: ConnectionKind.localDeviceAddress, embeddedCredential: nil) }
        guard !trimmed.isEmpty else { throw ProviderError.invalidAddress("Enter an address.") }
        if !trimmed.contains("://") {
            trimmed = kind.defaultScheme + "://" + trimmed
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else {
            throw ProviderError.invalidAddress("That doesn't look like a valid address.")
        }
        guard kind.allowedSchemes.contains(scheme) else {
            let allowed = kind.allowedSchemes.sorted().map { "\($0)://" }.joined(separator: " or ")
            throw ProviderError.invalidAddress("\(kind.displayName) addresses start with \(allowed).")
        }
        if [.homeServices, .workspaceCamera].contains(kind), scheme == "http", !isLoopback(host) {
            throw ProviderError.invalidAddress("\(kind.displayName) requires an https:// address so its token is never sent in the clear. Plain http is only accepted for a server on this device during development.")
        }
        components.scheme = scheme

        var embedded: ConnectionCredential?
        if let user = components.user, !user.isEmpty {
            embedded = ConnectionCredential(username: user.removingPercentEncoding ?? user, password: components.password?.removingPercentEncoding ?? "")
        }
        components.user = nil
        components.password = nil

        guard let url = components.url else { throw ProviderError.invalidAddress("That doesn't look like a valid address.") }
        return Parsed(url: url, embeddedCredential: embedded)
    }

    public static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    /// A display form that never includes credentials.
    public static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<address>" }
        components.user = nil
        components.password = nil
        components.query = components.query == nil ? nil : "…"
        return components.string ?? "<address>"
    }
}
