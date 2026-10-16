// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HaloNative",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Halo", targets: ["Halo"])],
    targets: [
        .target(name: "HaloCore"),
        .executableTarget(name: "Halo", dependencies: ["HaloCore"]),
        .executableTarget(name: "HaloCoreChecks", dependencies: ["HaloCore"], path: "Checks"),
    ]
)
