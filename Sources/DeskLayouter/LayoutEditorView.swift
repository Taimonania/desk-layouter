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
                        layoutGridCell(occupied: layout.occupies(column: column, row: row), cellSize: cellSize)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The one mini-grid cell shape shared by the read-only ``LayoutGridPreview`` and
/// the interactive ``InteractiveLayoutGrid``, so both paint cells identically and
/// a change to cell appearance happens in one place.
@ViewBuilder
func layoutGridCell(occupied: Bool, cellSize: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cellSize > 10 ? 3 : 1)
        .fill(occupied ? Color.accentColor : Color.secondary.opacity(0.22))
        .frame(width: cellSize, height: cellSize)
}

/// A direct-manipulation version of ``LayoutGridPreview`` bound to a
/// ``LayoutDraft``: clicking a cell selects that single cell, and pressing on one
/// cell and dragging to another selects the inclusive rectangle between them
/// (either drag direction). Every selection routes through the draft's pure
/// ``LayoutDraft/selectCells(fromColumn:fromRow:toColumn:toRow:)`` seam, so it is
/// always one continuous, valid rectangle and stays in lock-step with the
/// first/last controls that bind to the same draft. Row 0 is the top, matching
/// the on-screen orientation. Works for Full axes too — a Full axis resolves any
/// interaction to its single cell.
struct InteractiveLayoutGrid: View {
    @Binding var draft: LayoutDraft
    var cellSize: CGFloat = 26
    var spacing: CGFloat = 2

    private var columns: Int { draft.horizontalDivision.cellCount }
    private var rows: Int { draft.verticalDivision.cellCount }
    private var metrics: LayoutGridMetrics { LayoutGridMetrics(cellSize: cellSize, spacing: spacing) }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(column: column, row: row)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    draft.selectCells(
                        fromColumn: metrics.cellIndex(at: value.startLocation.x, cellCount: columns),
                        fromRow: metrics.cellIndex(at: value.startLocation.y, cellCount: rows),
                        toColumn: metrics.cellIndex(at: value.location.x, cellCount: columns),
                        toRow: metrics.cellIndex(at: value.location.y, cellCount: rows)
                    )
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout grid")
    }

    private func cell(column: Int, row: Int) -> some View {
        let occupied = draft.isCellOccupied(column: column, row: row)
        return layoutGridCell(occupied: occupied, cellSize: cellSize)
            .accessibilityElement()
            .accessibilityLabel("Column \(column + 1) of \(columns), row \(row + 1) of \(rows)")
            .accessibilityAddTraits(occupied ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Selects this cell")
            .accessibilityAction { draft.selectCell(column: column, row: row) }
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
                Text("Where \(card.presentedName)'s window sits on Desktop \(card.desktopNumber). Use Arrange to move the window into it.")
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
                isFull: draft.isHorizontalFull,
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
                isFull: draft.isVerticalFull,
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
    /// row-0-at-top orientation explicit. A Full axis (`isFull`) covers its whole
    /// extent in one cell, so it hides the first/last pickers — there is nothing
    /// to choose.
    @ViewBuilder
    private func axisControls(
        title: String,
        division: Binding<Division>,
        cellCount: Int,
        isFull: Bool,
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

            if !isFull {
                HStack(spacing: 10) {
                    cellPicker(label: startLabel, selection: start, cellCount: cellCount, topMarker: topMarker)
                    cellPicker(label: endLabel, selection: end, cellCount: cellCount, topMarker: topMarker)
                }
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
            InteractiveLayoutGrid(draft: $draft, cellSize: 26)
            Text("Click or drag to select")
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
        case .full: "Full"
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
