import AppKit
import DeskLayouterCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var dropTargetDesktop: Int?
    @State private var searchFieldWidth: CGFloat = 0
    @State private var hoveredBundleIdentifier: String?
    @State private var editingLayoutCard: BoardCard?

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

                // Search-to-add control row: type to filter installed apps; the
                // results panel floats over the board just below (see the ZStack).
                quickAdd

                // The Desktops board is the primary canvas and takes the rest of
                // the height. The search results float over it as a ZStack layer,
                // so showing results never pushes the board down. Apply sits below.
                ZStack(alignment: .topLeading) {
                    ScrollView(.vertical, showsIndicators: true) {
                        board(availableWidth: proxy.size.width - Self.boardPadding * 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !model.searchText.isEmpty {
                        resultsDropdown
                            .frame(width: searchFieldWidth > 0 ? searchFieldWidth : 380, alignment: .leading)
                            .padding(.top, 4)
                            .zIndex(1)
                    }
                }
                .frame(maxHeight: .infinity)

                applyBar
                feedback
            }
            .padding(Self.boardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(minWidth: 760, minHeight: 640)
        .sheet(item: $editingLayoutCard) { card in
            LayoutEditorView(model: model, card: currentCard(for: card) ?? card)
        }
        .onPreferenceChange(SearchFieldWidthKey.self) { searchFieldWidth = $0 }
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
            Text("No Desktops were found on the active display.")
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
            layoutButton(card)
            cardControls(card)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        // Cards with a Layout carry a faint accent border so apps that have a
        // Layout are distinguishable at a glance from those that do not (which get
        // the neutral border).
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(
                card.hasLayout ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2),
                lineWidth: card.hasLayout ? 1.5 : 1
            )
        )
        .onDrag {
            NSItemProvider(object: card.bundleIdentifier as NSString)
        }
        .contextMenu {
            Button(card.hasLayout ? "Edit Layout…" : "Set Layout…") {
                editingLayoutCard = card
            }
            Divider()
            moveButtons(for: card)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.appDisplayName(card.displayName)), Desktop \(card.desktopNumber), \(card.hasLayout ? "has a Layout" : "no Layout"). Draggable")
        .accessibilityActions {
            Button(card.hasLayout ? "Edit Layout" : "Set Layout") { editingLayoutCard = card }
            moveButtons(for: card)
        }
    }

    /// The Layout affordance on a card: a live mini-grid preview when the app has a
    /// Layout, or a dashed grid glyph when it does not. Either way it opens the
    /// Layout editor, so the Layout is both shown and editable in one place.
    private func layoutButton(_ card: BoardCard) -> some View {
        Button {
            editingLayoutCard = card
        } label: {
            if let layout = card.layout {
                LayoutGridPreview(layout: layout, cellSize: 5, spacing: 1)
            } else {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help(card.hasLayout ? "Edit this app's Layout" : "Set a Layout for this app")
        .accessibilityLabel(card.hasLayout ? "Edit Layout for \(Self.appDisplayName(card.displayName))" : "Set Layout for \(Self.appDisplayName(card.displayName))")
    }

    /// The freshest projection of a card by bundle identifier, so a sheet opened
    /// from a card always seeds from the current stored Layout rather than a stale
    /// capture.
    private func currentCard(for card: BoardCard) -> BoardCard? {
        model.columns
            .flatMap(\.cards)
            .first { $0.bundleIdentifier == card.bundleIdentifier }
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
            .accessibilityLabel("Remove \(Self.appDisplayName(card.displayName))")
        }
    }

    private func icon(for card: BoardCard) -> some View {
        iconView(forBundleIdentifier: card.bundleIdentifier)
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

    // MARK: - Search-to-add

    private var quickAdd: some View {
        HStack(spacing: 10) {
            searchField
            Toggle("Running only", isOn: $model.showRunningOnly)
                .toggleStyle(.checkbox)
                .fixedSize()
                .disabled(!model.canEditAssignments)
            Text("Add to")
                .foregroundStyle(.secondary)
            destinationPicker
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search applications to add", text: $model.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search applications to add")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SearchFieldWidthKey.self, value: proxy.size.width)
            }
        )
        .onExitCommand { model.searchText = "" }
    }

    /// Floating, scrollable results panel shown while searching. Clicking a row
    /// adds that app to the chosen Desktop and clears the search.
    private var resultsDropdown: some View {
        let matches = model.visibleApplications
        return VStack(spacing: 0) {
            if matches.isEmpty {
                Text("No matching applications")
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.bundleIdentifier) { index, application in
                            resultRow(application)
                            if index < matches.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 200) // ~5 rows tall, then scrolls
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func resultRow(_ application: InstalledApplication) -> some View {
        Button {
            model.selectApplication(withBundleIdentifier: application.bundleIdentifier)
            model.addAssignment()
            model.searchText = ""
        } label: {
            HStack(spacing: 8) {
                iconView(forBundleIdentifier: application.bundleIdentifier)
                Text(Self.appDisplayName(application.displayName))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if application.isRunning {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Running")
                }
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                hoveredBundleIdentifier == application.bundleIdentifier
                    ? Color.primary.opacity(0.06) : Color.clear
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.canEditAssignments)
        .onHover { isHovering in
            if isHovering {
                hoveredBundleIdentifier = application.bundleIdentifier
            } else if hoveredBundleIdentifier == application.bundleIdentifier {
                hoveredBundleIdentifier = nil
            }
        }
        .accessibilityLabel("Add \(Self.appDisplayName(application.displayName)) to Desktop \(model.newAssignmentDesktopNumber)")
    }

    @ViewBuilder
    private func iconView(forBundleIdentifier bundleIdentifier: String, size: CGFloat = 20) -> some View {
        if let nsImage = model.icon(forBundleIdentifier: bundleIdentifier) {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
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

/// Reports the search field's rendered width so the floating results dropdown can
/// be sized to match it.
private struct SearchFieldWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
