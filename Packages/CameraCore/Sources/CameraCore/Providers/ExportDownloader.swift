import Foundation

/// Downloads a recording export into a private temporary file. The
/// export's auth headers go only to its own origin; redirects elsewhere
/// are refused.
public enum ExportDownloader {
    public static func download(_ export: RecordingExport, configuration: URLSessionConfiguration = .ephemeral) async throws -> URL {
        var client = HTTPClient(base: export.downloadURL, headers: export.headers, configuration: configuration)
        client.timeout = 300
        let response = try await client.send("GET", url: export.downloadURL)
        guard response.isSuccess else {
            throw response.status == 401 || response.status == 403
                ? ProviderError.authenticationFailed("The server refused the download.")
                : ProviderError.invalidResponse("The export download failed (HTTP \(response.status)).")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = export.suggestedFilename.replacingOccurrences(of: "/", with: "-")
        let destination = directory.appendingPathComponent(name.isEmpty ? "recording.mp4" : name)
        try response.data.write(to: destination, options: .atomic)
        return destination
    }
}
