import DeskLayouterCore
import Foundation

private let builtIn = DisplayIdentity(
    colorSyncUUID: "BUILT-IN",
    lastKnownName: "Built-in Display",
    vendorID: 1,
    modelID: 10,
    serialNumber: 100
)
private let external = DisplayIdentity(
    colorSyncUUID: "EXTERNAL-OLD",
    lastKnownName: "Studio Display",
    vendorID: 2,
    modelID: 20,
    serialNumber: 200
)

private func section(
    _ display: DisplayIdentity,
    members: [DisplayIdentity]? = nil,
    main: Bool = false,
    desktops: [String]
) -> DisplayDesktopSectionSnapshot {
    DisplayDesktopSectionSnapshot(
        primaryDisplay: display,
        memberDisplays: members ?? [display],
        isMain: main,
        bounds: DisplayBounds(x: main ? 0 : 1000, y: 0, width: 1000, height: 800),
        orderedDesktopUUIDs: desktops
    )
}

private func topology(_ sections: [DisplayDesktopSectionSnapshot]) -> DisplayTopologySnapshot {
    DisplayTopologySnapshot(
        displaysHaveSeparateSpaces: true,
        automaticallyRearrangesSpaces: false,
        sections: sections
    )
}

private let layout = Layout(
    horizontalDivision: .halves,
    verticalDivision: .full,
    columnSpan: LayoutSpan(start: 0, end: 0),
    rowSpan: LayoutSpan(start: 0, end: 0)
)

private func app(
    _ bundleIdentifier: String,
    display: DisplayIdentity,
    desktop: Int,
    layout: Layout? = nil
) -> ManagedApplication {
    ManagedApplication(
        bundleIdentifier: bundleIdentifier,
        displayName: bundleIdentifier,
        display: display,
        desktopNumber: desktop,
        layout: layout
    )
}

@main
struct UnavailableDisplayTestRunner {
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

        let connected = topology([section(builtIn, main: true, desktops: ["B1", "B2"])])

        // Disconnect/reconnect is a projection-only availability change. The
        // persisted Assignment and Layout remain byte-for-byte semantic state.
        do {
            let configuration = DeskLayouterConfiguration(managedApplications: [
                app("com.example.connected", display: builtIn, desktop: 1),
                app("com.example.offline", display: external, desktop: 2, layout: layout),
            ])
            let board = BoardState(configuration: configuration)
            let disconnected = board.projection(on: connected, installedBundleIdentifiers: [])
            check("disconnected Display has a clearly separated unavailable section", disconnected.unavailableDisplays.count == 1)
            check("unavailable section keeps physical identity", disconnected.unavailableDisplays.first?.display == external)
            check("unavailable section keeps Assignment and Layout", disconnected.unavailableDisplays.first?.cards.first?.layout == layout)
            check("availability does not mutate persisted board", board.configuration == configuration)

            let reconnected = board.projection(
                on: topology([
                    section(builtIn, main: true, desktops: ["B1", "B2"]),
                    section(external, desktops: ["E1", "E2"]),
                ]),
                installedBundleIdentifiers: []
            )
            check("exact identity reconnect restores normal Display section", reconnected.unavailableDisplays.isEmpty && reconnected.sections.count == 2)
            check("reconnect does not rewrite Assignment identity", board.configuration.managedApplication(for: "com.example.offline")?.display == external)
        }

        // Planning distinguishes an unavailable Display (preserve) from an
        // unavailable Desktop on a connected Display (block the whole Apply).
        do {
            let configuration = DeskLayouterConfiguration(
                managedApplications: [
                    app("com.example.update", display: builtIn, desktop: 2),
                    app("com.example.offline", display: external, desktop: 1),
                    app("com.example.invalid", display: builtIn, desktop: 9),
                ],
                pendingRemovals: ["com.example.removed"]
            )
            let plan = AssignmentPlanner().applyPlan(configuration: configuration, on: connected)
            check("Apply plan contains resolvable update", plan.updates == ["com.example.update": "B2"])
            check("Apply plan distinguishes explicit deletion", plan.deletions == ["com.example.removed"])
            check("Apply plan preserves only unavailable Display", plan.preservations == ["com.example.offline"], "got \(plan.preservations)")
            check("Apply plan blocks connected unavailable Desktop", plan.invalidDesktopAssignments == ["com.example.invalid"])
            check("invalid Desktop makes plan non-mutable", !plan.canMutate)
        }

