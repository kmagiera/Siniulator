// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Siniulator",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Siniulator", targets: ["Siniulator"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(name: "SimulatorBridge", path: "Sources/SimulatorBridge", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("IOSurface")]),
        .executableTarget(name: "Siniulator", dependencies: ["SimulatorBridge", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("MetalKit"), .linkedFramework("CoreImage"),
                                           .linkedFramework("SceneKit"),
                                           .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "SiniulatorTests", dependencies: ["Siniulator"])
    ],
    swiftLanguageModes: [.v6]
)
