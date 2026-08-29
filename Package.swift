// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Grove",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Grove", targets: ["Grove"])
    ],
    targets: [
        .executableTarget(
            name: "Grove",
            path: "Sources/Grove"
        ),
        .testTarget(
            name: "GroveTests",
            dependencies: ["Grove"]
        )
    ]
)
