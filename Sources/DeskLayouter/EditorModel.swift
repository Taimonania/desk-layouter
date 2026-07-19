import AppKit
import DeskLayouterCore
import DeskLayouterMacOS

@MainActor
final class EditorModel: ObservableObject {
    @Published var desktopNumber = "1"
    @Published var searchText = ""
    @Published var showRunningOnly = false
    @Published private(set) var selectedBundleIdentifier: String?
    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var selectedApplicationName = "No application selected"
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
        // previously applied configuration on launch. A missing file loads as an
        // empty configuration; a read failure falls back to empty rather than
        // blocking launch.
        configuration = (try? configurationStore.load()) ?? DeskLayouterConfiguration()
        reflectLastManagedApplication()
        // The application list is loaded when the editor appears
        // (`refreshApplications()`), not here, so opening the window scans once
        // and re-scans on each reopen to keep the running state current.
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

    /// Re-enumerates installed and currently-running applications through the
    /// provider. Called on launch and whenever the editor is shown, so the
    /// running state stays current.
    func refreshApplications() {
        applications = applicationsProvider.applications()
    }

    /// Selects an application from the picker to feed into the Assignment.
    ///
    /// Driven by the list's selection binding: the selected bundle identifier is
    /// resolved against the loaded applications to capture the display name the
    /// Apply flow reports. A nil or unknown identifier (e.g. a stray deselect)
    /// is ignored, so the highlighted row and the chosen application stay in
    /// step and Apply always has something to act on.
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

    /// Reflects the most recently added managed application in the
    /// single-assignment editor, so a relaunch shows the previously saved
    /// configuration. The multi-assignment overview is issue #7.
    private func reflectLastManagedApplication() {
        guard let application = configuration.managedApplications.last else {
            return
        }
        selectedApplication = SelectedApplication(
            displayName: application.displayName,
            bundleIdentifier: application.bundleIdentifier
        )
        selectedApplicationName = application.displayName
        selectedBundleIdentifier = application.bundleIdentifier
        desktopNumber = String(application.desktopNumber)
    }

    func apply() {
        guard let selectedApplication else {
            statusMessage = "Choose an application before applying."
            return
        }
        guard let desktopNumber = Int(desktopNumber), desktopNumber > 0 else {
            statusMessage = "Enter a Desktop number greater than zero."
            return
        }

        do {
            let desktopSnapshot = try spacesAdapter.currentDesktopSnapshot()
            let assignment = Assignment(
                bundleIdentifier: selectedApplication.bundleIdentifier,
                desktopNumber: desktopNumber
            )
            // Surface the specific bad Desktop number for the just-chosen app
            // before touching the source of truth.
            _ = try assignmentPlanner.appBindings(for: assignment, on: desktopSnapshot)

            // Update and persist the JSON source of truth, then re-derive both
            // macOS representations from the full saved config so every managed
            // Assignment is applied and unmanaged bindings are left untouched.
            configuration.upsert(
                ManagedApplication(
                    bundleIdentifier: selectedApplication.bundleIdentifier,
                    displayName: selectedApplication.displayName,
                    desktopNumber: desktopNumber
                )
            )
            try configurationStore.save(configuration)

            let appBindings = assignmentPlanner.appBindings(
                for: configuration.assignments,
                on: desktopSnapshot
            )
            try spacesAdapter.apply(appBindings: appBindings)
            statusMessage = "Applied \(selectedApplication.displayName) to Desktop \(desktopNumber). Quit and relaunch it to see the Assignment take effect."
        } catch AssignmentPlanningError.desktopDoesNotExist {
            statusMessage = "Desktop \(desktopNumber) does not exist on the built-in display."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct SelectedApplication {
    let displayName: String
    let bundleIdentifier: String
}