        // A topology-only disconnect never invents an Apply edit. Real semantic
        // edits on an unavailable Assignment remain pending for later recovery.
        do {
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [
                app("com.example.offline", display: external, desktop: 1),
            ]))
            board.markApplied(effectiveDesktopUUIDs: ["com.example.offline": "E1"])
            check("disconnect alone does not dirty board", board.pendingChanges(on: connected).isEmpty)
            board.move(bundleIdentifier: "com.example.offline", toDesktop: 2)
            check("offline semantic edit remains pending", board.pendingChanges(on: connected) == ["com.example.offline"])
        }

        // Recovery is offered only for one different connected identity matching
        // a complete, nonzero hardware tuple, and never applied until confirmed.
        do {
            let replacement = DisplayIdentity(
                colorSyncUUID: "EXTERNAL-NEW",
                lastKnownName: "Studio Display",
                vendorID: 2,
                modelID: 20,
                serialNumber: 200
            )
            let recoveryTopology = topology([
                section(builtIn, main: true, desktops: ["B1"]),
                section(replacement, desktops: ["E1", "E2"]),
            ])
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [
                app("com.example.offline", display: external, desktop: 2, layout: layout),
            ]))
            let suggestion = recoveryTopology.recoveryCandidate(for: external)
            check("unique nonzero hardware identity offers recovery", suggestion == replacement)
            check("an exact connected identity never offers recovery", recoveryTopology.recoveryCandidate(for: replacement) == nil)
            check("recovery is not silently accepted", board.configuration.managedApplication(for: "com.example.offline")?.display == external)
            board.recoverDisplay(external, as: replacement)
            let recovered = board.configuration.managedApplication(for: "com.example.offline")
            check("confirmed recovery replaces saved identity", recovered?.display == replacement)
            check("confirmed recovery preserves Desktop and Layout", recovered?.desktopNumber == 2 && recovered?.layout == layout)
            check("confirmed recovery is a pending semantic edit", board.pendingChanges(on: recoveryTopology) == ["com.example.offline"])

            let zeroSerial = DisplayIdentity(
                colorSyncUUID: "ZERO-OLD",
                lastKnownName: "Unknown",
                vendorID: 2,
                modelID: 20,
                serialNumber: 0
            )
            check("zero hardware identity remains ambiguous", recoveryTopology.recoveryCandidate(for: zeroSerial) == nil)

            let duplicate = DisplayIdentity(
                colorSyncUUID: "EXTERNAL-NEW-2",
                lastKnownName: "Studio Display 2",
                vendorID: 2,
                modelID: 20,
                serialNumber: 200
            )
            let duplicateTopology = topology([
                section(replacement, main: true, desktops: ["E1"]),
                section(duplicate, desktops: ["D1"]),
            ])
            check("duplicate hardware matches remain ambiguous", duplicateTopology.recoveryCandidate(for: external) == nil)

            let missingSerial = DisplayIdentity(
                colorSyncUUID: "MISSING-OLD",
                lastKnownName: "Unknown",
                vendorID: 2,
                modelID: 20,
                serialNumber: nil
            )
            check("missing hardware identity remains ambiguous", recoveryTopology.recoveryCandidate(for: missingSerial) == nil)

            let duplicateExact = topology([
                section(external, main: true, desktops: ["A1"]),
                section(external, desktops: ["A2"]),
            ])
            let ambiguous = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [
                app("com.example.ambiguous", display: external, desktop: 1),
            ])).projection(on: duplicateExact, installedBundleIdentifiers: [])
            check("non-unique exact identity is surfaced as unavailable", ambiguous.unavailableDisplays.count == 1)
        }

        // Explicit reassignment is the existing board transition: it preserves
        // Layout, changes dirty state, and has no Apply/Arrange side effect.
        do {
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [
                app("com.example.offline", display: external, desktop: 1, layout: layout),
            ]))
            board.move(bundleIdentifier: "com.example.offline", toDisplay: builtIn, desktopNumber: 2)
            let moved = board.configuration.managedApplication(for: "com.example.offline")
            check("unavailable Assignment can be explicitly reassigned", moved?.display == builtIn && moved?.desktopNumber == 2)
            check("reassignment preserves Layout", moved?.layout == layout)
            check("reassignment changes working dirty state", board.pendingChanges == ["com.example.offline"])
        }

        do {
            let message = ArrangeReportPresenter.unavailableDisplaysMessage([
                "Travel Display", "Studio Display", "Travel Display",
            ])
            check(
                "Arrange skip report names every unavailable Display deterministically",
                message == "Skipped Layouts on unavailable Displays: Studio Display and Travel Display.",
                "got \(message)"
            )
        }

        // Removing an unavailable Assignment produces only its explicit deletion;
        // reconciliation leaves unrelated unmanaged and preserved keys alone.
        do {
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [
                app("com.example.offline", display: external, desktop: 1),
            ]))
            board.remove(bundleIdentifier: "com.example.offline")
            let plan = AssignmentPlanner().applyPlan(configuration: board.configuration, on: connected)
            let result = PersistentBindingReconciler.completeBindings(
                existing: ["com.example.offline": "OLD", "com.example.unmanaged": "U1"],
                updates: plan.updates,
                deletions: plan.deletions
            )
            check("offline explicit removal is a deletion", plan.deletions == ["com.example.offline"])
            check("offline explicit removal deletes only owned binding", result == ["com.example.unmanaged": "U1"])
        }

        do {
            let available = app("com.example.available", display: builtIn, desktop: 1)
            let offline = app("com.example.offline", display: external, desktop: 1)
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [available, offline]))
            board.markApplied(effectiveDesktopUUIDs: [
                available.bundleIdentifier: "OLD-B1",
                offline.bundleIdentifier: "E1",
            ])
            board.move(bundleIdentifier: available.bundleIdentifier, toDesktop: 2)
            board.move(bundleIdentifier: offline.bundleIdentifier, toDesktop: 2)
            let plan = AssignmentPlanner().applyPlan(configuration: board.configuration, on: connected)
            board.markApplied(plan)
            check("partial Apply advances available Assignment only", board.pendingChanges(on: connected) == [offline.bundleIdentifier])
            check("partial Apply retains unavailable concrete baseline", board.appliedAssignments[offline.bundleIdentifier]?.concreteDesktopUUID == "E1")
        }

        do {
            let plan = AssignmentPlanner().applyPlan(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("com.example.available", display: builtIn, desktop: 1),
                    app("com.example.offline", display: external, desktop: 2),
                ]),
                on: connected
            )
            check(
                "unchanged available bindings do not make an offline-only edit applicable",
                !plan.hasResolvableMutation(pendingBundleIdentifiers: ["com.example.offline"])
            )
            check(
                "a pending available update makes the mixed plan applicable",
                plan.hasResolvableMutation(pendingBundleIdentifiers: ["com.example.available", "com.example.offline"])
            )
        }

        // Mirror/lid/Main/topology refreshes are pure projections over the same
        // working state: pending edits and Preset association survive each shape.
        do {
            let presetID = UUID()
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("com.example.pending", display: external, desktop: 1),
                ]),
                selectedPresetID: presetID
            )
            board.move(bundleIdentifier: "com.example.pending", toDesktop: 2)
            let shapes = [
                topology([section(builtIn, main: true, desktops: ["B1"])]),
                topology([section(builtIn, members: [builtIn, external], main: true, desktops: ["M1", "M2"])]),
                topology([section(external, main: true, desktops: ["E1", "E2"])]),
            ]
            for shape in shapes { _ = board.projection(on: shape, installedBundleIdentifiers: []) }
            check("topology refresh preserves pending edit", board.configuration.managedApplication(for: "com.example.pending")?.desktopNumber == 2)
            check("topology refresh preserves Preset association", board.selectedPresetID == presetID)
        }

        if failures.isEmpty {
            print("Unavailable Display tests passed")
        } else {
            fatalError("Unavailable Display tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
