// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YTKBApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "YTKBApp",
            path: "Sources/YTKBApp"
        )
    ]
)
