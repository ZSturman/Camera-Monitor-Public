import CameraCore
import SwiftUI

@main
struct CameraMonitorApp: App {
    @State private var model = AppModel.makeDefault()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
                .homePageExport(model.homePageSummary)
                .onOpenURL { model.open($0) }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif

        #if os(macOS)
        // Separate, resizable viewing windows for individual cameras.
        WindowGroup("Camera", id: "camera", for: CameraID.self) { $cameraID in
            if let cameraID {
                CameraWindow(cameraID: cameraID)
                    .environment(model)
            }
        }
        .defaultSize(width: 800, height: 520)
        #endif
    }
}

#if os(macOS)
private struct CameraWindow: View {
    @Environment(AppModel.self) private var model
    let cameraID: CameraID

    var body: some View {
        if let camera = model.library.camera(cameraID) {
            LivePlayerContainer(camera: camera)
                .navigationTitle(model.library.displayName(camera))
        } else {
            ContentUnavailableView("Camera unavailable", systemImage: "video.slash", description: Text("This camera's connection was removed or hasn't loaded yet."))
        }
    }
}
#endif
