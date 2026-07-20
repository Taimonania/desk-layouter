import DeskLayouterCore

@main
struct LayoutDraftTestRunner {
    static func main() {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok: \(name)")
            } else {
                let detailText = detail()
                let suffix = detailText.isEmpty ? "" : " — \(detailText)"
                failures.append("\(name)\(suffix)")
                print("  FAIL: \(name)\(suffix)")
            }
        }

        // Default draft: a fresh draft is a valid Layout (left half of a
        // halves×halves grid) so the editor always opens on something arrangeable.
        do {
            let draft = LayoutDraft()
            check("default draft builds a valid Layout", draft.layout.isValid)
            check("default draft divides into halves both ways",
                  draft.horizontalDivision == .halves && draft.verticalDivision == .halves)
            check("default draft occupies the left half",
                  draft.columnSpan == .single(0) && draft.rowSpan == LayoutSpan(start: 0, end: 1),
                  "cols \(draft.columnSpan), rows \(draft.rowSpan)")
        }

        // Seeding round-trips a valid Layout unchanged, so opening the editor on an
        // app that has a Layout shows exactly its stored Layout.
        do {
            let layout = Layout(
                horizontalDivision: .thirds,
                verticalDivision: .fourths,
                columnSpan: LayoutSpan(start: 1, end: 2),
                rowSpan: .single(3)
            )
            let draft = LayoutDraft(layout)
            check("seeding a valid Layout round-trips it", draft.layout == layout, "got \(draft.layout)")
        }

        // Seeding an out-of-bounds Layout (tolerantly decoded / hand-authored)
        // clamps it into range so the draft is always valid.
        do {
            let bogus = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: LayoutSpan(start: 2, end: 5),
                rowSpan: LayoutSpan(start: -3, end: 9)
            )
            let draft = LayoutDraft(bogus)
            check("seeding an out-of-bounds Layout yields a valid draft", draft.layout.isValid,
                  "got \(draft.layout)")
            check("clamped column span sits inside halves",
                  draft.columnSpan == .single(1), "got \(draft.columnSpan)")
            check("clamped row span sits inside halves",
                  draft.rowSpan == LayoutSpan(start: 0, end: 1), "got \(draft.rowSpan)")
        }

        // Reducing a division re-clamps a span that reached a now-removed cell.
        do {
            var draft = LayoutDraft(
                Layout(
                    horizontalDivision: .fourths,
                    verticalDivision: .halves,
                    columnSpan: LayoutSpan(start: 2, end: 3),
                    rowSpan: .single(0)
                )
            )
            draft.setHorizontalDivision(.halves)
            check("shrinking the division clamps the span into range", draft.columnSpan.end <= 1,
                  "got \(draft.columnSpan)")
            check("clamped span stays non-empty and valid", draft.layout.isValid, "got \(draft.layout)")
        }

        // Growing a division leaves an already-valid span untouched.
        do {
            var draft = LayoutDraft(
                Layout(
                    horizontalDivision: .halves,
                    verticalDivision: .halves,
                    columnSpan: .single(0),
                    rowSpan: .single(0)
                )
            )
            draft.setHorizontalDivision(.fourths)
            check("growing the division preserves the existing span", draft.columnSpan == .single(0),
                  "got \(draft.columnSpan)")
        }

        // Moving a span's start past its end drags the end along (and vice versa),
        // so the span never inverts as the user edits the two ends independently.
        do {
            var draft = LayoutDraft()
            draft.setHorizontalDivision(.fourths) // columnSpan clamps to single(0)
            draft.setColumnEnd(2)
            check("setting the end widens the span", draft.columnSpan == LayoutSpan(start: 0, end: 2),
                  "got \(draft.columnSpan)")
            draft.setColumnStart(3)
            check("start past end drags the end with it", draft.columnSpan == .single(3),
                  "got \(draft.columnSpan)")
            draft.setColumnEnd(1)
            check("end before start drags the start with it", draft.columnSpan == .single(1),
                  "got \(draft.columnSpan)")
        }

        // Out-of-range end/start setters clamp rather than producing an invalid span.
        do {
            var draft = LayoutDraft()
            draft.setRowEnd(99)
            draft.setRowStart(-4)
            check("row setters clamp into the division", draft.layout.isValid, "got \(draft.rowSpan)")
            check("row span fills the halves it was pushed against",
                  draft.rowSpan == LayoutSpan(start: 0, end: 1), "got \(draft.rowSpan)")
        }

        // Mini-grid mapping: the occupancy the preview paints matches the span,
        // and honors row 0 = top (a "last row" span lights the bottom row).
        do {
            var draft = LayoutDraft()
            draft.setVerticalDivision(.thirds)
            draft.setRowStart(2)
            draft.setRowEnd(2) // last (bottom) third only
            check("an occupied cell reads true", draft.isCellOccupied(column: 0, row: 2))
            check("top row is not occupied for a last-third span", draft.isCellOccupied(column: 0, row: 0) == false)
            check("cell outside the column span reads false", draft.isCellOccupied(column: 1, row: 2) == false)
            check("draft occupancy matches its Layout's",
                  draft.isCellOccupied(column: 0, row: 2) == draft.layout.occupies(column: 0, row: 2))
        }

        // Setting an axis to Full collapses it to its single cell, and the draft
        // reports the axis as full so the editor can hide its first/last controls.
        do {
            var draft = LayoutDraft(
                Layout(
                    horizontalDivision: .fourths,
                    verticalDivision: .halves,
                    columnSpan: LayoutSpan(start: 1, end: 3),
                    rowSpan: .single(1)
                )
            )
            draft.setHorizontalDivision(.full)
            check("a Full axis collapses to its single cell",
                  draft.columnSpan == .single(0), "got \(draft.columnSpan)")
            check("a Full axis builds a valid Layout", draft.layout.isValid)
            check("the draft reports the horizontal axis as full", draft.isHorizontalFull)
            check("the vertical axis is not full", draft.isVerticalFull == false)
        }

        // Switching a Full axis back to a divided one starts at the leftmost
        // column / top row (index 0), regardless of where the span sat before.
        do {
            var draft = LayoutDraft(
                Layout(
                    horizontalDivision: .fourths,
                    verticalDivision: .halves,
                    columnSpan: .single(3),
                    rowSpan: .single(1)
                )
            )
            draft.setHorizontalDivision(.full)
            draft.setHorizontalDivision(.thirds)
            check("switching Full → Thirds selects the leftmost column",
                  draft.columnSpan == .single(0), "got \(draft.columnSpan)")

            draft.setVerticalDivision(.full)
            draft.setVerticalDivision(.fourths)
            check("switching Full → Fourths selects the top row",
                  draft.rowSpan == .single(0), "got \(draft.rowSpan)")
        }

        // A Layout seeded from a Full-axis Layout round-trips unchanged.
        do {
            let layout = Layout(
                horizontalDivision: .full,
                verticalDivision: .thirds,
                columnSpan: .single(0),
                rowSpan: .single(2)
            )
            let draft = LayoutDraft(layout)
            check("seeding a Full-axis Layout round-trips it", draft.layout == layout,
                  "got \(draft.layout)")
            check("seeded Full axis reports as full", draft.isHorizontalFull)
        }

        // Direct selection — clicking a single cell selects exactly that cell on
        // both axes, replacing whatever span was there before.
        do {
            var draft = LayoutDraft(
                Layout(
                    horizontalDivision: .thirds,
                    verticalDivision: .thirds,
                    columnSpan: LayoutSpan(start: 0, end: 2),
                    rowSpan: LayoutSpan(start: 0, end: 2)
                )
            )
            draft.selectCell(column: 1, row: 2)
            check("clicking a cell selects that single column",
                  draft.columnSpan == .single(1), "got \(draft.columnSpan)")
            check("clicking a cell selects that single row",
                  draft.rowSpan == .single(2), "got \(draft.rowSpan)")
            check("single-cell selection builds a valid Layout", draft.layout.isValid)
            check("only the clicked cell reads occupied",
                  draft.isCellOccupied(column: 1, row: 2)
                      && !draft.isCellOccupied(column: 0, row: 0)
                      && !draft.isCellOccupied(column: 2, row: 2))
        }

        // Direct selection — a forward drag (anchor before cursor) selects the
        // inclusive rectangle between the two cells.
        do {
            var draft = LayoutDraft(
                Layout(
                    horizontalDivision: .fourths,
                    verticalDivision: .thirds,
                    columnSpan: .single(0),
                    rowSpan: .single(0)
                )
            )
            draft.selectCells(fromColumn: 1, fromRow: 0, toColumn: 3, toRow: 2)
            check("forward drag selects the inclusive column span",
                  draft.columnSpan == LayoutSpan(start: 1, end: 3), "got \(draft.columnSpan)")
            check("forward drag selects the inclusive row span",
                  draft.rowSpan == LayoutSpan(start: 0, end: 2), "got \(draft.rowSpan)")
            check("forward drag builds a valid Layout", draft.layout.isValid)
        }

        // Direct selection — a reverse drag (cursor before anchor) selects the
        // same rectangle as the equivalent forward drag, regardless of direction.
        do {
            var forward = LayoutDraft(
                Layout(horizontalDivision: .fourths, verticalDivision: .thirds,
                       columnSpan: .single(0), rowSpan: .single(0))
            )
            var reverse = forward
            forward.selectCells(fromColumn: 1, fromRow: 0, toColumn: 3, toRow: 2)
            reverse.selectCells(fromColumn: 3, fromRow: 2, toColumn: 1, toRow: 0)
            check("reverse drag yields the same column span as forward",
                  forward.columnSpan == reverse.columnSpan,
                  "forward \(forward.columnSpan) reverse \(reverse.columnSpan)")
            check("reverse drag yields the same row span as forward",
                  forward.rowSpan == reverse.rowSpan,
                  "forward \(forward.rowSpan) reverse \(reverse.rowSpan)")
        }

        // Direct selection is always one continuous, valid rectangle even when the
        // drag endpoints fall outside the grid: the endpoints clamp into range.
        do {
            var draft = LayoutDraft(
                Layout(horizontalDivision: .halves, verticalDivision: .halves,
                       columnSpan: .single(0), rowSpan: .single(0))
            )
            draft.selectCells(fromColumn: -5, fromRow: 9, toColumn: 9, toRow: -5)
            check("out-of-range drag endpoints clamp to a valid rectangle", draft.layout.isValid,
                  "got \(draft.layout)")
            check("clamped drag fills the whole halves×halves grid",
                  draft.columnSpan == LayoutSpan(start: 0, end: 1)
                      && draft.rowSpan == LayoutSpan(start: 0, end: 1),
                  "cols \(draft.columnSpan) rows \(draft.rowSpan)")
        }

        // Direct selection on a Full axis stays on that axis's single cell no
        // matter which cell index the interaction reports.
        do {
            var draft = LayoutDraft(
                Layout(horizontalDivision: .full, verticalDivision: .thirds,
                       columnSpan: .single(0), rowSpan: .single(0))
            )
            draft.selectCells(fromColumn: 2, fromRow: 0, toColumn: 3, toRow: 2)
            check("a Full axis stays on its single cell under drag",
                  draft.columnSpan == .single(0), "got \(draft.columnSpan)")
            check("the divided axis still takes the dragged span",
                  draft.rowSpan == LayoutSpan(start: 0, end: 2), "got \(draft.rowSpan)")
            check("Full-axis selection builds a valid Layout", draft.layout.isValid)

            // Both axes Full: any interaction resolves to the one cell.
            var both = LayoutDraft(
                Layout(horizontalDivision: .full, verticalDivision: .full,
                       columnSpan: .single(0), rowSpan: .single(0))
            )
            both.selectCell(column: 3, row: 2)
            check("both-Full selection stays on cell (0,0)",
                  both.columnSpan == .single(0) && both.rowSpan == .single(0),
                  "cols \(both.columnSpan) rows \(both.rowSpan)")
        }

        // Synchronization — after a direct selection the first/last values the
        // controls read reflect the new span, and editing a control afterwards
        // still narrows the same span (both input methods drive one state).
        do {
            var draft = LayoutDraft(
                Layout(horizontalDivision: .fourths, verticalDivision: .halves,
                       columnSpan: .single(0), rowSpan: .single(0))
            )
            draft.selectCells(fromColumn: 1, fromRow: 0, toColumn: 3, toRow: 1)
            check("controls read the selection's first/last column",
                  draft.columnSpan.start == 1 && draft.columnSpan.end == 3)
            check("controls read the selection's first/last row",
                  draft.rowSpan.start == 0 && draft.rowSpan.end == 1)
            draft.setColumnStart(2)
            check("editing a control after a selection narrows the same span",
                  draft.columnSpan == LayoutSpan(start: 2, end: 3), "got \(draft.columnSpan)")
        }

        // Save/Cancel seam — a LayoutDraft is a value type, so the editor's draft
        // copy can be mutated freely; Cancel simply discards it and the source
        // Layout is untouched, while Save persists exactly `draft.layout`.
        do {
            let saved = Layout(
                horizontalDivision: .halves, verticalDivision: .halves,
                columnSpan: .single(0), rowSpan: LayoutSpan(start: 0, end: 1)
            )
            var draft = LayoutDraft(saved)
            draft.selectCells(fromColumn: 1, fromRow: 1, toColumn: 1, toRow: 1)
            check("mutating the draft does not mutate the source Layout",
                  saved.columnSpan == .single(0) && saved.rowSpan == LayoutSpan(start: 0, end: 1),
                  "source changed to \(saved)")
            check("Save would persist exactly the draft's current selection",
                  draft.layout == Layout(horizontalDivision: .halves, verticalDivision: .halves,
                                         columnSpan: .single(1), rowSpan: .single(1)),
                  "got \(draft.layout)")
        }

        // Grid metrics — the pure pointer-offset → cell-index mapping the
        // interactive preview drives. Pitch is cell + gap; a click near a cell's
        // centre lands on that cell, and offsets before/after the grid clamp to
        // the first/last cell so a drag past an edge still selects the edge cell.
        do {
            let metrics = LayoutGridMetrics(cellSize: 26, spacing: 2) // pitch 28
            check("offset in the first cell maps to index 0",
                  metrics.cellIndex(at: 13, cellCount: 4) == 0)
            check("offset in the third cell maps to index 2",
                  metrics.cellIndex(at: 2 * 28 + 13, cellCount: 4) == 2,
                  "got \(metrics.cellIndex(at: 2 * 28 + 13, cellCount: 4))")
            check("negative offset clamps to the first cell",
                  metrics.cellIndex(at: -40, cellCount: 4) == 0)
            check("offset past the grid clamps to the last cell",
                  metrics.cellIndex(at: 9_999, cellCount: 4) == 3,
                  "got \(metrics.cellIndex(at: 9_999, cellCount: 4))")
            check("any offset on a Full axis (cellCount 1) maps to 0",
                  metrics.cellIndex(at: 500, cellCount: 1) == 0)
            check("cellPitch is cell size plus spacing", metrics.cellPitch == 28)
        }

        // Click path — a zero-length drag (start == current cell), the way the
        // view routes a click, selects exactly that one cell on both axes.
        do {
            var draft = LayoutDraft(
                Layout(horizontalDivision: .thirds, verticalDivision: .thirds,
                       columnSpan: LayoutSpan(start: 0, end: 2), rowSpan: LayoutSpan(start: 0, end: 2))
            )
            draft.selectCells(fromColumn: 2, fromRow: 1, toColumn: 2, toRow: 1)
            check("a zero-length drag selects the single clicked cell",
                  draft.columnSpan == .single(2) && draft.rowSpan == .single(1),
                  "cols \(draft.columnSpan) rows \(draft.rowSpan)")
        }

        if failures.isEmpty {
            print("Layout draft tests passed")
        } else {
            fatalError("Layout draft tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
