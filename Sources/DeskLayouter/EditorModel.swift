import AppKit
import DeskLayouterCore
import DeskLayouterMacOS

/// The pending choice presented when the user selects another Preset while the
/// working copy has unsaved changes to the current one. Drives the protective
/// "Update and Switch" / "Discard and Switch" / "Cancel" prompt.
struct PendingPresetSwitch: Identifiable, Equatable {
    let targetID: UUID
    let targetName: String
    let currentPresetName: String

    var id: UUID { targetID }
}

/// The pending confirmation shown before a Preset is deleted. Carries the
/// Preset's name so the confirmation can name exactly what will be deleted.
struct PendingPresetDeletion: Identifiable, Equatable {
    let presetID: UUID
    let presetName: String

    var id: UUID { presetID }
}

/// The pending confirmation shown before the selected Preset is restored over
/// its edited working copy. Carries the stable identity as well as the visible
/// name so confirming always targets the Preset the prompt named.
struct PendingPresetRevert: Identifiable, Equatable {
    let presetID: UUID
    let presetName: String

    var id: UUID { presetID }
}

/// The one-time choice required before legacy Assignments can be attached in an
/// extended multi-Display topology. It remains presented until a choice is
/// successfully persisted; dismissing the sheet is disabled in the view.
struct PendingDisplayMigration: Identifiable, Equatable {
    let displays: [DisplayIdentity]

    var id: String { displays.map(\.colorSyncUUID).joined(separator: "|") }
}

@MainActor
final class EditorModel: ObservableObject {
    // Add-flow inputs (the searchable installed-app picker plus the chosen
    // destination Desktop).
    @Published var searchText = ""
    @Published var newAssignmentDesktopNumber = 1
    @Published private(set) var selectedBundleIdentifier: String?
    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var selectedApplicationName = "No application selected"

    // Board projection + pending state.
    @Published private(set) var columns: [DesktopColumn] = []
    // Assignments stranded on Desktops that no longer exist, surfaced as their own
    // labeled sections so they stay visible and recoverable rather than being
    // dropped (issue #52). Empty when every Assignment targets a Desktop that
    // exists.
    @Published private(set) var unavailableDesktops: [UnavailableDesktopSection] = []
    @Published private(set) var desktopCount = 0
    @Published private(set) var pendingChangeCount = 0
    @Published private(set) var feedback: EditorFeedback = .none

    // Presets: the ordered library shown in the header selector, and the working
    // copy's required selected-Preset association.
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var selectedPresetID: UUID
    @Published var pendingPresetSwitch: PendingPresetSwitch?
    @Published var pendingPresetDeletion: PendingPresetDeletion?
    @Published var pendingPresetRevert: PendingPresetRevert?
    @Published private(set) var pendingDisplayMigration: PendingDisplayMigration?

    private let assignmentPlanner: AssignmentPlanner
    private let spacesAdapter: any SpacesAdapter
    private let boardStateStore: BoardStateStore
    private let presetLibraryStore: PresetLibraryStore
    private let applicationPickerStore: ApplicationPickerStore
    private let windowArranger: WindowArranger
    private var board: BoardState
    private var presetLibrary: PresetLibrary
    private var selectedApplication: SelectedApplication?
    private var latestDesktopSnapshot: DesktopSnapshot?

    // Runtime Arrange state (issue #27, ADR-0003; settling policy issue #62). The
    // arming policy and the bounded settling/retry across Desktop transitions live
    // in `ArrangeTransitionCoordinator`; this model owns only the live NSWorkspace
    // observation that drives it, torn down as soon as the last armed Desktop is
    // arranged so the app is never a permanent background observer, and the
    // scheduler the coordinator retries on.
    private let transitionScheduler: any TransitionScheduler
    private var spaceChangeObserver: NSObjectProtocol?

    /// Coordinates the runtime Arrange cycle: it holds the arming set and, because
    /// `activeSpaceDidChangeNotification` fires before the new Desktop's live Space
    /// and Accessibility windows are ready (issue #62), waits for the transition to
    /// settle — retrying against the freshly re-resolved live Desktop — before an
    /// armed Desktop is completed. The live side effects are supplied here as
    /// closures; the policy itself is exercised deterministically in
    /// `DeskLayouterTransitionTests`. Built lazily so its closures can capture a
    /// fully-initialized `self`.
    private lazy var transitionCoordinator = ArrangeTransitionCoordinator(
        scheduler: transitionScheduler,
        resolveActiveDesktop: { [weak self] in self?.liveActiveDesktopNumber() ?? nil },
        performArrange: { [weak self] desktop in (self?.arrangePass(forDesktop: desktop)) ?? nil },
        presentReport: { [weak self] report, activeDesktop, pendingDesktops in
            guard let self else { return }
            feedback = arrangeFeedback(
                for: report,
                activeDesktop: activeDesktop,
                pendingDesktops: pendingDesktops
            )
        },
        stopObserving: { [weak self] in self?.stopObservingSpaceChanges() }
    )

