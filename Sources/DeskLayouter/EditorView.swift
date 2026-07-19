import AppKit
import DeskLayouterCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var dropTargetDesktop: Int?

    private static let boardPadding: CGFloat = 20

    /// Strips the ".app" bundle extension for display — users think in terms of
    /// application names ("Spotify"), not bundle file names ("Spotify.app").
    static func appDisplayName(_ rawName: String) -> String {
        rawName.lowercased().hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                // Fixed header — always visible, never clipped by a scroll.
                header

                // The Desktops board is the primary canvas: it gets the flexible
                // space and its own scroll region for when there are many
                // Desktops/apps. Apply sits directly beneath it.
                ScrollView(.vertical, showsIndicators: true) {
                    board(availableWidth: proxy.size.width - Self.boardPadding * 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                applyBar
                feedback

                Divider()

                // The installed-apps picker keeps the only other scroll region,
                // in its own bounded pane at the bottom — no scroll-within-scroll.
                addAssignment
            }
            .padding(Self.boardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(minWidth: 760, minHeight: 580)
        .onAppear { model.refresh() }
        // The Desktop list is a point-in-time snapshot; re-read it when the
        // active Space changes (e.g. the user just added or removed a Desktop in
        // Mission Control) so the board reflects Desktops added while it's open.
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.activeSpaceDidChangeNotification
            )
        ) { _ in
            model.refreshDesktops()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Desk Layouter")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Organize your applications across Desktops. Editing this board changes only Desk Layouter — macOS opens apps on their new Desktop only after you Apply.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-read the current Desktops and installed applications")
            .accessibilityLabel("Refresh Desktops and applications")
        }
    }

    // MARK: - Board

    @ViewBuilder
    private func board(availableWidth: CGFloat) -> some View {
        if model.columns.isEmpty {
            Text("No Desktops were found on the built-in display.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            LazyVGrid(
                columns: gridColumns(availableWidth: availableWidth),
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(model.columns) { column in
                    desktopColumn(column)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Flexible columns that stretch to fill the available width, but never more
    /// columns than there are Desktops — so e.g. three Desktops fill the row
    /// evenly instead of leaving a gap that reads as a reserved fourth slot. When
    /// the window is too narrow to fit every Desktop at a comfortable width, the
    /// extra Desktops wrap onto additional rows.
    private func gridColumns(availableWidth: CGFloat) -> [GridItem] {
        let minColumnWidth: CGFloat = 210
        let spacing: CGFloat = 14
        let usableWidth = max(availableWidth, minColumnWidth)
        let columnsThatFit = max(1, Int((usableWidth + spacing) / (minColumnWidth + spacing)))
        let columnCount = min(columnsThatFit, max(model.columns.count, 1))
        return Array(
            repeating: GridItem(.flexible(minimum: minColumnWidth), spacing: spacing),
            count: columnCount
        )
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
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
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
            Image(systemName: "line.3.horizontal")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            icon(for: card)
            Text(Self.appDisplayName(card.displayName))
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
        .contextMenu {
            moveButtons(for: card)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.displayName), Desktop \(card.desktopNumber). Draggable")
        .accessibilityActions {
            moveButtons(for: card)
        }
    }

    /// A pointer-free move path that mirrors the drag-and-drop affordance, shared by
    /// the card's context menu and its accessibility actions so the card can be moved
    /// between Desktops from the keyboard or assistive technology. The current Desktop
    /// is skipped since moving there is a no-op.
    @ViewBuilder
    private func moveButtons(for card: BoardCard) -> some View {
        ForEach(desktopNumbers, id: \.self) { number in
            if number != card.desktopNumber {
                Button("Move to Desktop \(number)") {
                    model.move(bundleIdentifier: card.bundleIdentifier, toDesktop: number)
                }
            }
        }
    }

    /// The Desktops the user can target, clamped to at least one so the UI never
    /// presents an empty range while the live Desktop count is still resolving.
    private var desktopNumbers: ClosedRange<Int> {
        1...max(model.desktopCount, 1)
    }

    private func cardControls(_ card: BoardCard) -> some View {
        HStack(spacing: 2) {
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
                    Text(Self.appDisplayName(application.displayName))
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
            .frame(height: 180)

            HStack {
                Text("Selected")
                Text(Self.appDisplayName(model.selectedApplicationName))
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
            ForEach(desktopNumbers, id: \.self) { number in
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
