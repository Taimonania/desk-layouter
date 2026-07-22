import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

private let builtIn = DisplayIdentity(
    colorSyncUUID: "BUILT-IN-UUID",
    lastKnownName: "Built-in Display",
    vendorID: 1,
    modelID: 10,
    serialNumber: 100
)
private let external = DisplayIdentity(
    colorSyncUUID: "EXTERNAL-UUID",
    lastKnownName: "Studio Display",
    vendorID: 2,
    modelID: 20,
    serialNumber: 200
)

private func section(
    primary: DisplayIdentity,
    members: [DisplayIdentity]? = nil,
    main: Bool,
    x: Double,
    desktops: [String]
) -> DisplayDesktopSectionSnapshot {
    DisplayDesktopSectionSnapshot(
        primaryDisplay: primary,
        memberDisplays: members ?? [primary],
        isMain: main,
        bounds: DisplayBounds(x: x, y: 0, width: 1000, height: 800),
        orderedDesktopUUIDs: desktops
    )
}

private final class MultiInventory: DisplayInventoryProviding {
    var displays: [ActiveDisplay]
    init(_ displays: [ActiveDisplay]) { self.displays = displays }
    func activeDisplays() throws -> [ActiveDisplay] { displays }
}

private final class MultiSettings: DisplaySettingsProviding {
    var displaysHaveSeparateSpaces: Bool
    var automaticallyRearrangesSpaces: Bool
    init(separate: Bool = true, rearranges: Bool = false) {
        displaysHaveSeparateSpaces = separate
        automaticallyRearrangesSpaces = rearranges
    }
}

private final class MultiStoreRunner: CommandRunning {
    var monitors: [String: [String]]
    var appBindings: [String: String]
    private(set) var writes = 0
    private(set) var deletes = 0
    private(set) var dockRestarts = 0

    init(monitors: [String: [String]], appBindings: [String: String]) {
        self.monitors = monitors
        self.appBindings = appBindings
    }

    func run(executable: String, arguments: [String]) throws -> Data {
        if executable == "/usr/bin/killall" {
            dockRestarts += 1
            return Data()
        }
        switch arguments.first {
        case "export":
            let entries = monitors.map { key, desktops in
                [
                    "Display Identifier": key,
                    "Spaces": desktops.enumerated().map {
                        ["uuid": $0.element, "ManagedSpaceID": NSNumber(value: $0.offset + 1)]
                    },
                ] as [String: Any]
            }
            return try PropertyListSerialization.data(
                fromPropertyList: [
                    "app-bindings": appBindings,
                    "SpacesDisplayConfiguration": ["Management Data": ["Monitors": entries]],
                ],
                format: .xml,
                options: 0
            )
        case "delete":
            deletes += 1
            appBindings = [:]
            return Data()
        case "write":
            writes += 1
            appBindings[arguments[4]] = arguments[5]
            return Data()
        default:
            return Data()
        }
    }
}

private final class MultiSessionUpdater: SessionBindingUpdating {
    private(set) var preflights = 0
    private(set) var updates: [[String: String]] = []
    func preflight() throws { preflights += 1 }
    func update(appBindings: [String: String]) throws { updates.append(appBindings) }
}

private struct MultiActiveSpaces: ActiveDisplaySpacesProviding {
    let values: [String: UInt64]
    func activeManagedSpaceIDsByDisplayKey() throws -> [String: UInt64] { values }
}

private struct TrustedAuthorizer: AccessibilityAuthorizing {
    func ensureTrusted(promptIfNeeded: Bool) -> Bool { true }
}

private final class RecordingWindowManipulator: WindowManipulating {
    private(set) var moves: [(String, CGRect)] = []
    func moveFrontmostStandardWindow(
        bundleIdentifier: String,
        toTopLeftFrame topLeftFrame: CGRect
    ) -> CGRect? {
        moves.append((bundleIdentifier, topLeftFrame))
        return topLeftFrame
    }
}

private struct PerDisplayGeometry: ScreenGeometryProviding {
    let activeVisibleFrame: CGRect? = nil
    let primaryDisplayHeight: CGFloat
    let frames: [String: CGRect]
    func visibleFrame(for display: DisplayIdentity) -> CGRect? {
        frames[display.colorSyncUUID]
    }
}

