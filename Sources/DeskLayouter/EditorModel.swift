import AppKit
import DeskLayouterCore
import DeskLayouterMacOS

/// The feedback shown after an editor action (Apply or Arrange), so the view can
/// style success and failure differently and surface actionable detail. Named for
/// the editor rather than Apply because Arrange — a distinct verb (CONTEXT.md) —
/// reports through the same channel.
enum EditorFeedback: Equatable {
    case none
    case info(String)
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .none: ""
        case let .info(text), let .success(text), let .failure(text): text
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

@MainActor
final class EditorModel: ObservableObject {
    // Add-flow inputs (the searchable installed-app picker plus the chosen
    // destination Desktop).
    @Published var searchText = ""
    @Published var showRunningOnly = false
    @Published var newAssignmentDesktopNumber = 1
    @Published private(set) var selectedBundleIdentifier: String?
    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var selectedApplicationName = "No application selected"

    // Board projection + pending state.
    @Published private(set) var columns: [DesktopColumn] = []
    @Published private(set) var desktopCount = 0
    @Published private(set) var pendingChangeCount = 0
    @Published private(set) var feedback: EditorFeedback = .none

    private let assignmentPlanner: AssignmentPlanner
    private let spacesAdapter: any SpacesAdapter
    private let boardStateStore: BoardStateStore
    private let applicationsProvider: any InstalledApplicationsProviding
    private let windowArranger: WindowArranger
    private var board: BoardState
    private var selectedApplication: SelectedApplication?

    // Runtime Arrange state (issue #27, ADR-0003). The pure arming policy lives in
    // `DesktopArrangePlan`; this model owns only the live NSWorkspace observation
    // that drives it, torn down as soon as the last armed Desktop is arranged so
    // the app is never a permanent background observer.
    private var arrangePlan = DesktopArrangePlan()
    private var spaceChangeObserver: NSObjectProtocol?

    init(
        assignmentPlanner: AssignmentPlanner = AssignmentPlanner(),
        spacesAdapter: any SpacesAdapter = MacOSSpacesAdapter(),
        boardStateStore: BoardStateStore = .default,
        applicationsProvider: any InstalledApplicationsProviding = SystemInstalledApplicationsProvider(),
        windowArranger: WindowArranger = WindowArranger()
    ) {
        self.assignmentPlanner = assignmentPlanner
        self.spacesAdapter = spacesAdapter
        self.boardStateStore = boardStateStore
        self.applicationsProvider = applicationsProvider
        self.windowArranger = windowArranger
        // Load the saved board state so the editor reflects both the previously
        // applied Assignments and any edits that were pending at last quit. A
        // missing file loads as an empty board; a read failure falls back to
        // empty rather than blocking launch.
        board = (try? boardStateStore.load()) ?? BoardState()
        refreshProjection()
    }

    /// The applications the picker shows, filtered by the current search text and
    /// the "Currently running" toggle. Pure filtering lives in
    /// `ApplicationCatalog`; this is just the view-facing projection.
    var visibleApplications: [InstalledApplication] {
        ApplicationCatalog.filtered(
            applications,
            searchText: searchText,
            runningOnly: showRunningOnly
        )
    }

    /// True when a Desktop snapshot is available, so the editor can offer Desktop
    /// choices and accept new Assignments.
    var canEditAssignments: Bool { desktopCount > 0 }

    /// True when there are pending changes to write *and* a single active
    /// Display resolved, so Apply is enabled. Apply is disabled on a clean board,
    /// and also whenever the active Display could not be resolved (no active
    /// Display, or multiple extended Displays) — pending edits are kept, but they
    /// cannot be written until the topology is a single Display again
    /// (issue #18, ACs 5–6).
    var canApply: Bool { board.isDirty && desktopCount > 0 }

    /// True when at least one managed app carries a valid Layout, so Arrange has
    /// something to enact. Deliberately independent of ``canApply``: setting a
    /// Layout does not dirty the board, so Arrange must not gate on pending
    /// Assignment changes (issue #27).
    var canArrange: Bool {
        board.configuration.managedApplications.contains(where: \.hasValidLayout)
    }

    /// The status text shown beneath the board.
    var statusMessage: String { feedback.message }

    /// The real application icon for a card, resolved in the macOS layer.
    func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        applicationsProvider.icon(forBundleIdentifier: bundleIdentifier)
    }

