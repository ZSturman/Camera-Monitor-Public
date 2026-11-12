import ImageIO
import CameraCore
import SwiftUI

/// Tiles for every visible camera, favorites first. Tiles never open live
/// streams, so a large grid doesn't pull every feed at once; cameras whose
/// provider offers still images show one, refreshed every minute while the
/// grid is on screen and kept (dated) for widgets. Tap a tile for live view.
struct CameraGridView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cameras = model.library.orderedCameras
        ScrollView {
            if cameras.isEmpty {
                ContentUnavailableView {
                    Label("No cameras loaded", systemImage: "video.slash")
                } description: {
                    Text(model.library.hiddenCameras.isEmpty ? "Check the Connections list for errors, or add a connection." : "All cameras are hidden. Unhide them from a camera's settings.")
                } actions: {
                    Button("Add Connection") { model.beginAdd() }
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(cameras) { camera in
                        Button {
                            model.selection = .camera(camera.id)
                        } label: {
                            CameraTile(camera: camera, connection: model.library.profile(camera.id.connectionID))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TileMenu(camera: camera) }
                        .accessibilityIdentifier("tile.\(model.library.displayName(camera))")
                    }
                }
                .padding()
            }
        }
        .navigationTitle("All Cameras")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

struct TileMenu: View {
    @Environment(AppModel.self) private var model
    let camera: CameraDescriptor

    var body: some View {
        let preferences = model.library.preferences(for: camera.id)
        Button {
            var updated = preferences
            updated.isFavorite.toggle()
            model.library.setPreferences(updated, for: camera.id)
            model.reloadWidgets()
        } label: {
            Label(preferences.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: preferences.isFavorite ? "star.slash" : "star")
        }
        Button {
            var updated = preferences
            updated.isHidden = true
            model.library.setPreferences(updated, for: camera.id)
            model.reloadWidgets()
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }
    }
}

struct CameraTile: View {
    @Environment(AppModel.self) private var model
    let camera: CameraDescriptor
    let connection: ConnectionProfile?
    @State private var thumbnail: CGImage?
    @State private var thumbnailDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black.gradient)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Image(systemName: camera.capabilities.liveView == nil ? "video.slash" : "play.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 3)
                if let thumbnailDate {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(thumbnailDate, style: .relative)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                        }
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()
            HStack {
                VStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        if model.library.preferences(for: camera.id).isFavorite {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                        }
                        Text(model.library.displayName(camera)).font(.headline)
                    }
                    Text(connection?.name ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusDot(status: camera.status)
            }
            HStack(spacing: 6) {
                if let live = camera.capabilities.liveView { CapabilityChip(text: live.displayName, symbol: "dot.radiowaves.left.and.right") }
                if camera.capabilities.serverRecording.isSupported { CapabilityChip(text: "Records", symbol: "record.circle") }
                if camera.capabilities.motionEvents.isSupported { CapabilityChip(text: "Motion", symbol: "figure.walk.motion") }
                if camera.status?.armed == true { CapabilityChip(text: "Armed", symbol: "shield.fill") }
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .task(id: camera.id) { await refreshThumbnails() }
    }

    private func refreshThumbnails() async {
        let url = model.thumbnailURL(for: camera.id)
        if let data = try? Data(contentsOf: url) {
            thumbnail = Self.decode(data)
            thumbnailDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        }
        guard camera.capabilities.snapshot.isSupported else { return }
        while !Task.isCancelled {
            if let provider = model.library.provider(for: camera.id.connectionID), let data = try? await provider.snapshot(for: camera.id), let image = Self.decode(data) {
                thumbnail = image
                thumbnailDate = Date()
                model.storeThumbnail(data, for: camera.id)
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary)
    }
}

struct CapabilityChip: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}
