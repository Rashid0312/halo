// swift-tools-version: 6.2
import PackageDescription
import Foundation

let nativeLibraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".native").path

let package = Package(
    name: "HaloNative",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Halo", targets: ["Halo"])],
    targets: [
        .target(name: "HaloCore"),
        .target(name: "CWake", linkerSettings: [
            .linkedLibrary("sherpa-onnx-c-api"),
            .unsafeFlags(["-L", nativeLibraries, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
        ]),
        .executableTarget(name: "Halo", dependencies: ["HaloCore", "CWake"]),
        .executableTarget(name: "HaloCoreChecks", dependencies: ["HaloCore"], path: "Checks"),
    ]
)