    /// Re-enumerates installed/running applications and re-reads the Desktop
    /// snapshot. Called on launch and whenever the editor is shown, so the
    /// running state and the available Desktops stay current.
    func refresh() {
        refreshApplications()
        refreshDesktops()
    }

    func refreshApplications() {
        applications = applicationsProvider.applications()
    }

    /// Reads the current Desktops on the sole active Display so the board renders
    /// one column per real Desktop and Desktop choices are constrained to Desktops
    /// that actually exist. A read failure — including no active Display or
    /// multiple extended Displays — surfaces the adapter's error and leaves the
    /// board with no columns (and Apply disabled) rather than offering invalid
    /// Desktops. The saved board is untouched, so pending edits are preserved.
    func refreshDesktops() {
        do {
            let snapshot = try spacesAdapter.currentDesktopSnapshot()
            desktopCount = snapshot.orderedDesktopUUIDs.count
            newAssignmentDesktopNumber = min(max(newAssignmentDesktopNumber, 1), max(desktopCount, 1))
        } catch {
            desktopCount = 0
            feedback = .failure(error.localizedDescription)
        }
        refreshProjection()
    }

    /// Selects an application from the picker to feed into a new Assignment.
    func selectApplication(withBundleIdentifier bundleIdentifier: String?) {
        guard
            let bundleIdentifier,
            let match = applications.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else {
            return
        }
        selectedBundleIdentifier = bundleIdentifier
        selectedApplication = SelectedApplication(
            displayName: match.displayName,
            bundleIdentifier: match.bundleIdentifier
        )
        selectedApplicationName = match.displayName
    }

    /// Adds the picked application at the chosen destination Desktop as a new
    /// Assignment (or updates it if the app is already managed). Persists the
    /// board so the change survives relaunch; macOS is only touched on Apply.
    func addAssignment() {
        guard let selectedApplication else {
            feedback = .info("Choose an application to add.")
            return
        }
        guard canEditAssignments else {
            feedback = .info("No Desktops are available on the active display.")
            return
        }
        guard (1...desktopCount).contains(newAssignmentDesktopNumber) else {
            feedback = .info(desktopDoesNotExistMessage(newAssignmentDesktopNumber))
            return
        }

        board.assign(
            ManagedApplication(
                bundleIdentifier: selectedApplication.bundleIdentifier,
                displayName: selectedApplication.displayName,
                desktopNumber: newAssignmentDesktopNumber
            )
        )
        persist(
            info: "Added \(selectedApplication.displayName) → Desktop \(newAssignmentDesktopNumber). Click Apply to enforce it."
        )
    }

    /// Moves a card to a specific Desktop. Both drag-and-drop and the keyboard
    /// arrow controls call here. A move to the same Desktop, or of an unmanaged
    /// bundle identifier, changes nothing.
    func move(bundleIdentifier: String, toDesktop desktopNumber: Int) {
        guard canEditAssignments, (1...desktopCount).contains(desktopNumber) else {
            return
        }
        mutateAndPersist(info: "Moved to Desktop \(desktopNumber). Click Apply to enforce it.") {
            $0.move(bundleIdentifier: bundleIdentifier, toDesktop: desktopNumber)
        }
    }

    /// Moves a card one Desktop left (`-1`) or right (`+1`) for keyboard-only
    /// operation, clamped to the Desktops that exist.
    func moveCard(bundleIdentifier: String, by offset: Int) {
        guard let current = columns
            .first(where: { $0.cards.contains { $0.bundleIdentifier == bundleIdentifier } })
        else {
            return
        }
        let target = current.number + offset
        guard (1...max(desktopCount, 1)).contains(target) else { return }
        move(bundleIdentifier: bundleIdentifier, toDesktop: target)
    }

    /// Removes an Assignment from the board. Only this app is affected; the app
    /// returns to opening wherever on the next Apply, which deletes only its owned
    /// key from the macOS bindings.
    func removeAssignment(bundleIdentifier: String) {
        mutateAndPersist(info: "Removed the Assignment. Click Apply to return the app to opening wherever.") {
            $0.remove(bundleIdentifier: bundleIdentifier)
        }
    }

