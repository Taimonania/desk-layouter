import DeskLayouterCore
import Foundation

@main
struct BoardStateTestRunner {
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

        func app(_ name: String, _ bundle: String, desktop: Int) -> ManagedApplication {
            ManagedApplication(bundleIdentifier: bundle, displayName: name, desktopNumber: desktop)
        }

        // Clean: a board whose working configuration matches the applied baseline
        // has no pending changes and disables Apply. A freshly loaded, previously
        // applied configuration is clean, not falsely dirty.
        do {
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                    app("Reader", "com.example.Reader", desktop: 2),
                ])
            )
            check("clean board reports no pending changes", board.pendingChangeCount == 0, "got \(board.pendingChangeCount)")
            check("clean board is not dirty", board.isDirty == false)
        }

        // Columns: the board projects one column per Desktop in positional order,
        // each carrying its cards and Assignment count. Empty Desktops still get a
        // column so the board stays usable with more Desktops than Assignments.
        do {
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                    app("Reader", "com.example.Reader", desktop: 1),
                    app("Mailer", "com.example.Mailer", desktop: 3),
                ])
            )
            let columns = board.columns(desktopCount: 3)
            check("board renders one column per Desktop in order", columns.map(\.number) == [1, 2, 3], "got \(columns.map(\.number))")
            check("column reports its Assignment count", columns.map(\.assignmentCount) == [2, 0, 1], "got \(columns.map(\.assignmentCount))")
            check(
                "cards carry bundle id and display name",
                columns[0].cards.map(\.bundleIdentifier) == ["com.example.Writer", "com.example.Reader"],
                "got \(columns[0].cards.map(\.bundleIdentifier))"
            )
        }

        // Columns: the board handles fewer or more than three Desktops without
        // trapping, and yields no columns when there are none.
        do {
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                ])
            )
            check("board renders a single Desktop", board.columns(desktopCount: 1).map(\.number) == [1])
            check("board renders five Desktops", board.columns(desktopCount: 5).map(\.number) == [1, 2, 3, 4, 5])
            check("board renders no columns when there are no Desktops", board.columns(desktopCount: 0).isEmpty)
        }

        // Columns: an Assignment referencing a Desktop that no longer exists is
        // left out of every column rather than trapping, and does not inflate any
        // count.
        do {
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                    app("Ghost", "com.example.Ghost", desktop: 9),
                ])
            )
            let columns = board.columns(desktopCount: 2)
            check("stale Desktop reference is not rendered", columns.map(\.assignmentCount) == [1, 0], "got \(columns.map(\.assignmentCount))")
        }

        // Add: assigning a new application makes the board dirty with exactly one
        // pending change and places the card in the chosen Desktop's column.
        do {
            var board = BoardState()
            board.assign(app("Writer", "com.example.Writer", desktop: 2))
            check("adding an application yields one pending change", board.pendingChangeCount == 1, "got \(board.pendingChangeCount)")
            check("adding an application makes the board dirty", board.isDirty)
            let columns = board.columns(desktopCount: 3)
            check("added card lands in the chosen Desktop", columns[1].cards.map(\.bundleIdentifier) == ["com.example.Writer"], "got \(columns[1].cards)")
        }

        // Move: moving a card to another Desktop is one pending change and updates
        // both the source and destination column counts.
        do {
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                    app("Reader", "com.example.Reader", desktop: 1),
                ])
            )
            board.move(bundleIdentifier: "com.example.Writer", toDesktop: 2)
            check("moving a card yields one pending change", board.pendingChangeCount == 1, "got \(board.pendingChangeCount)")
            let columns = board.columns(desktopCount: 2)
            check("move updates both Desktop counts", columns.map(\.assignmentCount) == [1, 1], "got \(columns.map(\.assignmentCount))")
            check("moved card carries its new Desktop", columns[1].cards.first?.desktopNumber == 2, "got \(String(describing: columns[1].cards.first?.desktopNumber))")
        }

        // Move: moving to the Desktop the card already occupies changes nothing,
        // and moving an unmanaged bundle identifier is a harmless no-op.
        do {
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                ])
            )
            board.move(bundleIdentifier: "com.example.Writer", toDesktop: 1)
            board.move(bundleIdentifier: "com.example.Unknown", toDesktop: 2)
            check("no-op moves leave the board clean", board.pendingChangeCount == 0, "got \(board.pendingChangeCount)")
        }

        // Remove: removing a card is one pending change, drops only that card, and
        // leaves every unrelated Assignment in place.
        do {
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                    app("Reader", "com.example.Reader", desktop: 2),
                ])
            )
            board.remove(bundleIdentifier: "com.example.Writer")
            check("removing a card yields one pending change", board.pendingChangeCount == 1, "got \(board.pendingChangeCount)")
            let columns = board.columns(desktopCount: 2)
            check("remove drops only the named card", columns.flatMap { $0.cards.map(\.bundleIdentifier) } == ["com.example.Reader"], "got \(columns.flatMap { $0.cards })")
            check("removed app is remembered for deletion on Apply", board.configuration.ownedBundleIdentifiers.contains("com.example.Writer"))
        }

        // Apply success: after the adapter has written the bindings, marking the
        // board applied advances the baseline so the board becomes clean and the
        // pending removals are cleared.
        do {
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                ])
            )
            board.assign(app("Reader", "com.example.Reader", desktop: 2))
            board.remove(bundleIdentifier: "com.example.Writer")
            check("board is dirty before Apply", board.pendingChangeCount == 2, "got \(board.pendingChangeCount)")
            board.markApplied()
            check("Apply success clears pending changes", board.pendingChangeCount == 0, "got \(board.pendingChangeCount)")
            check("Apply success clears pending removals", board.configuration.pendingRemovals.isEmpty)
            check("Apply success leaves the board not dirty", board.isDirty == false)
        }

        // Apply failure: when Apply throws, the board is NOT marked applied, so it
        // stays dirty with its pending changes intact and can be retried. This
        // mirrors the model calling markApplied() only on the adapter's success.
        do {
            var board = BoardState()
            board.assign(app("Writer", "com.example.Writer", desktop: 1))
            let pendingBefore = board.pendingChanges
            // Simulate an Apply that fails inside the adapter: markApplied() is
            // never reached, so no state transition happens.
            check("Apply failure leaves the board dirty", board.isDirty)
            check("Apply failure preserves the pending changes", board.pendingChanges == pendingBefore, "got \(board.pendingChanges)")
            check("Apply failure preserves the working configuration", board.configuration.managedApplications.count == 1)
        }

        // Persistence: the board state round-trips through serialization so the
        // pending-versus-applied distinction survives relaunch. A dirty board
        // stays dirty; a clean board stays clean.
        do {
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                ])
            )
            board.move(bundleIdentifier: "com.example.Writer", toDesktop: 3)
            let decoded = try? BoardStateSerialization.decode(from: BoardStateSerialization.encode(board))
            check("board state round-trips through serialization", decoded == board, "got \(String(describing: decoded))")
            check("a reloaded dirty board is still dirty", decoded?.isDirty == true)
        }

        // Persistence: a legacy document without an explicit baseline decodes as
        // clean rather than falsely dirty.
        do {
            let legacyJSON = Data(#"{"configuration":{"managedApplications":[{"bundleIdentifier":"com.example.A","displayName":"A","desktopNumber":1}]}}"#.utf8)
            let decoded = try? BoardStateSerialization.decode(from: legacyJSON)
            check("a board document without a baseline decodes as clean", decoded?.isDirty == false, "got \(String(describing: decoded?.pendingChanges))")
        }

        // Layout: setting a Layout on a managed app persists it on the card and
        // marks it as having a Layout, but does NOT create a pending Assignment
        // change — Layout is enacted by Arrange, not Apply.
        do {
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                ])
            )
            let layout = Layout(
                horizontalDivision: .thirds,
                verticalDivision: .halves,
                columnSpan: .single(2),
                rowSpan: .single(0)
            )
            board.setLayout(layout, forBundleIdentifier: "com.example.Writer")
            let card = board.columns(desktopCount: 1)[0].cards.first
            check("setting a Layout attaches it to the card", card?.layout == layout, "got \(String(describing: card?.layout))")
            check("card reports it has a Layout", card?.hasLayout == true)
            check("setting a Layout does not add a pending Assignment change", board.pendingChangeCount == 0, "got \(board.pendingChangeCount)")
        }

        // Layout: clearing returns the app to no Layout, and the card is again
        // distinguishable as having no Layout. Moving a card preserves its Layout.
        do {
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                ])
            )
            let layout = Layout(horizontalDivision: .halves, verticalDivision: .halves, columnSpan: .single(0), rowSpan: .single(0))
            board.setLayout(layout, forBundleIdentifier: "com.example.Writer")
            board.move(bundleIdentifier: "com.example.Writer", toDesktop: 2)
            check("moving a card keeps its Layout", board.columns(desktopCount: 2)[1].cards.first?.layout == layout)
            board.setLayout(nil, forBundleIdentifier: "com.example.Writer")
            let card = board.columns(desktopCount: 2)[1].cards.first
            check("clearing a Layout returns the app to no Layout", card?.layout == nil)
            check("cleared card reports it has no Layout", card?.hasLayout == false)
        }

        // Layout: setting a Layout on an unmanaged bundle identifier is a no-op.
        do {
            var board = BoardState()
            board.setLayout(
                Layout(horizontalDivision: .halves, verticalDivision: .halves, columnSpan: .single(0), rowSpan: .single(0)),
                forBundleIdentifier: "com.example.Ghost"
            )
            check("setting a Layout on an unmanaged app changes nothing", board.configuration.managedApplications.isEmpty)
        }

        // Layout: a set Layout survives serialization so it persists across quit.
        do {
            var board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 1),
                ])
            )
            let layout = Layout(horizontalDivision: .fourths, verticalDivision: .thirds, columnSpan: LayoutSpan(start: 1, end: 3), rowSpan: .single(2))
            board.setLayout(layout, forBundleIdentifier: "com.example.Writer")
            let decoded = try? BoardStateSerialization.decode(from: BoardStateSerialization.encode(board))
            check("a set Layout round-trips through serialization",
                  decoded?.columns(desktopCount: 1).first?.cards.first?.layout == layout,
                  "got \(String(describing: decoded))")
        }

        if failures.isEmpty {
            print("Board state tests passed")
        } else {
            fatalError("Board state tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
