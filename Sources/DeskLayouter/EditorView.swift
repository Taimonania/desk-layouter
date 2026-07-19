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

            HStack {
                Button("Choose Application…") {
                    model.chooseApplication()
                }
                Text(model.selectedApplicationName)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 300)
    }
}
