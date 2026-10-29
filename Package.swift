// swift-tools-version:6.0
// OpenXM for Mac.
// scripts/build.sh wraps the SwiftPM executable into a signed macOS app bundle.
import PackageDescription

let package = Package(
    name: "OpenXM",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "OpenXM", targets: ["OpenXM"]),
        .executable(name: "OpenXMArtwork", targets: ["OpenXMArtwork"]),
    ],
    targets: [
        .testTarget(name: "OpenXMTests", dependencies: ["OpenXM"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "OpenXM",
            path: "Sources/OpenXM",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("SceneKit"),
            ]
        ),
        // Build-time tool: renders the app icon (and nothing else) with CoreGraphics into an .iconset.
        .executableTarget(
            name: "OpenXMArtwork",
            path: "Sources/OpenXMArtwork",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
