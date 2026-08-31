// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Crunch",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Crunch",
            path: "Sources/Crunch"
        )
    ]
)
