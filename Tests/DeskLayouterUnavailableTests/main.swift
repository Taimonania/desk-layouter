import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

// Verifies issue #52: a loaded Preset that references an application which is not
// installed, or a Desktop number that no longer exists, must keep every
// Assignment visible, stored, and recoverable — never silently omitted, deleted,
// clamped, or reassigned. The pure surfacing/gating logic lives in
// `BoardState.projection(desktopCount:installedBundleIdentifiers:)` and
// `BoardProjection`, exercised here without any AppKit / macOS dependency.
// Hand-rolled @main runner, no XCTest — matching the other test targets.

@main
struct UnavailableTestRunner {
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

        func app(_ name: String, _ bundle: String, desktop: Int, layout: Layout? = nil) -> ManagedApplication {
            ManagedApplication.legacy(bundleIdentifier: bundle, displayName: name, desktopNumber: desktop, layout: layout)
        }

        func installed(_ bundles: String...) -> Set<String> { Set(bundles) }

        // A card assigned beyond the current Desktop count stays visible under an
        // "Unavailable Desktop N" section rather than vanishing; the available
        // columns cover exactly the Desktops that exist.
        do {
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                    app("Mailer", "com.example.Mailer", desktop: 3),
                ])
            )
            let projection = board.projection(
                desktopCount: 2,
                installedBundleIdentifiers: installed("com.example.Writer", "com.example.Mailer")
            )
            check("available columns cover exactly the existing Desktops", projection.availableColumns.map(\.number) == [1, 2], "got \(projection.availableColumns.map(\.number))")
            check("a too-high Desktop surfaces one unavailable section", projection.unavailableDesktops.map(\.desktopNumber) == [3], "got \(projection.unavailableDesktops.map(\.desktopNumber))")
            check("the stranded card is preserved in its unavailable section", projection.unavailableDesktops.first?.cards.map(\.bundleIdentifier) == ["com.example.Mailer"])
            check("the unavailable section is clearly labeled with its Desktop number", projection.unavailableDesktops.first?.title == "Unavailable Desktop 3", "got \(projection.unavailableDesktops.first?.title ?? "nil")")
            check("an out-of-range Assignment disables Apply via the projection", projection.hasUnavailableDesktopAssignments)
            check("the available columns do not inflate their counts with the stranded card", projection.availableColumns.map(\.assignmentCount) == [1, 0], "got \(projection.availableColumns.map(\.assignmentCount))")
        }

        // Multiple distinct unavailable Desktops each get their own section, in
        // ascending order, and every stranded card is retained.
        do {
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("A", "com.a", desktop: 5),
                    app("B", "com.b", desktop: 3),
                    app("C", "com.c", desktop: 3),
                    app("D", "com.d", desktop: 1),
                ])
            )
            let projection = board.projection(
                desktopCount: 2,
                installedBundleIdentifiers: installed("com.a", "com.b", "com.c", "com.d")
            )
            check("multiple unavailable Desktops each surface, ascending", projection.unavailableDesktops.map(\.desktopNumber) == [3, 5], "got \(projection.unavailableDesktops.map(\.desktopNumber))")
            check("unavailable Desktop numbers are exposed for feedback", projection.unavailableDesktopNumbers == [3, 5])
            check("both cards stranded on the same Desktop are kept together", projection.unavailableDesktops.first?.cards.map(\.bundleIdentifier) == ["com.b", "com.c"], "got \(projection.unavailableDesktops.first?.cards.map(\.bundleIdentifier) ?? [])")
            let allSurfaced = projection.availableColumns.flatMap(\.cards).count + projection.unavailableDesktops.flatMap(\.cards).count
            check("no Assignment is dropped: every card is surfaced somewhere", allSurfaced == 4, "got \(allSurfaced)")
        }

        // Cards on an unavailable Desktop retain their application identity and
        // optional Layout, so the move controls and Layout editor keep working.
        do {
            let layout = Layout(
                horizontalDivision: .halves,
                verticalDivision: .full,
                columnSpan: LayoutSpan(start: 0, end: 0),
                rowSpan: LayoutSpan(start: 0, end: 0)
            )
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Mailer", "com.example.Mailer", desktop: 4, layout: layout),
                ])
            )
            let projection = board.projection(desktopCount: 1, installedBundleIdentifiers: installed("com.example.Mailer"))
            let stranded = projection.unavailableDesktops.first?.cards.first
            check("a stranded card keeps its identity", stranded?.bundleIdentifier == "com.example.Mailer")
            check("a stranded card keeps its Desktop number", stranded?.desktopNumber == 4)
            check("a stranded card keeps its Layout", stranded?.layout == layout)
            check("a stranded card reports it has a Layout", stranded?.hasLayout == true)
        }

        // Moving a stranded card back to an available Desktop recovers it: the
        // board's move transition works from an out-of-range source, and the next
        // projection shows it in the available column with no unavailable sections.
        do {
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Mailer", "com.example.Mailer", desktop: 5),
                ])
            )
            board.move(bundleIdentifier: "com.example.Mailer", toDesktop: 2)
            let projection = board.projection(desktopCount: 3, installedBundleIdentifiers: installed("com.example.Mailer"))
            check("moving off an unavailable Desktop clears the unavailable sections", projection.unavailableDesktops.isEmpty)
            check("the recovered card lands in the chosen available Desktop", projection.availableColumns[1].cards.map(\.bundleIdentifier) == ["com.example.Mailer"], "got \(projection.availableColumns[1].cards.map(\.bundleIdentifier))")
            check("recovering re-enables Apply (no unavailable Desktop remains)", projection.hasUnavailableDesktopAssignments == false)
        }

        // The move transition both drag-and-drop and the keyboard arrow controls
        // funnel through must reach a card stranded on an unavailable Desktop. The
        // card is located in the working configuration (the single source of
        // truth) — not in the projected available columns — so keyboard move works
        // for stranded cards, and the move preserves the card's identity and
        // Layout while recovering it onto an available Desktop.
        do {
            let layout = Layout(
                horizontalDivision: .halves,
                verticalDivision: .full,
                columnSpan: LayoutSpan(start: 1, end: 1),
                rowSpan: LayoutSpan(start: 0, end: 0)
            )
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Mailer", "com.example.Mailer", desktop: 8, layout: layout),
                ])
            )
            check("a stranded card is found in the working configuration, not just the columns", board.configuration.managedApplication(for: "com.example.Mailer")?.desktopNumber == 8)
            // Emulate a keyboard move off the unavailable Desktop (the transition
            // the arrow controls invoke once the target is clamped into range).
            board.move(bundleIdentifier: "com.example.Mailer", toDesktop: 2)
            let moved = board.configuration.managedApplication(for: "com.example.Mailer")
            check("keyboard-moving a stranded card lands it on an available Desktop", moved?.desktopNumber == 2)
            check("keyboard-moving a stranded card preserves its Layout", moved?.layout == layout)
            let projection = board.projection(desktopCount: 3, installedBundleIdentifiers: installed("com.example.Mailer"))
            check("after a keyboard move no unavailable Desktop remains", projection.hasUnavailableDesktopAssignments == false)
            check("the recovered card appears in the available column with its Layout", projection.availableColumns[1].cards.first?.layout == layout)
        }

        // A managed application absent from the installed catalog stays visible on
        // its (available) Desktop with its stored display name, clearly flagged
        // unavailable — and does NOT by itself disable Apply.
        do {
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Installed", "com.installed", desktop: 1),
                    app("Gone", "com.gone", desktop: 1),
                ])
            )
            let projection = board.projection(desktopCount: 2, installedBundleIdentifiers: installed("com.installed"))
            let cards = projection.availableColumns[0].cards
            let gone = cards.first { $0.bundleIdentifier == "com.gone" }
            check("a missing application stays visible on its Desktop", gone != nil)
            check("a missing application keeps its stored display name", gone?.displayName == "Gone")
            check("a missing application is flagged unavailable", gone?.isApplicationAvailable == false)
            check("an installed application is not flagged unavailable", cards.first { $0.bundleIdentifier == "com.installed" }?.isApplicationAvailable == true)
            check("a missing application does not by itself disable Apply", projection.hasUnavailableDesktopAssignments == false)
        }

        // Reinstalling an app: the same stored configuration, projected against a
        // catalog that now includes the bundle id, shows the app available again
        // WITHOUT the configuration having been recreated or mutated.
        do {
            let configuration = DeskLayouterConfiguration(managedApplications: [
                app("Gone", "com.gone", desktop: 1),
            ])
            let board = BoardState(configuration: configuration)
            let before = board.projection(desktopCount: 1, installedBundleIdentifiers: installed())
            let after = board.projection(desktopCount: 1, installedBundleIdentifiers: installed("com.gone"))
            check("while uninstalled the card is flagged unavailable", before.availableColumns[0].cards.first?.isApplicationAvailable == false)
            check("once reinstalled the same card is available again", after.availableColumns[0].cards.first?.isApplicationAvailable == true)
            check("reinstalling does not recreate or mutate the stored Assignment", board.configuration == configuration)
        }

        // A returning Desktop: the same stored configuration, projected against a
        // larger Desktop count, moves the stranded card into an available column
        // with no unavailable section — again without mutating the configuration.
        do {
            let configuration = DeskLayouterConfiguration(managedApplications: [
                app("Mailer", "com.example.Mailer", desktop: 3),
            ])
            let board = BoardState(configuration: configuration)
            let fewer = board.projection(desktopCount: 2, installedBundleIdentifiers: installed("com.example.Mailer"))
            let more = board.projection(desktopCount: 3, installedBundleIdentifiers: installed("com.example.Mailer"))
            check("while the Desktop is gone the card is stranded", fewer.hasUnavailableDesktopAssignments)
            check("once the Desktop returns the card is available again", more.hasUnavailableDesktopAssignments == false)
            check("the returned card lands on its original Desktop", more.availableColumns[2].cards.map(\.bundleIdentifier) == ["com.example.Mailer"])
            check("a returning Desktop does not recreate or mutate the stored Assignment", board.configuration == configuration)
        }

        // Both dimensions at once: a missing app stranded on a missing Desktop is
        // surfaced in the unavailable section AND flagged unavailable, and blocks
        // Apply (because of the Desktop, not the app).
        do {
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("GhostOnGhost", "com.ghost", desktop: 9),
                ])
            )
            let projection = board.projection(desktopCount: 2, installedBundleIdentifiers: installed())
            let card = projection.unavailableDesktops.first?.cards.first
            check("a missing app on a missing Desktop is surfaced", card?.bundleIdentifier == "com.ghost")
            check("a missing app on a missing Desktop is flagged unavailable", card?.isApplicationAvailable == false)
            check("a missing app on a missing Desktop still blocks Apply (via the Desktop)", projection.hasUnavailableDesktopAssignments)
        }

        // Persistence round trip: a board carrying an out-of-range Assignment and a
        // (soon-to-be) missing app survives encode/decode with every managed
        // application intact — nothing dropped or clamped by serialization — and
        // projects identically after the round trip.
        do {
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                    app("Mailer", "com.example.Mailer", desktop: 7),
                    app("Gone", "com.gone", desktop: 1),
                ])
            )
            let data = try! BoardStateSerialization.encode(board)
            let restored = try! BoardStateSerialization.decode(from: data)
            check("serialization preserves every managed application", restored.configuration.managedApplications.count == 3, "got \(restored.configuration.managedApplications.count)")
            check("serialization preserves the out-of-range Desktop number", restored.configuration.managedApplication(for: "com.example.Mailer")?.desktopNumber == 7)
            let projection = restored.projection(desktopCount: 2, installedBundleIdentifiers: installed("com.example.Writer"))
            check("after a round trip the stranded Assignment still surfaces", projection.unavailableDesktops.map(\.desktopNumber) == [7])
            check("after a round trip the missing app is still flagged", projection.availableColumns[0].cards.first { $0.bundleIdentifier == "com.gone" }?.isApplicationAvailable == false)
        }

        // Loading a Preset that references a removed Desktop must not drop the
        // stranded Assignment: after load the working configuration still contains
        // it and it projects into an unavailable section.
        do {
            let preset = Preset(
                name: "Focus",
                managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                    app("Mailer", "com.example.Mailer", desktop: 6),
                ]
            )
            var board = BoardState()
            board.load(configuration: preset.configuration, selectedPresetID: preset.id)
            check("loading preserves the stranded Assignment in the working copy", board.configuration.managedApplication(for: "com.example.Mailer")?.desktopNumber == 6)
            let projection = board.projection(desktopCount: 2, installedBundleIdentifiers: installed("com.example.Writer", "com.example.Mailer"))
            check("a loaded stranded Assignment surfaces as unavailable", projection.unavailableDesktops.map(\.desktopNumber) == [6])
        }

        // With no Desktops resolved the projection produces no columns and no
        // unavailable sections (the display-resolution error state), but the stored
        // Assignments are untouched — nothing is dropped from the configuration.
        do {
            let configuration = DeskLayouterConfiguration(managedApplications: [
                app("Writer", "com.example.Writer", desktop: 1),
                app("Mailer", "com.example.Mailer", desktop: 3),
            ])
            let board = BoardState(configuration: configuration)
            let projection = board.projection(desktopCount: 0, installedBundleIdentifiers: installed("com.example.Writer"))
            check("no resolved Desktops yields no columns", projection.availableColumns.isEmpty)
            check("no resolved Desktops yields no unavailable sections", projection.unavailableDesktops.isEmpty)
            check("no resolved Desktops leaves the stored configuration intact", board.configuration == configuration)
        }

        // Arrange-skipping data shape: a managed app that is not installed but has a
        // valid Layout is still an Arrange candidate (availability is a runtime
        // window concern the engine resolves by finding no window and skipping —
        // it is never filtered out of the managed board here), so the Assignment is
        // preserved rather than removed.
        do {
            let layout = Layout(
                horizontalDivision: .full,
                verticalDivision: .full,
                columnSpan: LayoutSpan(start: 0, end: 0),
                rowSpan: LayoutSpan(start: 0, end: 0)
            )
            let managed = [
                app("Available", "com.available", desktop: 1, layout: layout),
                app("Missing", "com.missing", desktop: 1, layout: layout),
            ]
            let candidates = ArrangeEngine.candidates(from: managed)
            check("Arrange candidates are chosen by Layout, not installation status", candidates.map(\.bundleIdentifier) == ["com.available", "com.missing"], "got \(candidates.map(\.bundleIdentifier))")
        }

        if failures.isEmpty {
            print("Unavailable Preset apps/Desktops tests passed")
        } else {
            fatalError("Unavailable Preset apps/Desktops tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
