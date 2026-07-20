import CoreGraphics
import DeskLayouterCore
import Foundation

// Verifies the Layout model (issue #24): the pure target-frame computation from
// a Layout and a screen's usable area (edge-to-edge, no gaps, row 0 at the top),
// validation that rejects empty and out-of-bounds spans, and that a Layout rides
// on ManagedApplication as a tolerant-decoding optional (old configs without a
// Layout still load). Hand-rolled @main runner, no XCTest — matching the other
// core test targets.

@main
struct LayoutTestRunner {
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

        func approxEqual(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }

        func rectsEqual(_ a: CGRect, _ b: CGRect) -> Bool {
            approxEqual(a.minX, b.minX) && approxEqual(a.minY, b.minY)
                && approxEqual(a.width, b.width) && approxEqual(a.height, b.height)
        }

        // A 1000x800 usable area at the origin makes the arithmetic easy to read;
        // one case below uses a non-zero origin to prove offsets are honoured.
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        // Worked example: left half of halves — horizontal halves, first column,
        // full height. Left edge and both vertical edges sit exactly on the frame.
        do {
            let layout = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: .single(0),
                rowSpan: LayoutSpan(start: 0, end: 1)
            )
            let rect = layout.targetFrame(in: frame)
            check(
                "left half of halves covers the left 500x800",
                rectsEqual(rect, CGRect(x: 0, y: 0, width: 500, height: 800)),
                "got \(rect)"
            )
        }

        // Worked example: last half of halves — the right column, full height.
        // Its left edge meets the left-half's right edge with no gap or overlap.
        do {
            let layout = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: .single(1),
                rowSpan: LayoutSpan(start: 0, end: 1)
            )
            let rect = layout.targetFrame(in: frame)
            check(
                "last half of halves covers the right 500x800",
                rectsEqual(rect, CGRect(x: 500, y: 0, width: 500, height: 800)),
                "got \(rect)"
            )
        }

        // Worked example: a middle third — horizontal thirds, the centre column,
        // full height. Uses fractional edges so the thirds divide exactly.
        do {
            let layout = Layout(
                horizontalDivision: .thirds,
                verticalDivision: .halves,
                columnSpan: .single(1),
                rowSpan: LayoutSpan(start: 0, end: 1)
            )
            let rect = layout.targetFrame(in: frame)
            check(
                "middle third covers the centre column full height",
                rectsEqual(rect, CGRect(x: 1000.0 / 3.0, y: 0, width: 1000.0 / 3.0, height: 800)),
                "got \(rect)"
            )
        }

        // Worked example: a two-cell span of fourths — columns 1 through 2 of
        // four, full height, i.e. the centre half.
        do {
            let layout = Layout(
                horizontalDivision: .fourths,
                verticalDivision: .halves,
                columnSpan: LayoutSpan(start: 1, end: 2),
                rowSpan: LayoutSpan(start: 0, end: 1)
            )
            let rect = layout.targetFrame(in: frame)
            check(
                "two-cell span of fourths covers the centre 500x800",
                rectsEqual(rect, CGRect(x: 250, y: 0, width: 500, height: 800)),
                "got \(rect)"
            )
        }

        // Worked example: full-axis on one axis — full width (all thirds), top
        // row of a halved height. Row 0 is the top, so in the bottom-left frame
        // it occupies the upper half (y 400...800).
        do {
            let layout = Layout(
                horizontalDivision: .thirds,
                verticalDivision: .halves,
                columnSpan: LayoutSpan(start: 0, end: 2),
                rowSpan: .single(0)
            )
            let rect = layout.targetFrame(in: frame)
            check(
                "full-axis width with top-half height occupies the upper strip",
                rectsEqual(rect, CGRect(x: 0, y: 400, width: 1000, height: 400)),
                "got \(rect)"
            )
        }

        // The bottom row maps to the lower strip, confirming row indices increase
        // downward while the frame origin stays bottom-left.
        do {
            let layout = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: LayoutSpan(start: 0, end: 1),
                rowSpan: .single(1)
            )
            let rect = layout.targetFrame(in: frame)
            check(
                "bottom row occupies the lower strip (row 0 is the top)",
                rectsEqual(rect, CGRect(x: 0, y: 0, width: 1000, height: 400)),
                "got \(rect)"
            )
        }

        // Offsets are honoured: a non-zero frame origin shifts the result rather
        // than being ignored.
        do {
            let offsetFrame = CGRect(x: 100, y: 50, width: 800, height: 600)
            let layout = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: .single(0),
                rowSpan: .single(0)
            )
            let rect = layout.targetFrame(in: offsetFrame)
            check(
                "target frame honours a non-zero visibleFrame origin",
                rectsEqual(rect, CGRect(x: 100, y: 350, width: 400, height: 300)),
                "got \(rect)"
            )
        }

        // Edge-to-edge with no gaps: fourths divide the width exactly, cell edges
        // meeting with no gap and the outer edges landing on the frame.
        do {
            let cells = (0..<4).map { index in
                Layout(
                    horizontalDivision: .fourths,
                    verticalDivision: .halves,
                    columnSpan: .single(index),
                    rowSpan: LayoutSpan(start: 0, end: 1)
                ).targetFrame(in: frame)
            }
            check("fourths start at the frame's left edge", approxEqual(cells[0].minX, 0), "got \(cells[0].minX)")
            check("fourths end at the frame's right edge", approxEqual(cells[3].maxX, 1000), "got \(cells[3].maxX)")
            let contiguous = zip(cells, cells.dropFirst()).allSatisfy { approxEqual($0.maxX, $1.minX) }
            check("adjacent fourths meet with no gap", contiguous)
        }

        // Validation: a well-formed Layout passes; an empty span and an
        // out-of-bounds span are each rejected with the faulting axis.
        do {
            let valid = Layout(
                horizontalDivision: .fourths,
                verticalDivision: .thirds,
                columnSpan: LayoutSpan(start: 1, end: 2),
                rowSpan: .single(0)
            )
            check("a well-formed Layout validates", valid.isValid)
            check("validate() does not throw for a valid Layout", (try? valid.validate()) != nil)
        }

        do {
            let emptyColumn = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: LayoutSpan(start: 1, end: 0),
                rowSpan: .single(0)
            )
            check("an empty column span is invalid", emptyColumn.isValid == false)
            check(
                "empty column span throws emptySpan(.column)",
                throwsValidation(emptyColumn) == .emptySpan(.column),
                "got \(String(describing: throwsValidation(emptyColumn)))"
            )
        }

        do {
            let outOfBoundsColumn = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: LayoutSpan(start: 0, end: 2),
                rowSpan: .single(0)
            )
            check(
                "a column span reaching past the division is invalid",
                throwsValidation(outOfBoundsColumn) == .spanOutOfBounds(.column),
                "got \(String(describing: throwsValidation(outOfBoundsColumn)))"
            )
        }

        do {
            let negativeStart = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: LayoutSpan(start: -1, end: 0),
                rowSpan: .single(0)
            )
            check(
                "a negative column start is out of bounds",
                throwsValidation(negativeStart) == .spanOutOfBounds(.column),
                "got \(String(describing: throwsValidation(negativeStart)))"
            )
        }

        do {
            let outOfBoundsRow = Layout(
                horizontalDivision: .halves,
                verticalDivision: .thirds,
                columnSpan: .single(0),
                rowSpan: LayoutSpan(start: 0, end: 3)
            )
            check(
                "a row span reaching past the division throws on the row axis",
                throwsValidation(outOfBoundsRow) == .spanOutOfBounds(.row),
                "got \(String(describing: throwsValidation(outOfBoundsRow)))"
            )
        }

        // ManagedApplication carries an optional Layout that round-trips, and a
        // configuration written before Layout existed still decodes (layout nil),
        // matching the pendingRemovals tolerance.
        do {
            let layout = Layout(
                horizontalDivision: .thirds,
                verticalDivision: .fourths,
                columnSpan: .single(2),
                rowSpan: LayoutSpan(start: 1, end: 3)
            )
            let app = ManagedApplication(
                bundleIdentifier: "com.example.Arranged",
                displayName: "Arranged",
                desktopNumber: 2,
                layout: layout
            )
            let config = DeskLayouterConfiguration(managedApplications: [app])
            let decoded = try? ConfigurationSerialization.decode(
                from: ConfigurationSerialization.encode(config)
            )
            check("a configuration with a Layout round-trips", decoded == config, "got \(String(describing: decoded))")
            check(
                "the decoded Layout survives the round-trip",
                decoded?.managedApplications.first?.layout == layout
            )
        }

        do {
            let app = ManagedApplication(
                bundleIdentifier: "com.example.Plain",
                displayName: "Plain",
                desktopNumber: 1
            )
            check("a managed application without a Layout defaults to nil", app.layout == nil)
        }

        do {
            let legacyJSON = Data(#"{"managedApplications":[{"bundleIdentifier":"com.example.Legacy","displayName":"Legacy","desktopNumber":1}]}"#.utf8)
            let decoded = try? ConfigurationSerialization.decode(from: legacyJSON)
            check(
                "a config written before Layout existed decodes with layout nil",
                decoded?.managedApplications.first?.layout == nil,
                "got \(String(describing: decoded))"
            )
        }

        if failures.isEmpty {
            print("Layout tests passed")
        } else {
            fatalError("Layout tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }

    /// Runs ``Layout/validate()`` and returns the thrown error, or `nil` when it
    /// passed — so tests can assert the exact ``LayoutValidationError``.
    static func throwsValidation(_ layout: Layout) -> LayoutValidationError? {
        do {
            try layout.validate()
            return nil
        } catch let error as LayoutValidationError {
            return error
        } catch {
            return nil
        }
    }
}
