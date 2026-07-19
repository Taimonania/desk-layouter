import AppKit
import DeskLayouterCore
import DeskLayouterMacOS
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    @Published var desktopNumber = "1"
    @Published private(set) var selectedApplicationName = "No application selected"
    @Published private(set) var statusMessage = ""

    private let assignmentPlanner: AssignmentPlanner
    private let spacesAdapter: any SpacesAdapter
    private var selectedApplication: SelectedApplication?

    init(
        assignmentPlanner: AssignmentPlanner = AssignmentPlanner(),
        spacesAdapter: any SpacesAdapter = MacOSSpacesAdapter()
    ) {
        self.assignmentPlanner = assignmentPlanner
        self.spacesAdapter = spacesAdapter
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.message = "Choose the application to assign to a Desktop."
        panel.prompt = "Choose Application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let applicationURL = panel.url else {
            return
        }

        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            statusMessage = "That application does not have a bundle identifier."
            return
        }

        let displayName = FileManager.default.displayName(atPath: applicationURL.path)
        selectedApplication = SelectedApplication(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier
        )
        selectedApplicationName = displayName
        statusMessage = ""
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
            let appBindings = try assignmentPlanner.appBindings(
                for: assignment,
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
