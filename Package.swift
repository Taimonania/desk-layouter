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
            exclude: ["AppDelegate.swift", "EditorModel.swift", "EditorView.swift", "LayoutEditorView.swift"],
            sources: [
                "SpacesAdapter.swift",
                "DisplayResolution.swift",
                "ConfigurationStore.swift",
                "BoardStateStore.swift",
                "InstalledApplicationsProvider.swift",
                "WindowArranger.swift",
                "DesktopArrangePlan.swift",
            ]
        ),
        .executableTarget(
            name: "DeskLayouter",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Sources/DeskLayouter",
            exclude: [
                "SpacesAdapter.swift",
                "DisplayResolution.swift",
                "ConfigurationStore.swift",
                "BoardStateStore.swift",
                "InstalledApplicationsProvider.swift",
                "WindowArranger.swift",
                "DesktopArrangePlan.swift",
            ]
        ),
        .executableTarget(
            name: "DeskLayouterPlannerTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterPlannerTests"
        ),
        .executableTarget(
            name: "DeskLayouterBoardTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterBoardTests"
        ),
        .executableTarget(
            name: "DeskLayouterLayoutTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterLayoutTests"
        ),
        .executableTarget(
            name: "DeskLayouterLayoutEditorTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterLayoutEditorTests"
        ),
        .executableTarget(
            name: "DeskLayouterConfigStoreTests",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Tests/DeskLayouterConfigStoreTests"
        ),
        .executableTarget(
            name: "DeskLayouterPickerTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterPickerTests"
        ),
        .executableTarget(
            name: "DeskLayouterReconcilerTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterReconcilerTests"
        ),
        .executableTarget(
            name: "DeskLayouterAdapterFailureTests",
            dependencies: ["DeskLayouterMacOS"],
            path: "Tests/DeskLayouterAdapterFailureTests"
        ),
        .executableTarget(
            name: "DeskLayouterDesktopPlacementTests",
            dependencies: ["DeskLayouterMacOS"],
            path: "Tests/DeskLayouterDesktopPlacementTests"
        ),
        .executableTarget(
            name: "DeskLayouterDisplayTests",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Tests/DeskLayouterDisplayTests"
        ),
        .executableTarget(
            name: "DeskLayouterArrangeTests",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Tests/DeskLayouterArrangeTests"
        ),
        .executableTarget(
            name: "DeskLayouterArrangePlanTests",
            dependencies: ["DeskLayouterMacOS"],
            path: "Tests/DeskLayouterArrangePlanTests"
        ),
        .executableTarget(
            name: "DeskLayouterArrangeReportTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterArrangeReportTests"
        ),
    ]
)