    /// The latest availability-aware projection of the board against the live
    /// system (issue #52). Core owns the surfacing and Apply-gating rules; this
    /// model stores the projection and reads its computed facts rather than
    /// re-deriving them, so "what blocks Apply" lives in exactly one place.
    private var boardProjection = BoardProjection(availableColumns: [], unavailableDesktops: [])

    init(
        assignmentPlanner: AssignmentPlanner = AssignmentPlanner(),
        spacesAdapter: any SpacesAdapter = MacOSSpacesAdapter(),
        boardStateStore: BoardStateStore = .default,
        presetLibraryStore: PresetLibraryStore = .default,
        applicationsProvider: any InstalledApplicationsProviding = SystemInstalledApplicationsProvider(),
        windowArranger: WindowArranger = WindowArranger(),
        transitionScheduler: any TransitionScheduler = MainQueueTransitionScheduler()
    ) {
        self.assignmentPlanner = assignmentPlanner
        self.spacesAdapter = spacesAdapter
        self.boardStateStore = boardStateStore
        self.presetLibraryStore = presetLibraryStore
        applicationPickerStore = ApplicationPickerStore(provider: applicationsProvider)
        self.windowArranger = windowArranger
        self.transitionScheduler = transitionScheduler
        // Load the board and library as one reconciled session. A missing or
        // legacy association seeds a real Preset from the untouched working board;
        // read/write failures remain best-effort and never block launch.
        let session = PresetStartup.load(
            boardStateStore: boardStateStore,
            presetLibraryStore: presetLibraryStore
        )
        board = session.board
        presetLibrary = session.library
        selectedPresetID = session.selectedPresetID
        refreshPresets()
        refreshProjection()
    }

