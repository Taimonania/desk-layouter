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
        .target(
            name: "DeskLayouterMacOS",
            dependencies: ["DeskLayouterCore"],
            path: "Sources/DeskLayouter",
            exclude: ["AppDelegate.swift", "EditorModel.swift", "EditorView.swift"],
            sources: ["SpacesAdapter.swift"]
        ),
        .executableTarget(
            name: "DeskLayouter",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Sources/DeskLayouter",
            exclude: ["SpacesAdapter.swift"]
        ),
        .executableTarget(
            name: "DeskLayouterPlannerTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterPlannerTests"
        ),
        .executableTarget(
            name: "DeskLayouterDesktopPlacementTests",
            dependencies: ["DeskLayouterMacOS"],
            path: "Tests/DeskLayouterDesktopPlacementTests"
        ),
    ]
)
