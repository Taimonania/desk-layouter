import AppKit
import DeskLayouterCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: EditorModel

    /// Quits Desk Layouter. Injected so the editor header's Quit button routes
    /// through the same lifecycle seam the menu bar uses (issue #40).
    let quit: () -> Void

    @State private var dropTargetDesktop: Int?
    @State private var searchFieldWidth: CGFloat = 0
    @State private var hoveredBundleIdentifier: String?
    @State private var editingLayoutCard: BoardCard?
    @State private var showingSavePresetSheet = false
    @State private var newPresetName = ""
    @State private var savePresetError: String?
    @State private var showingRenamePresetSheet = false
    @State private var renamePresetName = ""
    @State private var renamePresetError: String?

    private static let boardPadding: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                // Fixed header — always visible, never clipped by a scroll.
                header

                // Preset bar: choose/load a Preset, save the board as a new one,
                // or explicitly update the selected one. Loading only swaps the
                // working board — Apply and Arrange stay separate, explicit actions.
                presetBar

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
        .sheet(isPresented: $showingSavePresetSheet) {
            savePresetSheet
        }
        .sheet(isPresented: $showingRenamePresetSheet) {
            renamePresetSheet
        }
        .confirmationDialog(
            presetDeletionTitle,
            isPresented: Binding(
                get: { model.pendingPresetDeletion != nil },
                set: { presenting in if !presenting { model.cancelPresetDeletion() } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingPresetDeletion
        ) { pending in
            Button("Delete Preset", role: .destructive) {
                model.confirmDeletePreset()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Delete Preset \(pending.presetName)")

            Button("Cancel", role: .cancel) {
                model.cancelPresetDeletion()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel deleting Preset \(pending.presetName)")
        } message: { pending in
            Text(presetDeletionMessage(for: pending))
        }
        .confirmationDialog(
            presetSwitchTitle,
            isPresented: Binding(
                get: { model.pendingPresetSwitch != nil },
                set: { presenting in if !presenting { model.cancelPresetSwitch() } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingPresetSwitch
        ) { pending in
            Button("Update and Switch") {
                model.confirmUpdateAndSwitch()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Update Preset \(pending.currentPresetName) and switch to \(pending.targetName)")

            Button("Discard and Switch", role: .destructive) {
                model.confirmDiscardAndSwitch()
            }
            .accessibilityLabel("Discard changes to Preset \(pending.currentPresetName) and switch to \(pending.targetName)")

            Button("Cancel", role: .cancel) {
                model.cancelPresetSwitch()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel switching Presets and keep the current working copy")
        } message: { pending in
            Text("The board has unsaved changes to the Preset \"\(pending.currentPresetName)\". Choose whether to store them in \"\(pending.currentPresetName)\" before switching to \"\(pending.targetName)\". This never Applies or Arranges.")
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
            // Quit sits beside Refresh now that the menu-bar icon opens the editor
            // directly instead of presenting a menu (issue #40). Command-Q triggers
            // it while the editor is active. Quitting is immediate and unconfirmed;
            // pending edits are already stored, so nothing is lost.
            Button(role: .destructive) {
                quit()
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit Desk Layouter")
            .accessibilityLabel("Quit Desk Layouter")
        }
    }

    // MARK: - Presets

    private var presetBar: some View {
        HStack(spacing: 10) {
            Text("Preset")
                .foregroundStyle(.secondary)
            Menu {
                if model.presets.isEmpty {
                    Text("No Presets yet")
                } else {
                    ForEach(model.presets) { preset in
                        Button {
                            model.selectPreset(id: preset.id)
                        } label: {
                            if preset.id == model.selectedPresetID {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                }
            } label: {
                Text(model.presetSelectionName)
                    .frame(minWidth: 120, alignment: .leading)
            }
            .frame(width: 220)
            .help("Load a saved Preset as a working copy. Loading never Applies or Arranges.")
            .accessibilityLabel("Preset selector, currently \(model.presetSelectionName)")

            Button {
                newPresetName = ""
                savePresetError = nil
                showingSavePresetSheet = true
            } label: {
                Label("Save as Preset…", systemImage: "square.and.arrow.down")
            }
            .help("Save the current board as a new Preset")
            .accessibilityLabel("Save the current board as a new Preset")

            Button {
                model.updateSelectedPreset()
            } label: {
                Label("Update Preset", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!model.canUpdateSelectedPreset)
            .help("Update the selected Preset to match the current board")
            .accessibilityLabel("Update the selected Preset")

            Button {
                renamePresetName = model.presetSelectionName
                renamePresetError = nil
                showingRenamePresetSheet = true
            } label: {
                Label("Rename Preset…", systemImage: "pencil")
            }
            .disabled(!model.canRenameSelectedPreset)
            .help("Rename the selected Preset. This never Applies or Arranges.")
            .accessibilityLabel("Rename the selected Preset")

            Button(role: .destructive) {
                model.requestDeleteSelectedPreset()
            } label: {
                Label("Delete Preset…", systemImage: "trash")
            }
            .disabled(!model.canDeleteSelectedPreset)
            .help("Delete the selected Preset. Your working board is kept as Custom Setup.")
            .accessibilityLabel("Delete the selected Preset")

            Spacer(minLength: 0)
        }
    }

    private var presetDeletionTitle: String {
        if let pending = model.pendingPresetDeletion {
            return "Delete the Preset \"\(pending.presetName)\"?"
        }
        return "Delete this Preset?"
    }

    private func presetDeletionMessage(for pending: PendingPresetDeletion) -> String {
        // The header only ever deletes the selected Preset, so the working board
        // is kept as "Custom Setup". Nothing is Applied or Arranged.
        "This removes the saved Preset \"\(pending.presetName)\". Your current board is kept as \"Custom Setup\" — nothing is Applied or Arranged, and no windows move."
    }

    private var presetSwitchTitle: String {
        if let pending = model.pendingPresetSwitch {
            return "Save changes to \"\(pending.currentPresetName)\" before switching?"
        }
        return "Save changes before switching?"
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save as Preset")
                .font(.headline)
            Text("Captures every application on the board with its Assignment and Layout. It does not Apply or Arrange.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Preset name")
                .onSubmit(commitSavePreset)
                .onChange(of: newPresetName) { _ in savePresetError = nil }
            if let savePresetError {
                Text(savePresetError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(savePresetError)")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingSavePresetSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    commitSavePreset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Saves the board as a Preset. On success the sheet dismisses; on a rejected
    /// name (empty or a case-insensitive duplicate) the error is shown inline and
    /// the sheet stays open with the typed name intact, so a rejected name never
    /// silently replaces another Preset.
    private func commitSavePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            savePresetError = "Enter a name for the Preset."
            return
        }
        if let error = model.saveCurrentBoardAsPreset(named: name) {
            savePresetError = error
        } else {
            showingSavePresetSheet = false
        }
    }

    private var renamePresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Preset")
                .font(.headline)
            Text("Changes only the Preset's name and keeps everything it captured. It does not Apply or Arrange.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Preset name", text: $renamePresetName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("New Preset name")
                .onSubmit(commitRenamePreset)
                .onChange(of: renamePresetName) { _ in renamePresetError = nil }
            if let renamePresetError {
                Text(renamePresetError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(renamePresetError)")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingRenamePresetSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    commitRenamePreset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renamePresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Renames the selected Preset. On success the sheet dismisses; on a rejected
    /// name (empty or a case-insensitive duplicate) the error is shown inline and
    /// the sheet stays open with the typed name intact, so a rejected name never
    /// silently replaces another Preset or loses this one.
    private func commitRenamePreset() {
        let name = renamePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            renamePresetError = "Enter a name for the Preset."
            return
        }
        if let error = model.renameSelectedPreset(to: name) {
            renamePresetError = error
        } else {
            showingRenamePresetSheet = false
        }
    }

    // MARK: - Board

    @ViewBuilder
    private func board(availableWidth: CGFloat) -> some View {
        if model.columns.isEmpty, model.unavailableDesktops.isEmpty {
            Text("No Desktops were found on the active display.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            VStack(alignment: .leading, spacing: 18) {
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

                // Assignments stranded on Desktops that no longer exist stay
                // visible and recoverable here rather than being dropped (issue
                // #52). Each card can be moved to a Desktop that exists.
                if !model.unavailableDesktops.isEmpty {
                    unavailableDesktopsRegion(availableWidth: availableWidth)
                }
            }
        }
    }

    @ViewBuilder
    private func unavailableDesktopsRegion(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Unavailable Desktops")
                    .font(.headline)
            }
            Text("These Assignments target Desktops that don't exist right now. Nothing was dropped — move each app to a Desktop that exists to enable Apply. They reappear on their Desktop if it returns.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(
                columns: gridColumns(availableWidth: availableWidth),
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(model.unavailableDesktops) { section in
                    unavailableDesktopSection(section)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.4)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unavailable Desktops. These Assignments target Desktops that do not currently exist.")
    }

    private func unavailableDesktopSection(_ section: UnavailableDesktopSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.title)
                    .font(.headline)
                Spacer()
                Text("\(section.assignmentCount)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                    .accessibilityLabel("\(section.assignmentCount) Assignments")
            }
            ForEach(section.cards) { card in
                appCard(card)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title), \(section.assignmentCount) Assignments")
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
            Text(card.presentedName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(card.isApplicationAvailable ? Color.primary : Color.secondary)
            if !card.isApplicationAvailable {
                unavailableAppBadge
            }
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
        .accessibilityLabel(cardAccessibilityLabel(card))
        .accessibilityActions {
            Button(card.hasLayout ? "Edit Layout" : "Set Layout") { editingLayoutCard = card }
            moveButtons(for: card)
        }
    }

    /// A small badge marking a managed application that is not currently installed
    /// (issue #52). Its Assignment stays stored and visible; the badge tells the
    /// user why the app has no icon and won't be arranged until it is reinstalled.
    private var unavailableAppBadge: some View {
        Text("Not installed")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.22)))
            .foregroundStyle(.orange)
            .help("This app isn't installed right now. Its Assignment is kept and will take effect again if you reinstall the app.")
            .accessibilityHidden(true)
    }

    private func cardAccessibilityLabel(_ card: BoardCard) -> String {
        let availability = card.isApplicationAvailable ? "" : ", not installed"
        return "\(card.presentedName), Desktop \(card.desktopNumber)\(availability), \(card.hasLayout ? "has a Layout" : "no Layout"). Draggable"
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
        .accessibilityLabel(card.hasLayout ? "Edit Layout for \(card.presentedName)" : "Set Layout for \(card.presentedName)")
    }

    /// The freshest projection of a card by bundle identifier, so a sheet opened
    /// from a card always seeds from the current stored Layout rather than a stale
    /// capture.
    private func currentCard(for card: BoardCard) -> BoardCard? {
        let available = model.columns.flatMap(\.cards)
        let unavailable = model.unavailableDesktops.flatMap(\.cards)
        return (available + unavailable)
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
            .accessibilityLabel("Remove \(card.presentedName)")
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
                Text(application.presentedName)
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
        .accessibilityLabel("Add \(application.presentedName) to Desktop \(model.newAssignmentDesktopNumber)")
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

            // Arrange enacts Layouts on live windows. It is separate from Apply
            // (which writes Assignments) and, unlike Apply, is not gated on pending
            // changes — setting a Layout never dirties the board (issue #27).
            Button("Arrange") {
                model.arrange()
            }
            .disabled(!model.canArrange)
            .help("Arranges this Desktop now, and your other Desktops the first time you visit each.")
            .accessibilityHint("Arranges this Desktop now, and your other Desktops the first time you visit each.")

            if let explanation = model.applyBlockedExplanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(explanation)
            } else if model.pendingChangeCount > 0 {
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
