import SwiftUI

/// The full-window Settings screen (issue #71). It replaces the board in the same
/// window rather than opening a sheet or a separate window, reusing the in-window
/// screen-swap navigation. Today it hosts a single control — whether updates
/// install automatically or ask first — and a "Done" control that returns to the
/// board.
struct SettingsView: View {
    @ObservedObject var model: AppRootModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                Button("Done") {
                    model.showBoard()
                }
                .keyboardShortcut(.defaultAction)
                .help("Return to the board")
                .accessibilityLabel("Done, return to the board")
            }

            Form {
                Picker(
                    "Software updates",
                    selection: Binding(
                        get: { model.automaticallyInstallUpdates },
                        set: { model.automaticallyInstallUpdates = $0 }
                    )
                ) {
                    Text("Ask before installing").tag(false)
                    Text("Automatically install updates").tag(true)
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Software update installation")
            }

            Text("Desk Layouter always checks for updates automatically. This setting only controls whether an available update installs on its own. Changes take effect the next time you launch Desk Layouter.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 760, minHeight: 640)
    }
}