    /// Sets (or with `nil`, clears) a managed application's Layout and persists the
    /// board immediately so it survives relaunch. Layout decides *where* on a
    /// Desktop the window sits; it is enacted by Arrange (issue #27), not Apply, so
    /// this never changes the pending-Assignment count. A no-op change (same
    /// Layout) is not persisted.
    func setLayout(_ layout: Layout?, forBundleIdentifier bundleIdentifier: String) {
        mutateAndPersist(
            info: layout == nil
                ? "Cleared the Layout."
                : "Set the Layout. Use Arrange to move the window into it."
        ) {
            $0.setLayout(layout, forBundleIdentifier: bundleIdentifier)
        }
    }

    /// Applies every managed Assignment to both macOS representations, reusing the
    /// existing delete-aware adapter path (managed bindings plus managed-owned
    /// keys, unmanaged preserved). On success the board's applied baseline is
    /// advanced so it becomes clean; on failure the board stays dirty and can be
    /// retried.
    func apply() {
        guard board.isDirty else {
            feedback = .info("No changes to apply.")
            return
        }
        do {
            let snapshot = try spacesAdapter.currentDesktopSnapshot()
            let managedBindings = assignmentPlanner.appBindings(
                for: board.configuration.assignments,
                on: snapshot
            )
            try spacesAdapter.apply(
                managedBindings: managedBindings,
                managedBundleIdentifiers: board.configuration.ownedBundleIdentifiers,
                // Revalidated against a fresh read just before the first mutation
                // so a display change between this snapshot and Apply aborts
                // without writing (issue #18, AC 8).
                expectedSnapshot: snapshot
            )
            // Capture what changed in this Apply before advancing the baseline, so
            // the summary names only the apps whose Desktop actually changed.
            let changedIdentifiers = Set(board.pendingChanges)
            board.markApplied()
            var message = appliedSummary(changedIdentifiers: changedIdentifiers)
            do {
                try boardStateStore.save(board)
            } catch {
                // Apply itself succeeded; only the bookkeeping write failed. Say so
                // rather than hiding it — the removed keys are simply re-deleted
                // (idempotently) on the next Apply.
                message += " (Could not store the board: \(error.localizedDescription))"
            }
            feedback = .success(message)
            refreshProjection()
        } catch {
            feedback = .failure("Apply failed: \(error.localizedDescription). Your changes are still pending — fix the issue and try again.")
        }
    }

