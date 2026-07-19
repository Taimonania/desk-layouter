import DeskLayouterCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var dropTargetDesktop: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            board
            Divider()
            addAssignment
            applyBar
            feedback
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 580)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Desk Layouter")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Organize your applications across Desktops. Editing this board changes only Desk Layouter — macOS opens apps on their new Desktop only after you Apply.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Board

    private var board: some View {
        Group {
            if model.columns.isEmpty {
                Text("No Desktops were found on the built-in display.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(model.columns) { column in
                            desktopColumn(column)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 220)
            }
        }
    }

    private func desktopColumn(_ column: DesktopColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Desktop \(column.number)")
                    .font(.headline)
                Spacer()
                Text("\(column.assignmentCount)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .accessibilityLabel("\(column.assignmentCount) Assignments")
            }

            if column.cards.isEmpty {
                Text("No apps")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(column.cards) { card in
                    appCard(card)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 240, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(dropTargetDesktop == column.number ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    dropTargetDesktop == column.number ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
        .onDrop(
            of: [.plainText],
            isTargeted: Binding(
                get: { dropTargetDesktop == column.number },
                set: { targeted in dropTargetDesktop = targeted ? column.number : nil }
            )
        ) { providers in
            handleDrop(providers, onto: column.number)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Desktop \(column.number), \(column.assignmentCount) Assignments")
    }

    private func appCard(_ card: BoardCard) -> some View {
        HStack(spacing: 8) {
            icon(for: card)
            Text(card.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            cardControls(card)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
        .onDrag {
            NSItemProvider(object: card.bundleIdentifier as NSString)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.displayName), Desktop \(card.desktopNumber)")
    }

    private func cardControls(_ card: BoardCard) -> some View {
        HStack(spacing: 2) {
            Button {
                model.moveCard(bundleIdentifier: card.bundleIdentifier, by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(card.desktopNumber <= 1)
            .help("Move to the previous Desktop")
            .accessibilityLabel("Move \(card.displayName) to the previous Desktop")

            Button {
                model.moveCard(bundleIdentifier: card.bundleIdentifier, by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(card.desktopNumber >= model.desktopCount)
            .help("Move to the next Desktop")
            .accessibilityLabel("Move \(card.displayName) to the next Desktop")

            Button(role: .destructive) {
                model.removeAssignment(bundleIdentifier: card.bundleIdentifier)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this Assignment")
            .accessibilityLabel("Remove \(card.displayName)")
        }
    }

    @ViewBuilder
    private func icon(for card: BoardCard) -> some View {
        if let nsImage = model.icon(forBundleIdentifier: card.bundleIdentifier) {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], onto desktopNumber: Int) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let bundleIdentifier = object as? String else { return }
            Task { @MainActor in
                model.move(bundleIdentifier: bundleIdentifier, toDesktop: desktopNumber)
            }
        }
        return true
    }

    // MARK: - Add flow

    private var addAssignment: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an application")
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
            .frame(minHeight: 120)

            HStack {
                Text("Selected")
                Text(model.selectedApplicationName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                destinationPicker
                Button("Add") {
                    model.addAssignment()
                }
                .disabled(!model.canEditAssignments)
            }
        }
    }

    /// A destination-Desktop chooser constrained to Desktops that currently exist,
    /// so the user can never add an Assignment to a Desktop that isn't real.
    private var destinationPicker: some View {
        Picker("Destination Desktop", selection: $model.newAssignmentDesktopNumber) {
            ForEach(1...max(model.desktopCount, 1), id: \.self) { number in
                Text("Desktop \(number)").tag(number)
            }
        }
        .labelsHidden()
        .frame(width: 130)
        .disabled(!model.canEditAssignments)
        .accessibilityLabel("Destination Desktop for the new application")
    }

    // MARK: - Apply

    private var applyBar: some View {
        HStack(spacing: 12) {
            Button(applyTitle) {
                model.apply()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canApply)

            if model.pendingChangeCount > 0 {
                Text("^[\(model.pendingChangeCount) unapplied change](inflect: true)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No changes to apply.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var applyTitle: String {
        model.pendingChangeCount > 0 ? "Apply (\(model.pendingChangeCount))" : "Apply"
    }

    @ViewBuilder
    private var feedback: some View {
        if !model.statusMessage.isEmpty {
            Text(model.statusMessage)
                .font(.callout)
                .foregroundStyle(model.feedback.isFailure ? Color.red : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
