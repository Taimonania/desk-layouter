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

        if failures.isEmpty {
            print("Layout draft tests passed")
        } else {
            fatalError("Layout draft tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
