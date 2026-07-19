import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Assignment")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose one installed application and the Desktop where macOS should open it.")
                .foregroundStyle(.secondary)

            applicationPicker

            HStack {
                Text("Selected")
                Text(model.selectedApplicationName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Desktop")
                TextField("Number", text: $model.desktopNumber)
                    .frame(width: 80)
                    .accessibilityLabel("Desktop number")
            }

            Button("Apply") {
                model.apply()
            }
            .keyboardShortcut(.defaultAction)

            Text("Already-running applications move only after you quit and relaunch them.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { model.refreshApplications() }
    }

    private var applicationPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            .frame(minHeight: 160)
        }
    }
}
