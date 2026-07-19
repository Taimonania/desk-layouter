// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DeskLayouter",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "DeskLayouter", targets: ["DeskLayouter"]),
    ],
    targets: [
        .executableTarget(
            name: "DeskLayouter",
            path: "Sources/DeskLayouter"
        ),
    ]
)
