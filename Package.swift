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
    dependencies: [
        // Sparkle 2 drives in-app auto-updates (see App/Info.plist SUFeedURL/SUPublicEDKey).
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.6.0")),
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
                "PresetLibraryStore.swift",
                "PresetSwitch.swift",
                "PresetEditing.swift",
                "InstalledApplicationsProvider.swift",
                "WindowArranger.swift",
                "DesktopArrangePlan.swift",
                "ArrangeTransitionCoordinator.swift",
                "EditorPresenter.swift",
            ]
        ),
        .executableTarget(
            name: "DeskLayouter",
            dependencies: [
                "DeskLayouterCore",
                "DeskLayouterMacOS",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DeskLayouter",
            exclude: [
                "SpacesAdapter.swift",
                "DisplayResolution.swift",
                "ConfigurationStore.swift",
                "BoardStateStore.swift",
                "PresetLibraryStore.swift",
                "PresetSwitch.swift",
                "PresetEditing.swift",
                "InstalledApplicationsProvider.swift",
                "WindowArranger.swift",
                "DesktopArrangePlan.swift",
                "ArrangeTransitionCoordinator.swift",
                "EditorPresenter.swift",
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
            name: "DeskLayouterPresetTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterPresetTests"
        ),
        .executableTarget(
            name: "DeskLayouterPresetSwitchTests",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Tests/DeskLayouterPresetSwitchTests"
        ),
        .executableTarget(
            name: "DeskLayouterPresetEditingTests",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Tests/DeskLayouterPresetEditingTests"
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
            name: "DeskLayouterTransitionTests",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Tests/DeskLayouterTransitionTests"
        ),
        .executableTarget(
            name: "DeskLayouterActiveDesktopTests",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Tests/DeskLayouterActiveDesktopTests"
        ),
        .executableTarget(
            name: "DeskLayouterArrangeReportTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterArrangeReportTests"
        ),
        .executableTarget(
            name: "DeskLayouterDisplayNameTests",
            dependencies: ["DeskLayouterCore"],
            path: "Tests/DeskLayouterDisplayNameTests"
        ),
        .executableTarget(
            name: "DeskLayouterMenuBarTests",
            dependencies: ["DeskLayouterMacOS"],
            path: "Tests/DeskLayouterMenuBarTests"
        ),
        .executableTarget(
            name: "DeskLayouterUnavailableTests",
            dependencies: ["DeskLayouterCore", "DeskLayouterMacOS"],
            path: "Tests/DeskLayouterUnavailableTests"
        ),
    ]
)
