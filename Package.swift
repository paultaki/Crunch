// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Crunch",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "CrunchCore",
            path: "Sources/CrunchCore"
        ),
        .executableTarget(
            name: "Crunch",
            dependencies: ["CrunchCore"],
            path: "Sources/Crunch"
        ),
        .testTarget(
            name: "CrunchTests",
            dependencies: ["CrunchCore"],
            path: "Tests/CrunchTests"
        )
    ]
)
