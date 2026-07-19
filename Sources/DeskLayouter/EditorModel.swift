import AppKit
import DeskLayouterCore
import DeskLayouterMacOS

/// One Assignment shown in the editor's overview list.
struct AssignmentRow: Identifiable, Equatable {
    let bundleIdentifier: String
    let displayName: String
    let desktopNumber: Int

    var id: String { bundleIdentifier }
}

@MainActor
final class EditorModel: ObservableObject {
    // Add-flow inputs (the #6 picker plus the chosen Desktop).
    @Published var searchText = ""
    @Published var showRunningOnly = false
    @Published var newAssignmentDesktopNumber = 1
    @Published private(set) var selectedBundleIdentifier: String?
    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var selectedApplicationName = "No application selected"

    // Overview + constraints.
    @Published private(set) var assignments: [AssignmentRow] = []
    @Published private(set) var desktopCount = 0
    @Published private(set) var statusMessage = ""

    private let assignmentPlanner: AssignmentPlanner
    private let spacesAdapter: any SpacesAdapter
    private let configurationStore: ConfigurationStore
    private let applicationsProvider: any InstalledApplicationsProviding
    private var configuration: DeskLayouterConfiguration
    private var selectedApplication: SelectedApplication?

    init(
        assignmentPlanner: AssignmentPlanner = AssignmentPlanner(),
        spacesAdapter: any SpacesAdapter = MacOSSpacesAdapter(),
        configurationStore: ConfigurationStore = .default,
        applicationsProvider: any InstalledApplicationsProviding = SystemInstalledApplicationsProvider()
    ) {
        self.assignmentPlanner = assignmentPlanner
        self.spacesAdapter = spacesAdapter
        self.configurationStore = configurationStore
        self.applicationsProvider = applicationsProvider
        // Load the saved source-of-truth config so the editor reflects the
        // previously applied Assignments on launch. A missing file loads as an
        // empty configuration; a read failure falls back to empty rather than
        // blocking launch.
        configuration = (try? configurationStore.load()) ?? DeskLayouterConfiguration()
        syncAssignments()
        // The application list and Desktop snapshot are loaded when the editor
        // appears (`refresh()`), not here, so opening the window scans once and
        // re-scans on each reopen to keep both current.
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

    /// Reads the current Desktops on the built-in display so Desktop choices are
    /// constrained to Desktops that actually exist. A read failure surfaces the
    /// adapter's error and disables adding rather than offering invalid Desktops.
    func refreshDesktops() {
        do {
            let snapshot = try spacesAdapter.currentDesktopSnapshot()
            desktopCount = snapshot.orderedDesktopUUIDs.count
            newAssignmentDesktopNumber = min(max(newAssignmentDesktopNumber, 1), max(desktopCount, 1))
        } catch {
            desktopCount = 0
            statusMessage = error.localizedDescription
        }
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
        statusMessage = ""
    }

    /// Adds the picked application at the chosen Desktop as a new Assignment (or
    /// updates it if the app is already managed). Persists the source of truth so
    /// the change survives relaunch; macOS is only touched on Apply.
    func addAssignment() {
        guard let selectedApplication else {
            statusMessage = "Choose an application to assign."
            return
        }
        guard canEditAssignments else {
            statusMessage = "No Desktops are available on the built-in display."
            return
        }
        guard (1...desktopCount).contains(newAssignmentDesktopNumber) else {
            statusMessage = desktopDoesNotExistMessage(newAssignmentDesktopNumber)
            return
        }

        configuration.upsert(
            ManagedApplication(
                bundleIdentifier: selectedApplication.bundleIdentifier,
                displayName: selectedApplication.displayName,
                desktopNumber: newAssignmentDesktopNumber
            )
        )
        persist(
            successMessage: "Added \(selectedApplication.displayName) → Desktop \(newAssignmentDesktopNumber). Click Apply to enforce it."
        )
    }

    /// Changes an existing managed Assignment to a different Desktop.
    func changeDesktop(forBundleIdentifier bundleIdentifier: String, to desktopNumber: Int) {
        guard let application = configuration.managedApplication(for: bundleIdentifier) else {
            return
        }
        // `canEditAssignments` short-circuits before the range is formed, so a
        // failed Desktop snapshot (`desktopCount == 0`) can never build `1...0`.
        guard canEditAssignments, (1...desktopCount).contains(desktopNumber) else {
            statusMessage = desktopDoesNotExistMessage(desktopNumber)
            return
        }
        configuration.upsert(
            ManagedApplication(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.displayName,
                desktopNumber: desktopNumber
            )
        )
        persist(
            successMessage: "Changed \(application.displayName) → Desktop \(desktopNumber). Click Apply to enforce it."
        )
    }

    /// Removes an Assignment. The app returns to unassigned on the next Apply,
    /// which deletes only its owned key from the macOS bindings.
    func removeAssignment(bundleIdentifier: String) {
        guard let application = configuration.managedApplication(for: bundleIdentifier) else {
            return
        }
        configuration.remove(bundleIdentifier: bundleIdentifier)
        persist(
            successMessage: "Removed \(application.displayName). Click Apply to return it to opening wherever."
        )
    }

    /// Applies every managed Assignment to both macOS representations.
    ///
    /// The complete post-change persistent dictionary and the current-session
    /// update are computed inside the adapter from the saved source of truth:
    /// the planner resolves managed Desktop numbers to UUIDs (skipping Desktops
    /// that no longer exist), and the full set of managed bundle identifiers is
    /// handed over as the ownership set so removed Assignments delete only their
    /// own keys.
    func apply() {
        do {
            let snapshot = try spacesAdapter.currentDesktopSnapshot()
            let managedBindings = assignmentPlanner.appBindings(
                for: configuration.assignments,
                on: snapshot
            )
            try spacesAdapter.apply(
                managedBindings: managedBindings,
                managedBundleIdentifiers: configuration.ownedBundleIdentifiers
            )
            // The removed apps' keys are now gone from both representations, so
            // forget them and persist the cleared source of truth.
            configuration.clearPendingRemovals()
            let count = configuration.managedApplications.count
            let noun = count == 1 ? "Assignment" : "Assignments"
            var message = "Applied \(count) \(noun). Already-running applications use their new Desktop only after you quit and relaunch them."
            do {
                try configurationStore.save(configuration)
            } catch {
                // Apply itself succeeded; only the bookkeeping save failed. Say so
                // rather than hiding it — the removed keys are simply re-deleted
                // (idempotently) on the next Apply.
                message += " (Could not save configuration: \(error.localizedDescription))"
            }
            statusMessage = message
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Saves the source of truth and refreshes the overview, reporting a save
    /// failure rather than silently losing the edit.
    private func persist(successMessage: String) {
        do {
            try configurationStore.save(configuration)
            syncAssignments()
            statusMessage = successMessage
        } catch {
            statusMessage = "Could not save the configuration: \(error.localizedDescription)"
        }
    }

    private func desktopDoesNotExistMessage(_ desktopNumber: Int) -> String {
        "Desktop \(desktopNumber) does not exist on the built-in display."
    }

    private func syncAssignments() {
        assignments = configuration.managedApplications.map {
            AssignmentRow(
                bundleIdentifier: $0.bundleIdentifier,
                displayName: $0.displayName,
                desktopNumber: $0.desktopNumber
            )
        }
    }
}

private struct SelectedApplication {
    let displayName: String
    let bundleIdentifier: String
}