private func active(
    id: UInt32,
    identity: DisplayIdentity,
    main: Bool,
    mirrors: UInt32 = 0,
    x: Double
) -> ActiveDisplay {
    ActiveDisplay(
        displayID: id,
        isMain: main,
        mirrorsDisplayID: mirrors,
        identity: identity,
        bounds: DisplayBounds(x: x, y: 0, width: 1000, height: 800)
    )
}

@main
struct MultiDisplayTestRunner {
    static func main() {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok: \(name)")
            } else {
                let rendered = detail()
                failures.append(rendered.isEmpty ? name : "\(name) — \(rendered)")
                print("  FAIL: \(failures.last!)")
            }
        }

        let topology = DisplayTopologySnapshot(
            displaysHaveSeparateSpaces: true,
            automaticallyRearrangesSpaces: false,
            sections: [
                section(primary: builtIn, main: true, x: 0, desktops: ["B1", "B2"]),
                section(primary: external, main: false, x: 1000, desktops: ["E1", "E2"]),
            ]
        )

        // Same positional number on two Displays is a different destination.
        do {
            let config = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.built", displayName: "Built", display: builtIn, desktopNumber: 2),
                ManagedApplication(bundleIdentifier: "com.example.external", displayName: "External", display: external, desktopNumber: 2),
            ])
            let plan = AssignmentPlanner().applyPlan(
                configuration: config,
                on: topology
            )
            check("Desktop 2 resolves independently on each physical Display", plan.updates == [
                "com.example.built": "B2",
                "com.example.external": "E2",
            ], "got \(plan.updates)")
            check("resolved Assignments are not preserved", plan.preservations.isEmpty)
        }

        // Adapter topology resolves Main dynamically, all other Displays by
        // physical UUID, and carries settings into the race token.
        do {
            let inventory = MultiInventory([
                active(id: 1, identity: builtIn, main: true, x: 0),
                active(id: 2, identity: external, main: false, x: 1000),
            ])
            let settings = MultiSettings(separate: true, rearranges: true)
            let runner = MultiStoreRunner(
                monitors: ["Main": ["B1", "B2"], external.colorSyncUUID: ["E1", "E2", "E3"]],
                appBindings: [:]
            )
            let adapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: MultiSessionUpdater(),
                displayInventory: inventory,
                displaySettings: settings
            )
            let live = try! adapter.currentDisplayTopology()
            check("adapter resolves every extended physical Display", live.sections.map(\.orderedDesktopUUIDs) == [["B1", "B2"], ["E1", "E2", "E3"]])
            check("adapter exposes separate-Spaces and positional warning settings", live.displaysHaveSeparateSpaces && live.automaticallyRearrangesSpaces)
            check(
                "positional-order warning does not disable Display actions",
                DisplaySettingsPresentation.actionsAllowed(for: live)
                    && DisplaySettingsPresentation.feedback(for: live).message.contains("positional")
            )

            let sharedSpaces = DisplayTopologySnapshot(
                displaysHaveSeparateSpaces: false,
                automaticallyRearrangesSpaces: true,
                sections: live.sections
            )
            check(
                "separate-Spaces requirement takes precedence over the positional warning",
                !DisplaySettingsPresentation.actionsAllowed(for: sharedSpaces)
                    && DisplaySettingsPresentation.feedback(for: sharedSpaces).message.contains("separate Spaces is off")
            )

            let activeAdapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: MultiSessionUpdater(),
                displayInventory: inventory,
                activeDisplaySpacesProvider: MultiActiveSpaces(values: [
                    "Main": 2,
                    external.colorSyncUUID: 1,
                ]),
                displaySettings: settings
            )
            let visible = try! activeAdapter.activeDesktopDestinations(in: live)
            check(
                "adapter resolves one currently visible Desktop per connected Display",
                visible == [
                    DesktopAddress(display: builtIn, desktopNumber: 2),
                    DesktopAddress(display: external, desktopNumber: 1),
                ],
                "got \(visible)"
            )
        }

        // Apply preserves unmanaged and unresolved bindings, deletes only the
        // explicit removal, and aborts a Main-role race before any mutation.
        do {
            let first = active(id: 1, identity: builtIn, main: true, x: 0)
            let second = active(id: 2, identity: external, main: false, x: 1000)
            let inventory = MultiInventory([first, second])
            let settings = MultiSettings()
            let runner = MultiStoreRunner(
                monitors: [
                    "Main": ["B1", "B2"],
                    builtIn.colorSyncUUID: ["B1", "B2"],
                    external.colorSyncUUID: ["E1", "E2"],
                ],
                appBindings: [
                    "com.example.unmanaged": "U1",
                    "com.example.preserved": "OLD",
                    "com.example.removed": "R1",
                ]
            )
            let updater = MultiSessionUpdater()
            let adapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: updater,
                displayInventory: inventory,
                displaySettings: settings
            )
            let expected = try! adapter.currentDisplayTopology()
            try! adapter.apply(
                plan: AssignmentApplyPlan(
                    updates: ["Com.Example.Changed": "E2"],
                    deletions: ["com.example.removed"],
                    preservations: ["com.example.preserved"]
                ),
                expectedTopology: expected
            )
            check("topology-aware Apply updates resolvable bindings", runner.appBindings["com.example.changed"] == "E2")
            check("topology-aware Apply deletes only explicit removals", runner.appBindings["com.example.removed"] == nil)
            check("topology-aware Apply preserves unresolved and unmanaged bindings", runner.appBindings["com.example.preserved"] == "OLD" && runner.appBindings["com.example.unmanaged"] == "U1")
            check("successful multi-Display Apply restarts Dock and updates the live session once", runner.dockRestarts == 1 && updater.updates.count == 1)

            let writesBeforeRace = runner.writes
            let deletesBeforeRace = runner.deletes
            let restartsBeforeRace = runner.dockRestarts
            inventory.displays = [
                active(id: 1, identity: builtIn, main: false, x: 0),
                active(id: 2, identity: external, main: true, x: 1000),
            ]
            var raceError: Error?
            do {
                try adapter.apply(
                    plan: AssignmentApplyPlan(updates: ["com.example.changed": "E1"], deletions: [], preservations: []),
                    expectedTopology: expected
                )
            } catch { raceError = error }
            check("Main-role topology race aborts", (raceError as? SpacesAdapterError) == .displayTopologyChanged)
            check("topology race performs no write/delete/Dock restart", runner.writes == writesBeforeRace && runner.deletes == deletesBeforeRace && runner.dockRestarts == restartsBeforeRace)

            inventory.displays = [first]
            var hotPlugError: Error?
            do {
                try adapter.apply(
                    plan: AssignmentApplyPlan(
                        updates: ["com.example.changed": "B2"],
                        deletions: [],
                        preservations: []
                    ),
                    expectedTopology: expected
                )
            } catch { hotPlugError = error }
            check("active-Display removal race aborts", (hotPlugError as? SpacesAdapterError) == .displayTopologyChanged)
            check("active-Display removal performs no write/delete/Dock restart", runner.writes == writesBeforeRace && runner.deletes == deletesBeforeRace && runner.dockRestarts == restartsBeforeRace)

            let pendingApp = ManagedApplication(
                bundleIdentifier: "com.example.pending.race",
                displayName: "Pending race",
                display: builtIn,
                desktopNumber: 1
            )
            var pendingBoard = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [pendingApp])
            )
            pendingBoard.move(bundleIdentifier: pendingApp.bundleIdentifier, toDesktop: 2)
            let pendingPlan = AssignmentPlanner().applyPlan(
                configuration: pendingBoard.configuration,
                on: expected
            )
            do {
                try adapter.apply(plan: pendingPlan, expectedTopology: expected)
            } catch {
                // Expected: the external Display is still removed above.
            }
            check(
                "hot-plug race keeps working edits pending",
                pendingBoard.pendingChanges(on: expected) == [pendingApp.bundleIdentifier]
            )

            let replacement = DisplayIdentity(
                colorSyncUUID: "REPLACEMENT-UUID",
                lastKnownName: "Replacement Display"
            )
            let raceTokens = [
                DisplayTopologySnapshot(
                    displaysHaveSeparateSpaces: true,
                    automaticallyRearrangesSpaces: false,
                    sections: [expected.sections[0]]
                ),
                DisplayTopologySnapshot(
                    displaysHaveSeparateSpaces: true,
                    automaticallyRearrangesSpaces: false,
                    sections: [
                        section(primary: replacement, main: true, x: 0, desktops: ["B1", "B2"]),
                        expected.sections[1],
                    ]
                ),
                DisplayTopologySnapshot(
                    displaysHaveSeparateSpaces: true,
                    automaticallyRearrangesSpaces: false,
                    sections: [
                        section(primary: builtIn, main: false, x: 0, desktops: ["B1", "B2"]),
                        section(primary: external, main: true, x: 1000, desktops: ["E1", "E2"]),
                    ]
                ),
                DisplayTopologySnapshot(
                    displaysHaveSeparateSpaces: true,
                    automaticallyRearrangesSpaces: false,
                    sections: [
                        section(
                            primary: builtIn,
                            members: [builtIn, external],
                            main: true,
                            x: 0,
                            desktops: ["B1", "B2"]
                        ),
                    ]
                ),
                DisplayTopologySnapshot(
                    displaysHaveSeparateSpaces: false,
                    automaticallyRearrangesSpaces: false,
                    sections: expected.sections
                ),
                DisplayTopologySnapshot(
                    displaysHaveSeparateSpaces: true,
                    automaticallyRearrangesSpaces: false,
                    sections: [
                        section(primary: builtIn, main: true, x: 0, desktops: ["B2", "B1"]),
                        expected.sections[1],
                    ]
                ),
            ]
            check(
                "race token detects active set, identity, Main, mirror, separate-Spaces, and order changes",
                raceTokens.allSatisfy { $0 != expected }
            )
        }

        do {
            let inventory = MultiInventory([active(id: 1, identity: builtIn, main: true, x: 0)])
            let settings = MultiSettings(separate: false)
            let runner = MultiStoreRunner(monitors: ["Main": ["B1"]], appBindings: ["keep": "B1"])
            let adapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: MultiSessionUpdater(),
                displayInventory: inventory,
                displaySettings: settings
            )
            let expected = try! adapter.currentDisplayTopology()
            var thrown: Error?
            do {
                try adapter.apply(
                    plan: AssignmentApplyPlan(updates: ["new": "B1"], deletions: [], preservations: []),
                    expectedTopology: expected
                )
            } catch { thrown = error }
            check("separate-Spaces off aborts Apply", (thrown as? SpacesAdapterError) == .separateSpacesRequired)
            check("separate-Spaces off performs no mutation", runner.writes == 0 && runner.deletes == 0 && runner.dockRestarts == 0 && runner.appBindings == ["keep": "B1"])
        }

        // Only explicit removals delete; unavailable Displays are preserved,
        // while an invalid Desktop on a connected Display blocks Apply.
        do {
            let disconnected = DisplayIdentity(colorSyncUUID: "OFFLINE", lastKnownName: "Travel Display")
            let config = DeskLayouterConfiguration(
                managedApplications: [
                    ManagedApplication(bundleIdentifier: "com.example.offline", displayName: "Offline", display: disconnected, desktopNumber: 1),
                    ManagedApplication(bundleIdentifier: "com.example.stale", displayName: "Stale", display: builtIn, desktopNumber: 9),
                ],
                pendingRemovals: ["com.example.removed"]
            )
            let plan = AssignmentPlanner().applyPlan(configuration: config, on: topology)
            check("unavailable Display binding is preserved", plan.preservations == ["com.example.offline"], "got \(plan.preservations)")
            check("connected unavailable Desktop blocks Apply", plan.invalidDesktopAssignments == ["com.example.stale"])
            check("only explicit removals are deleted", plan.deletions == ["com.example.removed"])
        }

        // Even a hand-built invalid plan is rejected by the adapter before its
        // preflight, store read, write, session update, or Dock restart.
        do {
            let inventory = MultiInventory([active(id: 1, identity: builtIn, main: true, x: 0)])
            let runner = MultiStoreRunner(
                monitors: ["Main": ["B1"]],
                appBindings: ["com.example.unmanaged": "U1"]
            )
            let updater = MultiSessionUpdater()
            let adapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: updater,
                displayInventory: inventory,
                displaySettings: MultiSettings()
            )
            let expected = try! adapter.currentDisplayTopology()
            var thrown: Error?
            do {
                try adapter.apply(
                    plan: AssignmentApplyPlan(
                        updates: ["com.example.valid": "B1"],
                        deletions: [],
                        preservations: [],
                        invalidDesktopAssignments: ["com.example.invalid"]
                    ),
                    expectedTopology: expected
                )
            } catch { thrown = error }
            check(
                "adapter rejects an invalid Desktop plan",
                (thrown as? SpacesAdapterError) == .invalidDesktopAssignments(
                    bundleIdentifiers: ["com.example.invalid"]
                )
            )
            check(
                "invalid Desktop rejection performs no mutation or preflight",
                runner.writes == 0 && runner.deletes == 0
                    && runner.dockRestarts == 0 && updater.preflights == 0
                    && runner.appBindings == ["com.example.unmanaged": "U1"]
            )
        }

        // A mirror group resolves every member identity to one shared Desktop set,
        // while its primary is the persisted identity for new Assignments.
        do {
            let mirrored = DisplayTopologySnapshot(
                displaysHaveSeparateSpaces: true,
                automaticallyRearrangesSpaces: false,
                sections: [section(primary: builtIn, members: [builtIn, external], main: true, x: 0, desktops: ["M1", "M2"])]
            )
            check("mirror member identity resolves through the shared section", mirrored.concreteDesktopUUID(display: external, desktopNumber: 2) == "M2")
            check("mirrored new-Assignment identity is the mirror primary", mirrored.sections.first?.newAssignmentDisplay.identifiesSameDisplay(as: builtIn) == true)
            check("mirror section title contains every member name", mirrored.sections.first?.displayName == "Built-in Display + Studio Display — Mirrored")

            let app = ManagedApplication(
                bundleIdentifier: "com.example.mirror",
                displayName: "Mirror",
                display: external,
                desktopNumber: 1
            )
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [app]))
            board.markApplied(effectiveDesktopUUIDs: [app.bundleIdentifier: "M1"])
            check("mirroring preserves a member's saved physical identity", board.configuration.managedApplications.first?.display?.identifiesSameDisplay(as: external) == true)

            let primaryApp = ManagedApplication(
                bundleIdentifier: "com.example.mirror.primary",
                displayName: "Primary app",
                display: builtIn,
                desktopNumber: 1,
                layout: app.layout
            )
            let mirroredReports = ArrangeEngine.reportsByAssignedDisplay(
                ArrangeReport(
                    arranged: [primaryApp.bundleIdentifier, app.bundleIdentifier],
                    skipped: [],
                    resisted: []
                ),
                applications: [primaryApp, app]
            )
            check(
                "mirrored Arrange reports remain under each saved physical Display",
                mirroredReports.count == 2
                    && mirroredReports[0].display.identifiesSameDisplay(as: builtIn)
                    && mirroredReports[0].report.arranged == [primaryApp.bundleIdentifier]
                    && mirroredReports[1].display.identifiesSameDisplay(as: external)
                    && mirroredReports[1].report.arranged == [app.bundleIdentifier]
            )
            let unchangedAfterUnmirror = DisplayTopologySnapshot(
                displaysHaveSeparateSpaces: true,
                automaticallyRearrangesSpaces: false,
                sections: [
                    section(primary: builtIn, main: true, x: 0, desktops: ["B1"]),
                    section(primary: external, main: false, x: 1000, desktops: ["M1"]),
                ]
            )
            check("unmirroring with the same effective UUID stays Apply-clean", board.pendingChanges(on: unchangedAfterUnmirror).isEmpty)
            let remintedAfterUnmirror = DisplayTopologySnapshot(
                displaysHaveSeparateSpaces: true,
                automaticallyRearrangesSpaces: false,
                sections: [
                    section(primary: builtIn, main: true, x: 0, desktops: ["B1"]),
                    section(primary: external, main: false, x: 1000, desktops: ["E1"]),
                ]
            )
            check("unmirroring is Apply-pending only when the effective UUID changes", board.pendingChanges(on: remintedAfterUnmirror) == [app.bundleIdentifier])
        }

        // Cross-Display movement changes the Assignment, preserves Layout, and is
        // both Preset-dirty (configuration changed) and Apply-dirty (baseline differs).
        do {
            let layout = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: .single(0),
                rowSpan: .single(0)
            )
            let original = ManagedApplication(
                bundleIdentifier: "com.example.move",
                displayName: "Move",
                display: builtIn,
                desktopNumber: 1,
                layout: layout
            )
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [original]))
            board.move(bundleIdentifier: original.bundleIdentifier, toDisplay: external, desktopNumber: 1)
            let moved = board.configuration.managedApplication(for: original.bundleIdentifier)
            check("cross-Display move changes the physical destination", moved?.display?.identifiesSameDisplay(as: external) == true)
            check("cross-Display move preserves the optional Layout", moved?.layout == layout)
            check("cross-Display move is Apply-pending", board.pendingChanges(on: topology) == [original.bundleIdentifier])
            check("cross-Display move changes the Preset board", board.configuration.hasSameManagedBoard(as: DeskLayouterConfiguration(managedApplications: [original])) == false)

            let encoded = try! BoardStateSerialization.encode(board)
            let relaunched = try! BoardStateSerialization.decode(from: encoded)
            check("relaunch preserves the moved physical Display destination", relaunched.configuration.managedApplication(for: original.bundleIdentifier)?.display?.identifiesSameDisplay(as: external) == true)

            var library = PresetLibrary()
            let builtCompanion = ManagedApplication(
                bundleIdentifier: "com.example.built.preset",
                displayName: "Built preset",
                display: builtIn,
                desktopNumber: 2,
                layout: layout
            )
            let completeBoard = board.configuration.managedApplications + [builtCompanion]
            let preset = try! library.add(name: "Displays", managedApplications: completeBoard)
            let alternate = try! library.add(name: "Alternate", managedApplications: [original])

            var loaded = BoardState()
            loaded.load(configuration: preset.configuration, selectedPresetID: preset.id)
            check(
                "Preset load preserves every physical destination",
                Set(loaded.configuration.managedApplications.compactMap { $0.display?.colorSyncUUID })
                    == [builtIn.colorSyncUUID, external.colorSyncUUID]
            )

            library.update(id: preset.id, managedApplications: loaded.configuration.managedApplications)
            check(
                "Preset update preserves every physical destination",
                Set(library.preset(for: preset.id)?.managedApplications.compactMap { $0.display?.colorSyncUUID } ?? [])
                    == [builtIn.colorSyncUUID, external.colorSyncUUID]
            )

            loaded.move(bundleIdentifier: original.bundleIdentifier, toDisplay: builtIn, desktopNumber: 1)
            let reverted = PresetEditing.revert(to: preset.id, library: library, board: loaded)
            check(
                "Preset revert restores the physical destination",
                reverted.configuration.managedApplication(for: original.bundleIdentifier)?
                    .display?.identifiesSameDisplay(as: external) == true
            )

            let switchedAway = PresetSwitch.discardAndSwitch(
                target: alternate.id,
                board: reverted,
                library: library
            )
            let switchedBack = PresetSwitch.discardAndSwitch(
                target: preset.id,
                board: switchedAway,
                library: library
            )
            check(
                "Preset switch restores every physical destination",
                Set(switchedBack.configuration.managedApplications.compactMap { $0.display?.colorSyncUUID })
                    == [builtIn.colorSyncUUID, external.colorSyncUUID]
            )

            library = try! PresetEditing.rename(
                id: preset.id,
                to: "Renamed Displays",
                library: library,
                persist: { _ in }
            )
            check(
                "Preset rename preserves every physical destination",
                Set(library.preset(for: preset.id)?.managedApplications.compactMap { $0.display?.colorSyncUUID } ?? [])
                    == [builtIn.colorSyncUUID, external.colorSyncUUID]
            )
            let decodedLibrary = try! PresetLibrarySerialization.decode(
                from: PresetLibrarySerialization.encode(library)
            )
            check("Preset create and relaunch preserve every physical destination", decodedLibrary.preset(for: preset.id)?.managedApplications.first?.display?.identifiesSameDisplay(as: external) == true)
        }

        // A Main-role transition is semantic no-op but concrete UUID drift is
        // Apply-pending, without changing the working configuration.
        do {
            let app = ManagedApplication(bundleIdentifier: "com.example.main", displayName: "Main", display: builtIn, desktopNumber: 1)
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [app]))
            board.markApplied(effectiveDesktopUUIDs: [app.bundleIdentifier: "OLD-B1"])
            let changedMain = DisplayTopologySnapshot(
                displaysHaveSeparateSpaces: true,
                automaticallyRearrangesSpaces: false,
                sections: [
                    section(primary: external, main: true, x: 1000, desktops: ["E1", "E2"]),
                    section(primary: builtIn, main: false, x: 0, desktops: ["NEW-B1", "B2"]),
                ]
            )
            check("Main change with UUID drift is Apply-pending", board.pendingChanges(on: changedMain) == [app.bundleIdentifier])
            check("Main change does not edit the Preset board", board.configuration == DeskLayouterConfiguration(managedApplications: [app]))
        }

        // Arrange scopes by both Display and Desktop, uses the destination
        // Display's usable frame, and arms identical Desktop numbers separately.
        do {
            let layout = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: LayoutSpan(start: 0, end: 1),
                rowSpan: LayoutSpan(start: 0, end: 1)
            )
            let builtApp = ManagedApplication(
                bundleIdentifier: "com.example.built.arrange",
                displayName: "Built",
                display: builtIn,
                desktopNumber: 1,
                layout: layout
            )
            let externalApp = ManagedApplication(
                bundleIdentifier: "com.example.external.arrange",
                displayName: "External",
                display: external,
                desktopNumber: 1,
                layout: layout
            )
            let scoped = ArrangeEngine.applications(
                [builtApp, externalApp],
                assignedTo: DesktopAddress(display: external, desktopNumber: 1),
                in: topology
            )
            check("Arrange never includes an app from another Display destination", scoped.map(\.bundleIdentifier) == [externalApp.bundleIdentifier])

            let manipulator = RecordingWindowManipulator()
            let arranger = WindowArranger(
                authorizer: TrustedAuthorizer(),
                windowManipulator: manipulator,
                screenGeometry: PerDisplayGeometry(
                    primaryDisplayHeight: 800,
                    frames: [
                        builtIn.colorSyncUUID: CGRect(x: 0, y: 0, width: 1000, height: 800),
                        external.colorSyncUUID: CGRect(x: 1000, y: 0, width: 1200, height: 800),
                    ]
                )
            )
            _ = try! arranger.arrange(managedApplications: scoped, on: external)
            check(
                "Arrange uses the destination Display's usable area",
                manipulator.moves.first?.1 == CGRect(x: 1000, y: 0, width: 1200, height: 800),
                "got \(String(describing: manipulator.moves.first?.1))"
            )

            var plan = MultiDisplayArrangePlan()
            let builtDesktop2 = DesktopAddress(display: builtIn, desktopNumber: 2)
            let externalDesktop2 = DesktopAddress(display: external, desktopNumber: 2)
            check(
                "other Display/Desktop destinations arm after the immediate pass",
                plan.press(
                    destinationsWithLayouts: [builtDesktop2, externalDesktop2],
                    visibleDestinations: []
                )
            )
            let completed = plan.completeVisible([externalDesktop2])
            check(
                "first visit completes only the exact physical Display/Desktop",
                completed == [externalDesktop2] && plan.armedDestinations == [builtDesktop2]
            )

            let announcement = ArrangeReportPresenter.announce(
                displayName: external.lastKnownName,
                desktopNumber: 1,
                arranged: [externalApp.displayName],
                skipped: [],
                resisted: []
            )
            check("Arrange report names physical Display and Desktop", announcement.message.contains("Studio Display, Desktop 1"))
        }

        // Projection creates visually ordered Display sections and keeps cards in
        // their physical destination even when Desktop numbers are identical.
        do {
            let reversedInput = DisplayTopologySnapshot(
                displaysHaveSeparateSpaces: true,
                automaticallyRearrangesSpaces: false,
                sections: [
                    section(primary: external, main: false, x: 1000, desktops: ["E1"]),
                    section(primary: builtIn, main: true, x: 0, desktops: ["B1"]),
                ]
            )
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.b", displayName: "B", display: builtIn, desktopNumber: 1),
                ManagedApplication(bundleIdentifier: "com.example.e", displayName: "E", display: external, desktopNumber: 1),
            ]))
            let projection = board.projection(on: reversedInput, installedBundleIdentifiers: ["com.example.b", "com.example.e"])
            check("Display sections are ordered by visual arrangement", projection.sections.map(\.display.colorSyncUUID) == [builtIn.colorSyncUUID, external.colorSyncUUID])
            check("cards remain under their physical Display", projection.sections.map { $0.availableColumns[0].cards.map(\.bundleIdentifier) } == [["com.example.b"], ["com.example.e"]])
        }

        if failures.isEmpty {
            print("Multi-display tests passed")
        } else {
            fatalError("Multi-display tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
