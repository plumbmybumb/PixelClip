// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PixelClipKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "PixelClipKit", targets: ["PixelClipKit"]),
    ],
    targets: [
        .target(
            name: "PixelClipKit",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "PixelClipKitTests",
            dependencies: ["PixelClipKit"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
