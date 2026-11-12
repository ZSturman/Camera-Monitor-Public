import Foundation

/// Persists nonsecret connection profiles as a versioned JSON file.
/// An unreadable file is preserved alongside, never silently overwritten.
public final class ProfileStore: @unchecked Sendable {
    public struct LoadResult: Sendable {
        public var profiles: [ConnectionProfile]
        /// Set when an existing file could not be read and was set aside.
        public var preservedCorruptFile: URL?
    }

    private struct Envelope: Codable {
        var version: Int
        var profiles: [ConnectionProfile]
    }

    public static let currentVersion = 1

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/CameraMonitor/connections.json`
    /// (inside the sandbox container on macOS and iOS).
    public static func defaultFileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("CameraMonitor", isDirectory: true).appendingPathComponent("connections.json")
    }

    /// The shared App Group location (so widgets can read the status
    /// summary). The first time it's used, existing files are copied from
    /// the app's own Application Support folder; the originals are kept.
    public static func sharedFileURL(appGroup: String) -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let directory = container.appendingPathComponent("Library/Application Support/CameraMonitor", isDirectory: true)
        let target = directory.appendingPathComponent("connections.json")
        if !FileManager.default.fileExists(atPath: target.path), let legacy = try? defaultFileURL().deletingLastPathComponent(),
           FileManager.default.fileExists(atPath: legacy.appendingPathComponent("connections.json").path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: legacy.path)) ?? [] where name.hasSuffix(".json") {
                try? FileManager.default.copyItem(at: legacy.appendingPathComponent(name), to: directory.appendingPathComponent(name))
            }
        }
        return target
    }

    public func load() throws -> LoadResult {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LoadResult(profiles: [], preservedCorruptFile: nil)
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let envelope = try Self.decoder.decode(Envelope.self, from: data)
            guard envelope.version <= Self.currentVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return LoadResult(profiles: envelope.profiles, preservedCorruptFile: nil)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let preserved = fileURL.deletingLastPathComponent().appendingPathComponent("connections.unreadable-\(stamp).json")
            try FileManager.default.copyItem(at: fileURL, to: preserved)
            return LoadResult(profiles: [], preservedCorruptFile: preserved)
        }
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Envelope(version: Self.currentVersion, profiles: profiles))
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

#if os(macOS)
extension Data.WritingOptions {
    // File protection classes are an iOS concept; keep call sites uniform.
    static var completeFileProtectionUntilFirstUserAuthentication: Data.WritingOptions { [] }
}
#endif
