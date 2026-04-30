// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YTKBApp",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "YTKBKit",
            path: "Sources/YTKBKit"
        ),
        .executableTarget(
            name: "YTKBApp",
            dependencies: ["YTKBKit"],
            path: "Sources/YTKBApp"
        ),
        .executableTarget(
            name: "YTKBAppTests",
            dependencies: ["YTKBKit"],
            path: "Tests/YTKBAppTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
