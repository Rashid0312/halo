// swift-tools-version: 6.2
import PackageDescription
import Foundation

let nativeLibraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".native").path

let package = Package(
    name: "HaloNative",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Halo", targets: ["Halo"])],
    dependencies: [
        .package(path: "../Vendor/Peekaboo/Core/PeekabooAutomationKit"),
        .package(path: "../Vendor/Peekaboo/Core/PeekabooFoundation"),
    ],
    targets: [
        .target(name: "HaloCore"),
        .target(name: "CWake", linkerSettings: [
            .linkedLibrary("sherpa-onnx-c-api"),
            .unsafeFlags(["-L", nativeLibraries, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
        ]),
        .executableTarget(name: "Halo", dependencies: [
            "HaloCore",
            "CWake",
            .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit"),
            .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
        ]),
        .executableTarget(name: "HaloCoreChecks", dependencies: ["HaloCore"], path: "Checks"),
    ]
)
