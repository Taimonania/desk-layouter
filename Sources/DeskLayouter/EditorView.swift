import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Assignments")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Assign applications to the Desktop where macOS should open them. Only the apps you add here are ever changed.")
                .foregroundStyle(.secondary)

            currentAssignments

            Divider()

            addAssignment

            Button("Apply") {
                model.apply()
            }
            .keyboardShortcut(.defaultAction)

            Text("Already-running applications move to their Desktop only after you quit and relaunch them.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 560)
        .onAppear { model.refresh() }
    }

    private var currentAssignments: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Assignments")
                .font(.headline)

            if model.assignments.isEmpty {
                Text("No Assignments yet. Add one below.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.assignments) { assignment in
                    HStack {
                        Text(assignment.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        desktopPicker(
                            selection: Binding(
                                get: { assignment.desktopNumber },
                                set: { model.changeDesktop(forBundleIdentifier: assignment.bundleIdentifier, to: $0) }
                            )
                        )
                        .accessibilityLabel("Desktop for \(assignment.displayName)")
                        Button(role: .destructive) {
                            model.removeAssignment(bundleIdentifier: assignment.bundleIdentifier)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Remove \(assignment.displayName)")
                    }
                }
            }
        }
    }

    private var addAssignment: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an Assignment")
                .font(.headline)

            HStack {
                TextField("Search applications", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search applications")
                Toggle("Currently running", isOn: $model.showRunningOnly)
                    .toggleStyle(.checkbox)
            }

            List(
                model.visibleApplications,
                selection: Binding(
                    get: { model.selectedBundleIdentifier },
                    set: { model.selectApplication(withBundleIdentifier: $0) }
                )
            ) { application in
                HStack {
                    Text(application.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if application.isRunning {
                        Text("Running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(application.bundleIdentifier)
            }
            .frame(minHeight: 150)

            HStack {
                Text("Selected")
                Text(model.selectedApplicationName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                desktopPicker(selection: $model.newAssignmentDesktopNumber)
                    .accessibilityLabel("Desktop for the new Assignment")
                Button("Add") {
                    model.addAssignment()
                }
                .disabled(!model.canEditAssignments)
            }
        }
    }

    /// A Desktop chooser constrained to Desktops that currently exist on the
    /// built-in display, so the user can never pick a Desktop that isn't real.
    private func desktopPicker(selection: Binding<Int>) -> some View {
        Picker("Desktop", selection: selection) {
            ForEach(1...max(model.desktopCount, 1), id: \.self) { number in
                Text("Desktop \(number)").tag(number)
            }
        }
        .labelsHidden()
        .frame(width: 130)
        .disabled(!model.canEditAssignments)
    }
}
