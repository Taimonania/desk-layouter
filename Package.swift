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
        .target(name: "DeskLayouterCore"),
        .executableTarget(
            name: "DeskLayouter",
            dependencies: ["DeskLayouterCore"],
            path: "Sources/DeskLayouter"
        ),
        .executableTarget(
            name: "DeskLayouterPlannerTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterPlannerTests"
        ),
    ]
)
