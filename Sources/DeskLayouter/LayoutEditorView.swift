import DeskLayouterCore
import SwiftUI

/// A mini grid that paints a ``Layout`` as its division and highlights the cells
/// the window occupies. Row 0 is drawn at the top, matching the on-screen
/// orientation, so a "last third" span lights the bottom row — the small visual
/// indication the editor and cards use to show what a Layout means.
struct LayoutGridPreview: View {
    let layout: DeskLayouterCore.Layout
    var cellSize: CGFloat = 22
    var spacing: CGFloat = 2

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<layout.verticalDivision.cellCount, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<layout.horizontalDivision.cellCount, id: \.self) { column in
                        RoundedRectangle(cornerRadius: cellSize > 10 ? 3 : 1)
                            .fill(
                                layout.occupies(column: column, row: row)
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.22)
                            )
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Sheet that gives one managed application a ``Layout`` (or clears it). All the
/// clamping/validity logic lives in the pure ``LayoutDraft``; this view is just
/// the controls and a live mini-grid preview bound to it.
struct LayoutEditorView: View {
    @ObservedObject var model: EditorModel
    let card: BoardCard
    @Environment(\.dismiss) private var dismiss

    @State private var draft: LayoutDraft

    init(model: EditorModel, card: BoardCard) {
        self.model = model
        self.card = card
        _draft = State(initialValue: card.layout.map(LayoutDraft.init) ?? LayoutDraft())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Layout")
                    .font(.headline)
                Text("Where \(EditorView.appDisplayName(card.displayName))'s window sits on Desktop \(card.desktopNumber). Use Arrange to move the window into it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 24) {
                controls
                preview
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            axisControls(
                title: "Columns (left → right)",
                division: divisionBinding({ $0.horizontalDivision }, { $0.setHorizontalDivision($1) }),
                cellCount: draft.horizontalDivision.cellCount,
                startLabel: "First column",
                endLabel: "Last column",
                start: intBinding({ $0.columnSpan.start }, { $0.setColumnStart($1) }),
                end: intBinding({ $0.columnSpan.end }, { $0.setColumnEnd($1) }),
                topMarker: nil
            )
            axisControls(
                title: "Rows (top → bottom)",
                division: divisionBinding({ $0.verticalDivision }, { $0.setVerticalDivision($1) }),
                cellCount: draft.verticalDivision.cellCount,
                startLabel: "First row",
                endLabel: "Last row",
                start: intBinding({ $0.rowSpan.start }, { $0.setRowStart($1) }),
                end: intBinding({ $0.rowSpan.end }, { $0.setRowEnd($1) }),
                topMarker: 0
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One axis block: its division segmented control plus start/end cell pickers.
    /// `topMarker` names the index that should read "(top)" so rows make their
    /// row-0-at-top orientation explicit.
    @ViewBuilder
    private func axisControls(
        title: String,
        division: Binding<Division>,
        cellCount: Int,
        startLabel: String,
        endLabel: String,
        start: Binding<Int>,
        end: Binding<Int>,
        topMarker: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Picker("Division", selection: division) {
                ForEach(Division.allCases, id: \.self) { option in
                    Text(Self.divisionName(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                cellPicker(label: startLabel, selection: start, cellCount: cellCount, topMarker: topMarker)
                cellPicker(label: endLabel, selection: end, cellCount: cellCount, topMarker: topMarker)
            }
        }
    }

    private func cellPicker(label: String, selection: Binding<Int>, cellCount: Int, topMarker: Int?) -> some View {
        Picker(label, selection: selection) {
            ForEach(0..<cellCount, id: \.self) { index in
                Text(cellTitle(index, topMarker: topMarker)).tag(index)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 6) {
            LayoutGridPreview(layout: draft.layout, cellSize: 26)
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if card.hasLayout {
                Button("Clear Layout", role: .destructive) {
                    model.setLayout(nil, forBundleIdentifier: card.bundleIdentifier)
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                model.setLayout(draft.layout, forBundleIdentifier: card.bundleIdentifier)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Binding helpers

    /// Bindings that route every mutation through the pure ``LayoutDraft`` setters
    /// so the draft's clamping invariants hold no matter what the controls emit.
    private func divisionBinding(
        _ get: @escaping (LayoutDraft) -> Division,
        _ set: @escaping (inout LayoutDraft, Division) -> Void
    ) -> Binding<Division> {
        Binding(get: { get(draft) }, set: { newValue in
            var copy = draft
            set(&copy, newValue)
            draft = copy
        })
    }

    private func intBinding(
        _ get: @escaping (LayoutDraft) -> Int,
        _ set: @escaping (inout LayoutDraft, Int) -> Void
    ) -> Binding<Int> {
        Binding(get: { get(draft) }, set: { newValue in
            var copy = draft
            set(&copy, newValue)
            draft = copy
        })
    }

    // MARK: - Labels

    private static func divisionName(_ division: Division) -> String {
        switch division {
        case .halves: "Halves"
        case .thirds: "Thirds"
        case .fourths: "Fourths"
        }
    }

    private func cellTitle(_ index: Int, topMarker: Int?) -> String {
        if index == topMarker {
            return "\(index + 1) (top)"
        }
        return "\(index + 1)"
    }
}
