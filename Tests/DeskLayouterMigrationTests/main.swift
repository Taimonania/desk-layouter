import DeskLayouterCore
import Foundation

private struct RawConfigurationDocument: Encodable {
    let managedApplications: [ManagedApplication]
    let pendingRemovals: [String]
}

private struct RawPresetDocument: Encodable {
    let id: UUID
    let name: String
    let managedApplications: [ManagedApplication]
}

@main
struct MigrationTestRunner {
    static func main() {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok: \(name)")
            } else {
                let detailText = detail()
                let suffix = detailText.isEmpty ? "" : " — \(detailText)"
                failures.append("\(name)\(suffix)")
                print("  FAIL: \(name)\(suffix)")
            }
        }

        let display = DisplayIdentity(
            colorSyncUUID: "B173FA83-AFFB-4C9B-B03A-F57BA529EFF1",
            lastKnownName: "DELL S3423DWC",
            vendorID: 4_263,
            modelID: 16_897,
            serialNumber: 123_456
        )
        let layout = Layout(
            horizontalDivision: .thirds,
            verticalDivision: .halves,
            columnSpan: .single(1),
            rowSpan: .single(0)
        )
        let presetID = UUID()
        let legacyApplication = ManagedApplication.legacy(
            bundleIdentifier: "com.example.Writer",
            displayName: "Writer",
            desktopNumber: 2,
            layout: layout
        )
        var legacyBoard = BoardState(
            configuration: DeskLayouterConfiguration(
                managedApplications: [legacyApplication],
                pendingRemovals: ["com.example.Removed"]
            ),
            appliedBaseline: ["com.example.Writer": 2],
            selectedPresetID: presetID
        )
        legacyBoard.move(bundleIdentifier: "com.example.Writer", toDesktop: 3)
        let library = PresetLibrary(presets: [
            Preset(id: presetID, name: "Work", managedApplications: [legacyApplication]),
            Preset(name: "Empty", managedApplications: []),
        ])
        let snapshot = DesktopSnapshot(
            display: display,
            orderedDesktopUUIDs: ["D1", "D2", "D3"]
        )

        check(
            "one active Display plans automatic migration",
            AssignmentMigration.plan(
                board: legacyBoard,
                library: library,
                availableDisplays: [display]
            ) == .automatic(display)
        )
        let secondDisplay = DisplayIdentity(
            colorSyncUUID: "94A740C1-0030-43DB-9FC2-DA11D7C5FA99",
            lastKnownName: "Studio Display",
            vendorID: 1_552,
            modelID: 8_902,
            serialNumber: 654_321
        )
        check(
            "multiple active Displays require an explicit unselected choice",
            AssignmentMigration.plan(
                board: legacyBoard,
                library: library,
                availableDisplays: [display, secondDisplay]
            ) == .requiresChoice([display, secondDisplay])
        )
        let explicitlyChosen = AssignmentMigration.migrate(
            board: legacyBoard,
            library: library,
            to: DesktopSnapshot(
                display: secondDisplay,
                orderedDesktopUUIDs: ["S1", "S2", "S3"]
            )
        )
        check(
            "the explicit multi-Display choice is applied consistently",
            explicitlyChosen.board.configuration.managedApplications.allSatisfy {
                $0.display == secondDisplay
            }
                && explicitlyChosen.board.appliedAssignments.values.allSatisfy {
                    $0.display == secondDisplay
                }
                && explicitlyChosen.library.presets.flatMap(\.managedApplications).allSatisfy {
                    $0.display == secondDisplay
                }
        )

        let migrated = AssignmentMigration.migrate(
            board: legacyBoard,
            library: library,
            to: snapshot,
            appliedDesktopUUIDs: ["com.example.Writer": "D2"]
        )

        check(
            "migration attaches the chosen physical Display to the working board",
            migrated.board.configuration.managedApplications.first?.display == display
        )
        check(
            "migration preserves the working Desktop and Layout",
            migrated.board.configuration.managedApplications.first?.desktopNumber == 3
                && migrated.board.configuration.managedApplications.first?.layout == layout
        )
        check(
            "migration attaches the same Display to every Preset Assignment",
            migrated.library.presets.flatMap(\.managedApplications).allSatisfy { $0.display == display }
        )
        check(
            "migration preserves Preset order, identity, and selection",
            migrated.library.presets.map(\.name) == ["Work", "Empty"]
                && migrated.board.selectedPresetID == presetID
        )
        check(
            "migration preserves pending removals and application ordering",
            migrated.board.configuration.pendingRemovals == ["com.example.Removed"]
                && migrated.board.configuration.managedApplications.map(\.bundleIdentifier) == ["com.example.Writer"]
        )
        check(
            "migration preserves semantic pending state",
            migrated.board.pendingChanges == legacyBoard.pendingChanges
        )
        check(
            "migration preserves selected-Preset dirty state",
            migrated.library.isModified(
                migrated.board.configuration,
                from: migrated.board.selectedPresetID
            ) == library.isModified(
                legacyBoard.configuration,
                from: legacyBoard.selectedPresetID
            )
        )
        check(
            "migration records the semantic baseline and concrete Desktop UUID",
            migrated.board.appliedAssignments["com.example.Writer"]
                == AppliedAssignment(
                    display: display,
                    desktopNumber: 2,
                    concreteDesktopUUID: "D2"
                )
        )

        do {
            let encodedBoard = try BoardStateSerialization.encode(migrated.board)
            let decodedBoard = try BoardStateSerialization.decode(from: encodedBoard)
            let encodedLibrary = try PresetLibrarySerialization.encode(migrated.library)
            let decodedLibrary = try PresetLibrarySerialization.decode(from: encodedLibrary)
            check("migrated board round-trips", decodedBoard == migrated.board)
            check("migrated Presets round-trip", decodedLibrary == migrated.library)
            let boardJSON = String(decoding: encodedBoard, as: UTF8.self)
            check("persisted identity contains the ColorSync UUID", boardJSON.contains(display.colorSyncUUID))
            check("persisted identity contains recovery metadata", boardJSON.contains("vendorID") && boardJSON.contains("lastKnownName"))
            check("transient identity facts are never persisted", !boardJSON.contains("displayID") && !boardJSON.contains("isMain") && !boardJSON.contains("geometry") && !boardJSON.contains("displayNumber") && !boardJSON.contains("Main\""))
        } catch {
            check("migrated state serializes", false, "\(error)")
        }

        // Legacy files from each persistence generation decode without losing
        // Assignments or Layouts and stay explicitly unmigrated until topology is
        // known. Migration itself is pure: it cannot Apply or Arrange.
        do {
            let legacyConfigurationJSON = Data(#"{"managedApplications":[{"bundleIdentifier":"com.example.Legacy","displayName":"Legacy","desktopNumber":2,"layout":{"horizontalDivision":2,"verticalDivision":2,"columnSpan":{"start":0,"end":0},"rowSpan":{"start":0,"end":0}}}]}"#.utf8)
            let decoded = try ConfigurationSerialization.decode(from: legacyConfigurationJSON)
            check("legacy configuration decodes with its Assignment intact", decoded.managedApplications.first?.desktopNumber == 2)
            check("legacy configuration remains marked for migration", decoded.managedApplications.first?.display == nil)
            check("legacy configuration keeps its Layout", decoded.managedApplications.first?.layout != nil)

            let legacyBoardJSON = Data(#"{"configuration":{"managedApplications":[{"bundleIdentifier":"com.example.Legacy","displayName":"Legacy","desktopNumber":2}]},"appliedBaseline":{"com.example.Legacy":2}}"#.utf8)
            let decodedBoard = try BoardStateSerialization.decode(from: legacyBoardJSON)
            check("legacy board baseline decodes without loss", decodedBoard.appliedBaseline == ["com.example.Legacy": 2])
            check("legacy board is recognized as needing migration", AssignmentMigration.needsMigration(board: decodedBoard, library: PresetLibrary()))

            let legacyPresetsJSON = Data(#"{"presets":[{"id":"00000000-0000-0000-0000-000000000021","name":"Legacy","managedApplications":[{"bundleIdentifier":"com.example.Legacy","displayName":"Legacy","desktopNumber":2}]}]}"#.utf8)
            let decodedPresets = try PresetLibrarySerialization.decode(from: legacyPresetsJSON)
            check("legacy Preset decodes without loss", decodedPresets.presets.first?.managedApplications.first?.desktopNumber == 2)
            check("legacy Preset is recognized as needing migration", AssignmentMigration.needsMigration(board: BoardState(), library: decodedPresets))
        } catch {
            check("all legacy formats decode", false, "\(error)")
        }

        // Effective UUID drift is Apply-pending but is not a Preset edit because
        // the semantic Display + positional Desktop destination did not change.
        do {
            let application = ManagedApplication(
                bundleIdentifier: "com.example.Writer",
                displayName: "Writer",
                display: display,
                desktopNumber: 2,
                layout: layout
            )
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [application]),
                appliedAssignments: [
                    application.bundleIdentifier: AppliedAssignment(
                        display: display,
                        desktopNumber: 2,
                        concreteDesktopUUID: "OLD-D2"
                    ),
                ],
                selectedPresetID: presetID
            )
            let matchingLibrary = PresetLibrary(presets: [
                Preset(id: presetID, name: "Work", managedApplications: [application]),
            ])
            let reminted = DesktopSnapshot(display: display, orderedDesktopUUIDs: ["D1", "NEW-D2"])
            check(
                "a reminted effective Desktop UUID makes Apply pending",
                board.pendingChanges(on: reminted) == [application.bundleIdentifier]
            )
            check(
                "effective UUID drift does not mark the selected Preset edited",
                !matchingLibrary.isModified(board.configuration, from: presetID)
            )

            let sameEffectiveUUIDAfterMainRoleChange = DesktopSnapshot(
                display: display,
                orderedDesktopUUIDs: ["D1", "OLD-D2"]
            )
            check(
                "a Main-role change alone stays Apply-clean when the effective UUID is unchanged",
                board.pendingChanges(on: sameEffectiveUUIDAfterMainRoleChange).isEmpty
            )
        }

        // Reassigning an existing application across physical Displays replaces
        // its one Assignment instead of creating one Assignment per Display.
        do {
            var configuration = DeskLayouterConfiguration()
            configuration.upsert(
                ManagedApplication(
                    bundleIdentifier: "com.example.Unique",
                    displayName: "Unique",
                    display: display,
                    desktopNumber: 1
                )
            )
            configuration.upsert(
                ManagedApplication(
                    bundleIdentifier: "com.example.Unique",
                    displayName: "Unique",
                    display: secondDisplay,
                    desktopNumber: 2
                )
            )
            check(
                "one application has at most one Assignment across Displays",
                configuration.managedApplications.count == 1
                    && configuration.managedApplications.first?.display == secondDisplay
                    && configuration.managedApplications.first?.desktopNumber == 2
            )
        }

        // In this one-logical-Display slice, an Assignment for another physical
        // Display must block Apply rather than being skipped and then deleted by
        // the adapter's managed-key reconciliation.
        do {
            let application = ManagedApplication(
                bundleIdentifier: "com.example.External",
                displayName: "External",
                display: secondDisplay,
                desktopNumber: 1
            )
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [application])
            )
            check(
                "an Assignment for another physical Display blocks Apply resolution",
                board.hasUnavailableDisplayAssignments(on: snapshot)
            )
            check(
                "an Assignment for its active physical Display remains resolvable",
                !board.hasUnavailableDisplayAssignments(
                    on: DesktopSnapshot(display: secondDisplay, orderedDesktopUUIDs: ["S1"])
                )
            )
        }

        // Persistence boundaries retain only the latest Assignment for a bundle
        // identifier while preserving its first position in application order.
        do {
            let first = ManagedApplication(
                bundleIdentifier: "com.example.Unique",
                displayName: "Unique",
                display: display,
                desktopNumber: 1
            )
            let replacement = ManagedApplication(
                bundleIdentifier: first.bundleIdentifier,
                displayName: first.displayName,
                display: secondDisplay,
                desktopNumber: 2
            )
            let trailing = ManagedApplication(
                bundleIdentifier: "com.example.Trailing",
                displayName: "Trailing",
                display: display,
                desktopNumber: 3
            )
            let configuration = DeskLayouterConfiguration(
                managedApplications: [first, trailing, replacement]
            )
            let preset = Preset(
                name: "Unique",
                managedApplications: [first, trailing, replacement]
            )
            check(
                "constructed boards enforce one Assignment per application",
                configuration.managedApplications == [replacement, trailing]
            )
            check(
                "constructed Presets enforce one Assignment per application",
                preset.managedApplications == [replacement, trailing]
            )

            do {
                let configurationData = try JSONEncoder().encode(
                    RawConfigurationDocument(
                        managedApplications: [first, trailing, replacement],
                        pendingRemovals: []
                    )
                )
                let decoded = try ConfigurationSerialization.decode(from: configurationData)
                let presetData = try JSONEncoder().encode(
                    RawPresetDocument(
                        id: preset.id,
                        name: preset.name,
                        managedApplications: [first, trailing, replacement]
                    )
                )
                let decodedPreset = try JSONDecoder().decode(Preset.self, from: presetData)
                check(
                    "decoded boards enforce one Assignment per application",
                    decoded.managedApplications == [replacement, trailing]
                )
                check(
                    "decoded Presets enforce one Assignment per application",
                    decodedPreset.managedApplications == [replacement, trailing]
                )
            } catch {
                check("duplicate persisted Assignments decode", false, "\(error)")
            }
        }

        if failures.isEmpty {
            print("Migration tests passed")
        } else {
            fatalError("Migration tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
