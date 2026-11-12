import CameraCore
import HomeServicesConnection
import SwiftUI

struct CameraPiConnection: View {
    @Environment(AppModel.self) private var model
    private let marker = "piConnection.profile.v1"
    var body: some View {
        PiConnectionHost(preset: "camera-monitor", keychainService: "com.zacharysturman.cameramonitor.pi") { credential in
            guard !model.isIsolated else { return }
            if let credential {
                let id = UserDefaults.standard.string(forKey: marker).flatMap(UUID.init(uuidString:)) ?? UUID()
                UserDefaults.standard.set(id.uuidString, forKey: marker)
                guard let address = URL(string: credential.base_url) else { throw PairingError.invalidResponse }
                var profile = model.library.profiles.first { $0.id == id }
                    ?? ConnectionProfile(id: id, name: credential.connection.token.name, kind: .homeServices, address: address)
                let secret = ConnectionCredential(password: credential.token)
                if profile.address != address || model.library.credential(for: id) != secret {
                    profile.address = address
                    if model.library.profiles.contains(where: { $0.id == id }) {
                        try model.library.update(profile, credential: .replace(secret))
                    } else { try model.library.add(profile, credential: secret) }
                }
                let previousDefault = UserDefaults.standard.string(forKey: "piConnection.defaultCamera.v1")
                await model.refresh()
                if let camera = credential.connection.preferences["camera_id"],
                   previousDefault != camera {
                    let selected = CameraID(connectionID: id, nativeID: camera)
                    if model.library.camera(selected) != nil { model.selection = .camera(selected) }
                    UserDefaults.standard.set(camera, forKey: "piConnection.defaultCamera.v1")
                }
            } else if let raw = UserDefaults.standard.string(forKey: marker), let id = UUID(uuidString: raw) {
                try model.library.remove(id)
                UserDefaults.standard.removeObject(forKey: marker)
                UserDefaults.standard.removeObject(forKey: "piConnection.defaultCamera.v1")
                model.selection = .connections
            }
        }
    }
}
