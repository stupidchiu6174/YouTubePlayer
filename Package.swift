// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YouTubePlayer",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "YouTubePlayer", targets: ["YouTubePlayer"]),
        .executable(name: "YouTubePlayerApp", targets: ["YouTubePlayerApp"]),
    ],
    targets: [
        .target(name: "YouTubePlayer", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "YouTubePlayerApp", dependencies: ["YouTubePlayer"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