    /// The applications the picker shows, filtered by the current search text.
    /// Pure filtering lives in
    /// `ApplicationCatalog`; this is just the view-facing projection.
    var visibleApplications: [InstalledApplication] {
        ApplicationCatalog.filtered(
            applications,
            searchText: searchText
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
    ///
    /// Apply is additionally disabled while any Assignment targets a Desktop that
    /// does not currently exist (issue #52): writing then would silently drop
    /// those stranded Assignments, so the user must first move them to an
    /// available Desktop. Missing *applications* never disable Apply — their
    /// bundle identifiers stay declarative data that takes effect if reinstalled.
    var canApply: Bool {
        !currentPendingChanges.isEmpty
            && desktopCount > 0
            && !hasUnavailableDisplayAssignments
            && !hasUnavailableDesktopAssignments
            && pendingDisplayMigration == nil
    }

    /// True when the one-Display editor cannot resolve every saved Assignment
    /// against the currently active physical Display. Apply stays blocked so a
    /// skipped Assignment's existing macOS binding is never treated as a managed
    /// key to delete.
    var hasUnavailableDisplayAssignments: Bool {
        board.hasUnavailableDisplayAssignments(on: latestDesktopSnapshot)
    }

    /// True when at least one Assignment targets a Desktop that no longer exists,
    /// so the board shows the unavailable sections and Apply is blocked. Reads the
    /// Core projection's rule directly — the single source of truth.
    var hasUnavailableDesktopAssignments: Bool { boardProjection.hasUnavailableDesktopAssignments }

    /// Explanatory feedback shown beside Apply while it is blocked by unavailable
    /// Desktops, naming exactly which Desktops must be cleared so the user knows
    /// what to fix. `nil` when Apply is not blocked for this reason.
    var applyBlockedExplanation: String? {
        if hasUnavailableDisplayAssignments {
            return "Apply is disabled: one or more Assignments target a physical Display that is not currently available. Nothing is dropped — reconnect that Display to Apply these Assignments."
        }
        guard hasUnavailableDesktopAssignments else { return nil }
        let numbers = boardProjection.unavailableDesktopNumbers
        let list = numbers.map(String.init).joined(separator: ", ")
        let desktopNoun = numbers.count == 1 ? "Desktop" : "Desktops"
        return "Apply is disabled: move every app off unavailable \(desktopNoun) \(list) to a Desktop that exists. Nothing is dropped — your Assignments stay until you move them."
    }

    /// True when at least one managed app carries a valid Layout, so Arrange has
    /// something to enact. Deliberately independent of ``canApply``: setting a
    /// Layout does not dirty the board, so Arrange must not gate on pending
    /// Assignment changes (issue #27).
    var canArrange: Bool {
        board.configuration.managedApplications.contains(where: \.hasValidLayout)
    }

    /// The single status presentation shown above the footer. Latest action
    /// feedback wins; otherwise it explains pending changes or why Apply is off.
    var statusPresentation: EditorStatusPresentation {
        EditorStatusPresentation.resolve(
            feedback: feedback,
            pendingChangeCount: pendingChangeCount,
            applyBlockedExplanation: applyBlockedExplanation,
            desktopCount: desktopCount
        )
    }

    /// The real application icon for a card, resolved in the macOS layer.
    func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        applicationPickerStore.icon(forBundleIdentifier: bundleIdentifier)
    }

    /// Re-enumerates installed/running applications and re-reads the Desktop
    /// snapshot. Called on launch and whenever the editor is shown, so the
    /// running state and the available Desktops stay current.
    func refresh() {
        refreshApplications()
        refreshDesktops()
    }

    func refreshApplications() {
        applicationPickerStore.refresh()
        applications = applicationPickerStore.applications
    }

    /// Reads the current Desktops on the sole active Display so the board renders
    /// one column per real Desktop and Desktop choices are constrained to Desktops
    /// that actually exist. A read failure — including no active Display or
    /// multiple extended Displays — surfaces the adapter's error and leaves the
    /// board with no columns (and Apply disabled) rather than offering invalid
    /// Desktops. The saved board is untouched, so pending edits are preserved.
    func refreshDesktops() {
        if prepareDisplayMigrationIfNeeded() {
            latestDesktopSnapshot = nil
            desktopCount = 0
            refreshProjection()
            return
        }
        do {
            let snapshot = try spacesAdapter.currentDesktopSnapshot()
            latestDesktopSnapshot = snapshot
            desktopCount = snapshot.orderedDesktopUUIDs.count
            newAssignmentDesktopNumber = min(max(newAssignmentDesktopNumber, 1), max(desktopCount, 1))
        } catch {
            latestDesktopSnapshot = nil
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
        selectedApplicationName = match.presentedName
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
        guard let display = latestDesktopSnapshot?.display else {
            feedback = .failure("The physical Display could not be identified. No Assignment was added.")
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
                display: display,
                desktopNumber: newAssignmentDesktopNumber
            )
        )
        persist(
            info: "Added \(ApplicationDisplayName.presented(selectedApplication.displayName)) → Desktop \(newAssignmentDesktopNumber). Click Apply to enforce it."
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
    ///
    /// The current Desktop is read from the working configuration — the single
    /// source of truth — not from the projected available `columns`, so a card
    /// stranded on a Desktop that no longer exists (issue #52) can still be moved
    /// off it with the keyboard. Clamping the target into `1...desktopCount` means
    /// an edge card is a harmless no-op as before, while a stranded card is
    /// brought back onto the nearest Desktop that exists.
    func moveCard(bundleIdentifier: String, by offset: Int) {
        guard desktopCount > 0,
              let application = board.configuration.managedApplication(for: bundleIdentifier)
        else {
            return
        }
        let target = min(max(application.desktopNumber + offset, 1), desktopCount)
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
        guard !currentPendingChanges.isEmpty else {
            feedback = .info("No changes to apply.")
            return
        }
        // Refuse to Apply while any Assignment is stranded on a Desktop that no
        // longer exists: writing now would skip those bindings and delete their
        // owned keys, silently dropping the Assignments (issue #52). Keep them and
        // tell the user what to move instead.
        if let explanation = applyBlockedExplanation {
            feedback = .info(explanation)
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
            let changedIdentifiers = Set(board.pendingChanges(on: snapshot))
            board.markApplied(effectiveDesktopUUIDs: managedBindings)
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
            .map(\.presentedName)
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

        // Resolve the Desktop that is LIVE-active in the current WindowServer
        // session (issue #61). This is deliberately not the exported store's
        // `Current Space`, which can lag behind the session. If it cannot be
        // resolved or mapped, fail closed: move no windows and arm no Desktop, so
        // no Desktop is wrongly treated as completed.
        guard let activeDesktop = try? spacesAdapter.activeDesktopNumber() else {
            feedback = .failure(
                "Could not determine the active Desktop, so nothing was arranged. "
                    + "Make sure a single display is active, then press Arrange again."
            )
            return
        }

        // Immediately arrange the active Desktop, passing only the applications
        // assigned to it. The engine only reaches the active Space, so scoping to
        // this Desktop's apps means apps on other Desktops are neither moved nor
        // reported during this pass.
        let activeDesktopApplications = ArrangeEngine.applications(
            applications,
            assignedToDesktop: activeDesktop
        )
        guard let report = runArrange(activeDesktopApplications) else { return }

        // Arm the other Desktops that have Layouts. `activeDesktop` is excluded
        // because it was just arranged above. Re-pressing starts a fresh cycle and
        // invalidates any settling attempt still pending from a previous press
        // (issue #62).
        let desktopsWithLayouts = Set(
            applications.filter(\.hasValidLayout).map(\.desktopNumber)
        )
        let shouldObserve = transitionCoordinator.press(
            desktopsWithLayouts: desktopsWithLayouts,
            activeDesktop: activeDesktop
        )
        if shouldObserve {
            startObservingSpaceChanges()
        } else {
            stopObservingSpaceChanges()
        }

        feedback = arrangeFeedback(
            for: report,
            activeDesktop: activeDesktop,
            pendingDesktops: Array(transitionCoordinator.armedDesktops)
        )
    }

    /// The live active Desktop number, or `nil` when it cannot be resolved. Wraps
    /// the throwing adapter read so the coordinator sees a clean optional and
    /// treats an unresolved read as "unknown" — retried during a transition rather
    /// than acted on (issue #61, #62).
    private func liveActiveDesktopNumber() -> Int? {
        (try? spacesAdapter.activeDesktopNumber()) ?? nil
    }

    /// Runs one settling Arrange pass scoped to `desktop`'s applications, reusing
    /// the same engine scoping and error-to-feedback mapping as the immediate
    /// pass. Returns `nil` when the pass could not run (feedback already set).
    private func arrangePass(forDesktop desktop: Int) -> ArrangeReport? {
        let desktopApplications = ArrangeEngine.applications(
            board.configuration.managedApplications,
            assignedToDesktop: desktop
        )
        return runArrange(desktopApplications)
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

    /// Builds the feedback after an Arrange pass: it names the affected
    /// application display names and the numbered active Desktop, names any
    /// Desktops still armed for their first visit, names applications skipped for
    /// having no available window, and — as a distinct error — names any windows
    /// that refused to move or resize (issue #34 acceptance criteria). The pure
    /// wording lives in `ArrangeReportPresenter`; this only maps the engine's
    /// bundle identifiers to display names and threads the presenter's tone into
    /// the view's success/failure styling.
    private func arrangeFeedback(
        for report: ArrangeReport,
        activeDesktop: Int?,
        pendingDesktops: [Int]
    ) -> EditorFeedback {
        let displayNames = Dictionary(
            board.configuration.managedApplications.map { ($0.bundleIdentifier, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        func displayName(for bundleIdentifier: String) -> String {
            displayNames[bundleIdentifier] ?? bundleIdentifier
        }

        let announcement = ArrangeReportPresenter.announce(
            activeDesktop: activeDesktop,
            arranged: report.arranged.map(displayName(for:)),
            skipped: report.skipped.map(displayName(for:)),
            resisted: report.resisted.map(\.displayName),
            pendingDesktops: pendingDesktops
        )
        switch announcement.tone {
        case .success:
            return .success(announcement.message)
        case .failure:
            return .failure(announcement.message)
        }
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
                // Hand the notification to the coordinator, which starts a bounded
                // settling cycle instead of acting synchronously on a transition
                // that has not settled yet (issue #62).
                self?.transitionCoordinator.spaceChangeNotified()
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

    // MARK: - Presets

    /// The real, undecorated name of the selected Preset. Prompts and rename
    /// editing use this value so the Preset-dirty marker remains presentation,
    /// never part of the stored name.
    var selectedPresetName: String {
        presetLibrary.preset(for: selectedPresetID)?.name ?? ""
    }

    /// Whether the working board differs from the selected Preset's stored
    /// snapshot. `PresetLibrary.isModified` delegates to the existing
    /// `Preset.matches` comparison, which includes Assignments and Layouts but
    /// ignores Apply bookkeeping such as pending removals.
    var isSelectedPresetModified: Bool {
        presetLibrary.isModified(board.configuration, from: selectedPresetID)
    }

    /// The selector's visible value. A dirty working copy stays attached to its
    /// selected Preset and is decorated rather than replaced by a custom state.
    var presetSelectionLabel: String {
        guard isSelectedPresetModified else { return selectedPresetName }
        return "● \(selectedPresetName) — Edited"
    }

    /// True only while the working board differs from its selected Preset, so an
    /// explicit update cannot be offered for an already matching snapshot.
    var canUpdateSelectedPreset: Bool {
        isSelectedPresetModified
    }

    /// Revert abandons edits to the working copy, so it shares the same
    /// Preset-dirty gate as Update and is independent of Apply-dirty.
    var canRevertSelectedPreset: Bool { isSelectedPresetModified }

    /// True when a resolvable Preset is selected, so the header's Rename action has
    /// a target.
    var canRenameSelectedPreset: Bool {
        presetLibrary.preset(for: selectedPresetID) != nil
    }

    /// True when the selected Preset can be deleted without emptying the library.
    var canDeleteSelectedPreset: Bool {
        canRenameSelectedPreset && presetLibrary.presets.count > 1
    }

    /// Saves the current working board as a new Preset under the given name,
    /// capturing every managed application, its Assignment, and its optional
    /// Layout — including an empty board. The name is validated (non-empty and
    /// unique ignoring capitalization); an invalid name replaces nothing.
    ///
    /// Returns `nil` on success (the caller dismisses its save prompt), or a
    /// clear error message to show inline so the user can correct the name in
    /// place without losing what they typed. On success the working copy is
    /// associated with the new Preset and both files are persisted. This never
    /// Applies or Arranges.
    @discardableResult
    func saveCurrentBoardAsPreset(named name: String) -> String? {
        do {
            // Validate and add against a copy so a disk-write failure cannot leave
            // the in-memory library ahead of what is stored.
            var updatedLibrary = presetLibrary
            let created = try updatedLibrary.add(
                name: name,
                managedApplications: board.configuration.managedApplications
            )
            try presetLibraryStore.save(updatedLibrary)
            presetLibrary = updatedLibrary
            board.associateSelectedPreset(created.id)
            selectedPresetID = created.id
            refreshPresets()
            do {
                try boardStateStore.save(board)
            } catch {
                // The Preset itself was saved; only the board-association write
                // failed. Report it in the status line but treat the save as done.
                feedback = .failure("Saved the Preset, but could not store the board: \(error.localizedDescription)")
                return nil
            }
            feedback = .success("Saved Preset \"\(created.name)\".")
            return nil
        } catch let error as PresetNameError {
            return presetNameErrorMessage(error)
        } catch {
            return "Could not save the Preset: \(error.localizedDescription)"
        }
    }

    /// Entry point for choosing a Preset from the selector. When the working copy
    /// still matches the selected Preset (or none is selected) it loads the target
    /// immediately; when the working copy has been modified it opens the protective
    /// three-way prompt instead of silently overwriting or discarding work.
    /// Re-selecting the already-selected Preset is a no-op, so a checkmarked row
    /// can never silently discard the working copy.
    func selectPreset(id: UUID) {
        guard id != selectedPresetID, presetLibrary.preset(for: id) != nil else { return }
        switch PresetSwitch.decide(
            target: id,
            currentSelection: selectedPresetID,
            configuration: board.configuration,
            library: presetLibrary
        ) {
        case .switchImmediately:
            loadPreset(id: id)
        case let .confirm(currentPresetName):
            pendingPresetSwitch = PendingPresetSwitch(
                targetID: id,
                targetName: presetLibrary.preset(for: id)?.name ?? "",
                currentPresetName: currentPresetName
            )
        }
    }

    /// "Update and Switch": stores the working board in the current Preset, then
    /// loads the requested one. A persistence failure prevents the switch and
    /// reports the error, leaving both the working copy and the stored Preset intact.
    func confirmUpdateAndSwitch() {
        guard
            let pending = pendingPresetSwitch,
            let current = presetLibrary.preset(for: selectedPresetID)
        else {
            pendingPresetSwitch = nil
            return
        }
        do {
            let result = try PresetSwitch.updateAndSwitch(
                target: pending.targetID,
                currentSelection: selectedPresetID,
                library: presetLibrary,
                board: board,
                persist: { try presetLibraryStore.save($0) }
            )
            presetLibrary = result.library
            board = result.board
            selectedPresetID = board.selectedPresetID ?? selectedPresetID
            refreshPresets()
            pendingPresetSwitch = nil
            do {
                try boardStateStore.save(board)
                refreshProjection()
                feedback = .success("Updated Preset \"\(current.name)\" and switched to \"\(pending.targetName)\".")
            } catch {
                refreshProjection()
                feedback = .failure("Updated Preset \"\(current.name)\" and switched, but could not store the board: \(error.localizedDescription)")
            }
        } catch {
            pendingPresetSwitch = nil
            feedback = .failure("Could not update Preset \"\(current.name)\": \(error.localizedDescription). Nothing was switched.")
        }
    }

    /// "Discard and Switch": loads the requested Preset over the working copy,
    /// leaving the stored current Preset unchanged.
    func confirmDiscardAndSwitch() {
        guard let pending = pendingPresetSwitch else { return }
        pendingPresetSwitch = nil
        loadPreset(id: pending.targetID)
    }

    /// "Cancel": dismisses the prompt, preserving the working copy and selection.
    func cancelPresetSwitch() {
        pendingPresetSwitch = nil
    }

    /// Loads the Preset with the given identity as the working copy: it swaps in
    /// the Preset's complete board while preserving the true last-applied baseline,
    /// and records the selected-Preset association. Loading changes only the
    /// working board — it never Applies to macOS or Arranges windows. The board is
    /// persisted so the working copy and its association survive relaunch.
    func loadPreset(id: UUID) {
        guard let preset = presetLibrary.preset(for: id) else { return }
        board.load(configuration: preset.configuration, selectedPresetID: preset.id)
        selectedPresetID = preset.id
        do {
            try boardStateStore.save(board)
            refreshProjection()
            feedback = .info("Loaded Preset \"\(preset.name)\". Apply or Arrange when you're ready — loading changed only this board.")
        } catch {
            feedback = .failure("Could not store the board: \(error.localizedDescription)")
        }
    }

    /// Updates the selected Preset to match the current working board, capturing
    /// its managed applications, Assignments, and Layouts. This is the only action
    /// that changes a stored Preset — editing a loaded working copy leaves the
    /// Preset untouched until the user asks for this. With no Preset selected there
    /// is nothing to update.
    func updateSelectedPreset() {
        guard let existing = presetLibrary.preset(for: selectedPresetID) else {
            feedback = .info("Select a Preset to update, or save the board as a new Preset.")
            return
        }
        guard isSelectedPresetModified else {
            feedback = .info("Preset \"\(existing.name)\" already matches the current board.")
            return
        }
        var updatedLibrary = presetLibrary
        updatedLibrary.update(id: selectedPresetID, managedApplications: board.configuration.managedApplications)
        do {
            try presetLibraryStore.save(updatedLibrary)
            presetLibrary = updatedLibrary
            refreshPresets()
            feedback = .success("Updated Preset \"\(existing.name)\".")
        } catch {
            feedback = .failure("Could not update the Preset: \(error.localizedDescription)")
        }
    }

    /// Opens the Revert confirmation for the selected Preset. A matching board
    /// has nothing to abandon, so the action remains disabled and this guard keeps
    /// programmatic calls harmless as well.
    func requestRevertSelectedPreset() {
        guard
            canRevertSelectedPreset,
            let preset = presetLibrary.preset(for: selectedPresetID)
        else {
            return
        }
        pendingPresetRevert = PendingPresetRevert(
            presetID: preset.id,
            presetName: preset.name
        )
    }

    /// Restores the confirmed Preset snapshot over the working copy. The pure
    /// transformation preserves the applied baseline, so this can change the
    /// existing Apply-dirty count but can never Apply or Arrange. Persisting the
    /// resulting board only makes the reverted working copy survive relaunch.
    func confirmRevertSelectedPreset() {
        guard
            let pending = pendingPresetRevert,
            pending.presetID == selectedPresetID,
            presetLibrary.preset(for: pending.presetID) != nil
        else {
            pendingPresetRevert = nil
            return
        }
        board = PresetEditing.revert(
            to: pending.presetID,
            library: presetLibrary,
            board: board
        )
        pendingPresetRevert = nil
        do {
            try boardStateStore.save(board)
            refreshProjection()
            feedback = .success("Reverted to Preset \"\(pending.presetName)\". Nothing was Applied or Arranged.")
        } catch {
            refreshProjection()
            feedback = .failure("Reverted to Preset \"\(pending.presetName)\", but could not store the board: \(error.localizedDescription)")
        }
    }

    /// Dismisses the Revert confirmation with the working copy untouched.
    func cancelRevertSelectedPreset() {
        pendingPresetRevert = nil
    }

    /// Renames the selected Preset, reusing the same validation as Preset creation
    /// (non-empty, case-insensitive uniqueness) and preserving its complete stored
    /// snapshot. Returns `nil` on success (the caller dismisses its rename prompt),
    /// or a clear error message to show inline so the user can correct the name in
    /// place. The rename is persisted before it is committed in memory, so a disk
    /// failure never loses the Preset. This never Applies or Arranges and never
    /// touches the working board — the association is by identity.
    @discardableResult
    func renameSelectedPreset(to name: String) -> String? {
        guard presetLibrary.preset(for: selectedPresetID) != nil else {
            return "Select a Preset to rename."
        }
        do {
            presetLibrary = try PresetEditing.rename(
                id: selectedPresetID,
                to: name,
                library: presetLibrary,
                persist: { try presetLibraryStore.save($0) }
            )
            refreshPresets()
            let newName = presetLibrary.preset(for: selectedPresetID)?.name ?? name
            feedback = .success("Renamed the Preset to \"\(newName)\".")
            return nil
        } catch let error as PresetNameError {
            return presetNameErrorMessage(error)
        } catch {
            return "Could not rename the Preset: \(error.localizedDescription)"
        }
    }

    /// Opens the delete confirmation for the selected Preset, naming exactly what
    /// will be deleted. Deleting is never immediate — it always routes through this
    /// explicit confirmation. With no Preset selected there is nothing to delete.
    func requestDeleteSelectedPreset() {
        guard canDeleteSelectedPreset else {
            feedback = .info("Keep at least one Preset.")
            return
        }
        guard let preset = presetLibrary.preset(for: selectedPresetID) else {
            feedback = .info("Select a Preset to delete.")
            return
        }
        pendingPresetDeletion = PendingPresetDeletion(
            presetID: selectedPresetID,
            presetName: preset.name
        )
    }

    /// Performs the confirmed deletion. The stored library is written with the
    /// Preset removed before the change is committed in memory, so a disk failure
    /// prevents the delete and reports it, losing neither the Preset nor the
    /// working board. Deleting the selected Preset preserves its loaded working
    /// board and associates it with a remaining Preset. This never Applies or
    /// Arranges and never alters the applied baseline.
    func confirmDeletePreset() {
        guard let pending = pendingPresetDeletion, let existing = presetLibrary.preset(for: pending.presetID) else {
            pendingPresetDeletion = nil
            return
        }
        let wasSelected = selectedPresetID == pending.presetID
        do {
            let result = try PresetEditing.delete(
                id: pending.presetID,
                currentSelection: selectedPresetID,
                library: presetLibrary,
                board: board,
                persist: { try presetLibraryStore.save($0) }
            )
            presetLibrary = result.library
            board = result.board
            selectedPresetID = board.selectedPresetID ?? selectedPresetID
            refreshPresets()
            pendingPresetDeletion = nil
            guard wasSelected else {
                feedback = .success("Deleted Preset \"\(existing.name)\".")
                return
            }
            // Persist the replacement association so it survives relaunch. The
            // delete itself already succeeded, so a board-write failure is
            // reported but does not undo it; the next launch repairs any dangling
            // on-disk identity from the preserved working board.
            do {
                try boardStateStore.save(board)
                refreshProjection()
                feedback = .success("Deleted Preset \"\(existing.name)\". This board is now associated with \"\(selectedPresetName)\".")
            } catch {
                refreshProjection()
                feedback = .failure("Deleted Preset \"\(existing.name)\", but could not store the board: \(error.localizedDescription)")
            }
        } catch {
            pendingPresetDeletion = nil
            feedback = .failure("Could not delete Preset \"\(existing.name)\": \(error.localizedDescription). Nothing was deleted.")
        }
    }

    /// Dismisses the delete confirmation without deleting anything.
    func cancelPresetDeletion() {
        pendingPresetDeletion = nil
    }

    private func presetNameErrorMessage(_ error: PresetNameError) -> String {
        switch error {
        case .empty:
            "Enter a name for the Preset."
        case let .duplicate(existingName):
            "A Preset named \"\(existingName)\" already exists. Choose a different name."
        }
    }

    private func refreshPresets() {
        presets = presetLibrary.orderedPresets
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
        boardProjection = board.projection(
            desktopCount: desktopCount,
            installedBundleIdentifiers: Set(applications.map(\.bundleIdentifier))
        )
        columns = boardProjection.availableColumns
        unavailableDesktops = boardProjection.unavailableDesktops
        pendingChangeCount = currentPendingChanges.count
    }

    private var currentPendingChanges: [String] {
        board.pendingChanges(on: latestDesktopSnapshot)
    }

    /// Resolves legacy Assignments before the editor exposes any mutating action.
    /// One logical Display migrates automatically; multiple Displays produce a
    /// persistent, explicit choice. This path only reads topology and writes the
    /// app's JSON models — it never calls Apply or Arrange.
    private func prepareDisplayMigrationIfNeeded() -> Bool {
        guard AssignmentMigration.needsMigration(board: board, library: presetLibrary) else {
            pendingDisplayMigration = nil
            return false
        }
        do {
            let displays = try spacesAdapter.availableDisplays()
            guard !displays.isEmpty else {
                feedback = .failure("No active display was found for migrating saved Assignments.")
                return true
            }
            switch AssignmentMigration.plan(
                board: board,
                library: presetLibrary,
                availableDisplays: displays
            ) {
            case .notNeeded:
                pendingDisplayMigration = nil
                return false
            case let .requiresChoice(choices):
                pendingDisplayMigration = PendingDisplayMigration(displays: choices)
                feedback = .info("Choose the physical Display for your existing Assignments. Nothing will be Applied or Arranged.")
                return true
            case let .automatic(display):
                let snapshot = try spacesAdapter.desktopSnapshot(for: display)
                return !commitDisplayMigration(to: snapshot, automatic: true)
            }
        } catch {
            feedback = .failure("Could not migrate saved Assignments: \(error.localizedDescription)")
            return true
        }
    }

    /// Applies the user's accessible migration choice consistently to the working
    /// board, applied baseline, and every Preset, then permanently stores it.
    func chooseDisplayForMigration(_ display: DisplayIdentity) {
        guard pendingDisplayMigration?.displays.contains(where: {
            $0.identifiesSameDisplay(as: display)
        }) == true else {
            return
        }
        do {
            let snapshot = try spacesAdapter.desktopSnapshot(for: display)
            if commitDisplayMigration(to: snapshot, automatic: false) {
                pendingDisplayMigration = nil
                refreshDesktops()
            }
        } catch {
            feedback = .failure("Could not migrate saved Assignments: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func commitDisplayMigration(
        to snapshot: DesktopSnapshot,
        automatic: Bool
    ) -> Bool {
        do {
            let appliedDesktopUUIDs = try spacesAdapter.persistedDesktopUUIDs(
                for: Set(board.appliedAssignments.keys)
            )
            let migrated = AssignmentMigration.migrate(
                board: board,
                library: presetLibrary,
                to: snapshot,
                appliedDesktopUUIDs: appliedDesktopUUIDs
            )

            // Persist both complete values before exposing the migrated session.
            // If the second write fails, restore the original first document so
            // a later launch cannot observe a split migration choice.
            try presetLibraryStore.save(migrated.library)
            do {
                try boardStateStore.save(migrated.board)
            } catch {
                try? presetLibraryStore.save(presetLibrary)
                throw error
            }
            board = migrated.board
            presetLibrary = migrated.library
            latestDesktopSnapshot = snapshot
            pendingDisplayMigration = nil
            refreshPresets()
            feedback = .success(
                automatic
                    ? "Attached existing Assignments to \(snapshot.display?.lastKnownName ?? "the active Display"). Nothing was Applied or Arranged."
                    : "Attached existing Assignments to \(snapshot.display?.lastKnownName ?? "the chosen Display"). Nothing was Applied or Arranged."
            )
            return true
        } catch {
            feedback = .failure("Could not store migrated Assignments: \(error.localizedDescription)")
            return false
        }
    }
}

private struct SelectedApplication {
    let displayName: String
    let bundleIdentifier: String
}
