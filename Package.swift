// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gaze",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Gaze", targets: ["GazeApp"]),
        .library(name: "GazeKit", targets: ["GazeKit"]),
    ],
    dependencies: [
        // Updates for people Gaze is shared with.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
    ],
    targets: [
        .target(name: "GazeKit"),
        .executableTarget(
            name: "GazeApp",
            dependencies: ["GazeKit", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is copied into Gaze.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "GazeEval",
            dependencies: ["GazeKit"],
            // A one-off script: top-level state shared with its helper functions.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GazeKitTests",
            dependencies: ["GazeKit"]
        ),
    ]
)
