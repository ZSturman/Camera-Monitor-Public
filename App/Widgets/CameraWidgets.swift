import CameraCore
import ImageIO
import SwiftUI
import WidgetKit

/// Widgets show what the app last saw: each camera's status and when it
/// was observed, and the last still image. They read a summary the app
/// writes to the shared App Group; they never contact cameras or hold
/// credentials, so everything shown is dated.
@main
struct CameraMonitorWidgets: WidgetBundle {
    var body: some Widget {
        CameraStatusWidget()
        #if os(iOS)
        CameraSummaryAccessoryWidget()
        #endif
    }
}

enum SharedStore {
    static let appGroup = "group.com.zacharysturman.cameramonitor"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Library/Application Support/CameraMonitor", isDirectory: true)
    }

    static func summary() -> WidgetSummary? {
        directory.flatMap(WidgetSummary.load(from:))
    }

    static func thumbnail(for camera: WidgetSummary.Camera, maxPixels: Int) -> (CGImage, Date)? {
        guard let url = directory?.appendingPathComponent(WidgetSummary.thumbnailDirectory).appendingPathComponent(camera.thumbnailName),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary),
              let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        else { return nil }
        return (image, date)
    }
}

struct SummaryEntry: TimelineEntry {
    var date: Date
    var summary: WidgetSummary?
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: Date(), summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(SummaryEntry(date: Date(), summary: context.isPreview ? (SharedStore.summary() ?? .placeholder) : SharedStore.summary()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        // The app reloads timelines when it learns something new; the
        // periodic refresh only keeps the "observed … ago" text current.
        let entry = SummaryEntry(date: Date(), summary: SharedStore.summary())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

extension WidgetSummary {
    static var placeholder: WidgetSummary {
        let connection = UUID()
        return WidgetSummary(updatedAt: Date(), cameras: [
            .init(id: CameraID(connectionID: connection, nativeID: "a"), name: "Front Door", connectionName: "Frigate", state: .online, observedAt: Date(), armed: nil, isFavorite: true, listedAt: Date(), hasLiveView: true),
            .init(id: CameraID(connectionID: connection, nativeID: "b"), name: "Garage", connectionName: "Frigate", state: .offline, observedAt: Date().addingTimeInterval(-600), armed: nil, isFavorite: false, listedAt: Date(), hasLiveView: true),
        ])
    }
}

struct CameraStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CameraStatus", provider: SummaryProvider()) { entry in
            CameraStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cameras")
        .description("Favorite cameras with their last known status. Tap to open live view.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CameraStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SummaryEntry

    var body: some View {
        if let cameras = entry.summary?.cameras, !cameras.isEmpty {
            switch family {
            case .systemSmall:
                CameraCell(camera: cameras[0], large: true)
                    .widgetURL(WidgetSummary.deepLink(for: cameras[0].id))
            case .systemMedium:
                grid(Array(cameras.prefix(2)), columns: 2)
            default:
                grid(Array(cameras.prefix(4)), columns: 2)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "video.badge.plus").font(.title)
                Text("Open Camera Monitor to add cameras.").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func grid(_ cameras: [WidgetSummary.Camera], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(cameras) { camera in
                Link(destination: WidgetSummary.deepLink(for: camera.id)) {
                    CameraCell(camera: camera, large: family == .systemLarge)
                }
            }
        }
    }
}

struct CameraCell: View {
    let camera: WidgetSummary.Camera
    let large: Bool

    var body: some View {
        let thumbnail = SharedStore.thumbnail(for: camera, maxPixels: large ? 500 : 300)
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.85))
                if let thumbnail {
                    Image(decorative: thumbnail.0, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(thumbnail.1, style: .relative)
                        .font(.system(size: 9)).padding(.horizontal, 4).padding(2)
                        .background(.ultraThinMaterial, in: Capsule()).padding(3)
                } else {
                    Image(systemName: "video").foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()
            HStack(spacing: 4) {
                Image(systemName: camera.state?.widgetSymbol ?? "questionmark.circle")
                    .foregroundStyle(camera.state?.widgetColor ?? .secondary)
                Text(camera.name).font(.caption.bold()).lineLimit(1)
            }
            Text(statusText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var statusText: String {
        guard let state = camera.state, let observed = camera.observedAt else { return "Status not observed" }
        return "\(state == .online ? "Online" : state.displayName) · \(observed.formatted(.relative(presentation: .named)))"
    }
}

#if os(iOS)
/// Lock Screen: how many cameras were last seen online.
struct CameraSummaryAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CameraSummaryAccessory", provider: SummaryProvider()) { entry in
            let cameras = entry.summary?.cameras ?? []
            let online = cameras.filter { $0.state == .online }.count
            let problems = cameras.filter { [.offline, .authenticationFailed, .disconnectedHardware, .staleStream].contains($0.state) }.count
            VStack(alignment: .leading) {
                Label("\(online)/\(cameras.count) online", systemImage: "video")
                if problems > 0 { Text("\(problems) need attention").font(.caption) }
                if let date = entry.summary?.updatedAt { Text(date, style: .relative).font(.caption2) }
            }
            .containerBackground(.clear, for: .widget)
            .widgetURL(URL(string: "cameramonitor://cameras"))
        }
        .configurationDisplayName("Camera Status")
        .description("How many cameras were last seen online.")
        .supportedFamilies([.accessoryRectangular])
    }
}
#endif

extension CameraState {
    var widgetColor: Color {
        switch self {
        case .online: .green
        case .unknown: .secondary
        case .staleStream, .recorderUnavailable, .storageUnavailable: .orange
        case .offline, .authenticationFailed, .disconnectedHardware: .red
        }
    }

    var widgetSymbol: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .unknown: "questionmark.circle"
        case .offline: "wifi.slash"
        case .authenticationFailed: "lock.slash"
        case .disconnectedHardware: "cable.connector.slash"
        case .staleStream: "clock.badge.exclamationmark"
        case .recorderUnavailable: "record.circle"
        case .storageUnavailable: "externaldrive.badge.exclamationmark"
        }
    }
}
