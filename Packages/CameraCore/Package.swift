// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CameraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CameraCore", targets: ["CameraCore"]),
    ],
    targets: [
        .target(name: "CameraCore"),
        .testTarget(
            name: "CameraCoreTests",
            dependencies: ["CameraCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
