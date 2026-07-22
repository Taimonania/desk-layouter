import Foundation

public struct AssignmentMigrationResult: Equatable, Sendable {
    public let board: BoardState
    public let library: PresetLibrary

    public init(board: BoardState, library: PresetLibrary) {
        self.board = board
        self.library = library
    }
}

public enum DisplayMigrationPlan: Equatable, Sendable {
    case notNeeded
    case automatic(DisplayIdentity)
    case requiresChoice([DisplayIdentity])
}

/// Pure, coordinated migration of every persisted Assignment surface.
///
/// The caller supplies one explicitly resolved Display snapshot, either because
/// the active topology has one logical Display or because the user selected one
/// from an ambiguous multi-Display topology. This type has no adapter, filesystem,
/// Apply, or Arrange dependency, so choosing a migration destination cannot enact
/// anything on macOS.
public enum AssignmentMigration {
    public static func plan(
        board: BoardState,
        library: PresetLibrary,
        availableDisplays: [DisplayIdentity]
    ) -> DisplayMigrationPlan {
        guard needsMigration(board: board, library: library) else { return .notNeeded }
        if availableDisplays.count == 1, let display = availableDisplays.first {
            return .automatic(display)
        }
        return .requiresChoice(availableDisplays)
    }

    public static func needsMigration(board: BoardState, library: PresetLibrary) -> Bool {
        board.configuration.managedApplications.contains { $0.display == nil }
            || board.appliedAssignments.values.contains { $0.display == nil }
            || library.presets.contains { preset in
                preset.managedApplications.contains { $0.display == nil }
            }
    }

    public static func migrate(
        board: BoardState,
        library: PresetLibrary,
        to snapshot: DesktopSnapshot,
        appliedDesktopUUIDs: [String: String] = [:]
    ) -> AssignmentMigrationResult {
        guard let display = snapshot.display else {
            return AssignmentMigrationResult(board: board, library: library)
        }

        let migratedConfiguration = attachingLegacyAssignments(
            in: board.configuration,
            to: display
        )
        let migratedAppliedAssignments = Dictionary(
            uniqueKeysWithValues: board.appliedAssignments.map { bundleIdentifier, applied in
                guard applied.display == nil else { return (bundleIdentifier, applied) }
                return (
                    bundleIdentifier,
                    AppliedAssignment(
                        display: display,
                        desktopNumber: applied.desktopNumber,
                        concreteDesktopUUID: appliedDesktopUUIDs[bundleIdentifier]
                    )
                )
            }
        )
        let migratedBoard = BoardState(
            configuration: migratedConfiguration,
            appliedAssignments: migratedAppliedAssignments,
            selectedPresetID: board.selectedPresetID
        )
        let migratedLibrary = PresetLibrary(
            presets: library.presets.map { preset in
                Preset(
                    id: preset.id,
                    name: preset.name,
                    managedApplications: preset.managedApplications.map {
                        attachingLegacyAssignment($0, to: display)
                    }
                )
            }
        )
        return AssignmentMigrationResult(board: migratedBoard, library: migratedLibrary)
    }

    private static func attachingLegacyAssignments(
        in configuration: DeskLayouterConfiguration,
        to display: DisplayIdentity
    ) -> DeskLayouterConfiguration {
        DeskLayouterConfiguration(
            managedApplications: configuration.managedApplications.map {
                attachingLegacyAssignment($0, to: display)
            },
            pendingRemovals: configuration.pendingRemovals
        )
    }

    private static func attachingLegacyAssignment(
        _ application: ManagedApplication,
        to display: DisplayIdentity
    ) -> ManagedApplication {
        guard application.display == nil else { return application }
        return ManagedApplication(
            bundleIdentifier: application.bundleIdentifier,
            displayName: application.displayName,
            display: display,
            desktopNumber: application.desktopNumber,
            layout: application.layout
        )
    }
}