    /// The success message after Apply, naming only the already-running apps whose
    /// Assignment actually changed in this Apply — those are the ones that must be
    /// quit and relaunched before they use their new Desktop. Unchanged apps and
    /// removed apps are not listed.
    private func appliedSummary(changedIdentifiers: Set<String>) -> String {
        let count = board.configuration.managedApplications.count
        let noun = count == 1 ? "Assignment" : "Assignments"
        var message = "Applied \(count) \(noun)."

        let managedIdentifiers = Set(board.configuration.managedApplications.map(\.bundleIdentifier))
        let runningNames = applications
            .filter {
                $0.isRunning
                    && changedIdentifiers.contains($0.bundleIdentifier)
                    && managedIdentifiers.contains($0.bundleIdentifier)
            }
            .map(\.displayName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if runningNames.isEmpty {
            message += " Newly launched apps open on their assigned Desktop."
        } else {
            message += " Quit and relaunch these already-running apps before they use their new Desktop: \(runningNames.joined(separator: ", "))."
        }
        return message
    }

    // MARK: - Arrange

    /// Enacts persisted Layouts at runtime (issue #27, ADR-0003). Arranges the
    /// currently active Desktop immediately, then arms every OTHER Desktop that
    /// has a Layout so it is arranged once, the first time it becomes active. Once
    /// the last armed Desktop has been visited the Space-change observation is torn
    /// down entirely. Pressing again re-arms from scratch. Windows that resisted
    /// the move are surfaced in the feedback rather than dropped silently.
    func arrange() {
        let applications = board.configuration.managedApplications
        let activeDesktop = try? spacesAdapter.activeDesktopNumber()

        // Immediately arrange the active Desktop. The engine only reaches the
        // active Space, so this enacts exactly the Layouts on the Desktop in front
        // of the user right now.
        guard let report = runArrange(applications) else { return }

        // Arm the other Desktops that have Layouts. `activeDesktop` is excluded
        // because it was just arranged above.
        let desktopsWithLayouts = Set(
            applications.filter(\.hasValidLayout).map(\.desktopNumber)
        )
        let outcome = arrangePlan.press(
            desktopsWithLayouts: desktopsWithLayouts,
            activeDesktop: activeDesktop
        )
        if outcome.shouldObserve {
            startObservingSpaceChanges()
        } else {
            stopObservingSpaceChanges()
        }

        feedback = arrangeFeedback(
            for: report,
            armedDesktopCount: arrangePlan.armedDesktops.count
        )
    }

    /// Runs one Arrange pass, translating the engine's thrown errors into
    /// user-facing feedback. Returns the report on success, or `nil` when the pass
    /// could not run (feedback already set) so the caller aborts arming.
    private func runArrange(_ applications: [ManagedApplication]) -> ArrangeReport? {
        do {
            return try windowArranger.arrange(managedApplications: applications)
        } catch WindowArrangeError.accessibilityNotGranted {
            feedback = .failure(
                "Grant Desk Layouter Accessibility access in System Settings > "
                    + "Privacy & Security > Accessibility, then press Arrange again. Nothing was moved."
            )
            return nil
        } catch WindowArrangeError.noActiveScreen {
            feedback = .failure("No active display could be resolved to arrange against. Nothing was moved.")
            return nil
        } catch {
            feedback = .failure("Arrange failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Builds the feedback after an Arrange pass: it names how many windows moved,
    /// explains that any armed Desktops are arranged on first visit, and — the key
    /// signal — lists any windows that resisted the move so they are never dropped
    /// silently (issue #27 acceptance criteria).
    private func arrangeFeedback(for report: ArrangeReport, armedDesktopCount: Int) -> EditorFeedback {
        var message = report.arranged.isEmpty
            ? "Arranged this Desktop — no windows needed moving."
            : "Arranged \(report.arranged.count) ^[window](inflect: true) on this Desktop."
        if armedDesktopCount > 0 {
            message += " \(armedDesktopCount) other ^[Desktop](inflect: true) with a Layout will be arranged the first time you visit ^[it](inflect: true)."
        }
        if report.hasResistance {
            let names = report.resisted
                .map(\.displayName)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            message += " These windows resisted being moved (fixed-size, fullscreen, or a sheet): "
                + names.joined(separator: ", ") + "."
            return .failure(message)
        }
        return .success(message)
    }

    /// Starts observing Space changes so an armed Desktop is arranged the first
    /// time it becomes active. Idempotent — a second Arrange while already
    /// observing does not stack observers.
    private func startObservingSpaceChanges() {
        guard spaceChangeObserver == nil else { return }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActiveSpaceChange()
            }
        }
    }

    /// Tears the Space-change observation down entirely, so the app is not a
    /// permanent background observer once every armed Desktop has been arranged.
    private func stopObservingSpaceChanges() {
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
            self.spaceChangeObserver = nil
        }
    }

    /// Handles a Space change while arming is active: if the now-active Desktop is
    /// armed, arrange it once and disarm it; when it was the last armed Desktop,
    /// stop observing.
    private func handleActiveSpaceChange() {
        let activeDesktop = try? spacesAdapter.activeDesktopNumber()
        switch arrangePlan.desktopBecameActive(activeDesktop) {
        case .ignore:
            return
        case let .arrange(tearDownAfter):
            if let report = runArrange(board.configuration.managedApplications) {
                feedback = arrangeFeedback(for: report, armedDesktopCount: arrangePlan.armedDesktops.count)
            }
            if tearDownAfter {
                stopObservingSpaceChanges()
            }
        }
    }

    /// Applies a transition to the board and persists it, but only when it
    /// actually changed something. This is the shared spine for the move and
    /// remove intents so each need not repeat the change-detection and persistence.
    private func mutateAndPersist(info: String, _ transition: (inout BoardState) -> Void) {
        let before = board
        transition(&board)
        guard board != before else { return }
        persist(info: info)
    }

    /// Stores the board and refreshes the projection, reporting a write failure
    /// rather than silently losing the edit.
    private func persist(info: String) {
        do {
            try boardStateStore.save(board)
            refreshProjection()
            feedback = .info(info)
        } catch {
            feedback = .failure("Could not store the board: \(error.localizedDescription)")
        }
    }

    private func desktopDoesNotExistMessage(_ desktopNumber: Int) -> String {
        "Desktop \(desktopNumber) does not exist on the active display."
    }

    private func refreshProjection() {
        columns = board.columns(desktopCount: desktopCount)
        pendingChangeCount = board.pendingChangeCount
    }
}

private struct SelectedApplication {
    let displayName: String
    let bundleIdentifier: String
}
