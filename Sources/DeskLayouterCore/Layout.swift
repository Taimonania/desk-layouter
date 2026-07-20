import CoreGraphics
import Foundation

/// How an axis of a Desktop's screen is divided when placing a window: not at
/// all (full), or into halves, thirds, or fourths. The raw value is the number
/// of equal cells the axis is split into, so `cellCount` reads straight off it
/// and the persisted JSON stores a plain `1`, `2`, `3`, or `4`.
///
/// `full` is a single undivided cell covering the complete usable extent of the
/// axis (no menu bar / Dock, no macOS native fullscreen). The cases are ordered
/// full, halves, thirds, fourths — the order the editor offers them in — and
/// `full`'s raw value `1` does not collide with the `2`/`3`/`4` written by
/// Layouts persisted before Full existed, so those remain compatible.
public enum Division: Int, Codable, Equatable, Sendable, CaseIterable {
    case full = 1
    case halves = 2
    case thirds = 3
    case fourths = 4

    /// The number of equal cells this division splits its axis into.
    public var cellCount: Int { rawValue }

    /// Whether this axis is a single undivided cell covering the whole axis.
    public var isFull: Bool { self == .full }
}

/// An inclusive run of cells a window occupies on one axis, expressed as
/// 0-based `start` and `end` indices into that axis's division. A single cell is
/// `start == end`; a full axis is `start == 0` and `end == cellCount - 1`.
///
/// The span carries no notion of which division it belongs to — validity against
/// a specific ``Division`` is checked by ``Layout/validate()``.
public struct LayoutSpan: Codable, Equatable, Sendable {
    /// The 0-based index of the first occupied cell (inclusive).
    public var start: Int
    /// The 0-based index of the last occupied cell (inclusive).
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Convenience for a span covering a single cell at `index`.
    public static func single(_ index: Int) -> LayoutSpan {
        LayoutSpan(start: index, end: index)
    }

    /// The number of cells covered, when the span is non-empty. A span whose
    /// `end` precedes its `start` is empty and this is not meaningful (validation
    /// rejects it).
    public var cellCount: Int { end - start + 1 }
}

/// Where a managed application's window sits on its Desktop's screen: the screen
/// is divided horizontally and vertically (each full — undivided — or into
/// halves, thirds, or fourths), and the window occupies a column span and a row
/// span of the resulting grid.
///
/// This is the persisted declarative desired state described in
/// `docs/adr/0003-runtime-window-arrange-accessibility.md` and the **Layout**
/// term in `CONTEXT.md`. It is a pure value with no Accessibility, AppKit, or
/// coordinate-flip concerns; enacting it (Arrange) is a distinct runtime act
/// that lives outside this core.
///
/// Column indices increase left-to-right and **row indices increase
/// top-to-bottom** (row 0 is the top of the screen). Layouts are per-application
/// and independent — two apps' Layouts may overlap or leave gaps, which is
/// allowed and unvalidated here.
public struct Layout: Codable, Equatable, Sendable {
    /// How the screen's width is divided into columns.
    public var horizontalDivision: Division
    /// How the screen's height is divided into rows.
    public var verticalDivision: Division
    /// The columns the window occupies, indexed into ``horizontalDivision``.
    public var columnSpan: LayoutSpan
    /// The rows the window occupies, indexed into ``verticalDivision``.
    public var rowSpan: LayoutSpan

    public init(
        horizontalDivision: Division,
        verticalDivision: Division,
        columnSpan: LayoutSpan,
        rowSpan: LayoutSpan
    ) {
        self.horizontalDivision = horizontalDivision
        self.verticalDivision = verticalDivision
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
    }

    /// Computes the target rectangle for this Layout within a screen's usable
    /// area (`NSScreen.visibleFrame`), edge-to-edge with no gaps.
    ///
    /// The grid is divided by proportion of the frame rather than by a rounded
    /// per-cell size, so a span touching an edge of the grid lands exactly on
    /// the corresponding edge of `visibleFrame` and neighbouring spans meet with
    /// no gap or overlap. Row 0 is the top of the screen.
    ///
    /// The returned rect is in the **same coordinate space as the supplied
    /// `visibleFrame`** — i.e. the bottom-left-origin `NSScreen` plane. The
    /// whole-display top-left flip the Accessibility API needs is the adapter's
    /// job (ADR-0003), not this pure computation's.
    ///
    /// This computation does not itself validate the Layout; callers that accept
    /// untrusted Layouts should call ``validate()`` first. For an out-of-bounds
    /// span it still returns a proportional rect (which may fall outside
    /// `visibleFrame`).
    public func targetFrame(in visibleFrame: CGRect) -> CGRect {
        let columns = CGFloat(horizontalDivision.cellCount)
        let rows = CGFloat(verticalDivision.cellCount)

        let minX = visibleFrame.minX + visibleFrame.width * (CGFloat(columnSpan.start) / columns)
        let maxX = visibleFrame.minX + visibleFrame.width * (CGFloat(columnSpan.end + 1) / columns)

        // Row 0 is the top of the screen; `visibleFrame` is bottom-left origin,
        // so a smaller row index maps to a larger y.
        let maxY = visibleFrame.maxY - visibleFrame.height * (CGFloat(rowSpan.start) / rows)
        let minY = visibleFrame.maxY - visibleFrame.height * (CGFloat(rowSpan.end + 1) / rows)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether the cell at the given 0-based `column` and `row` is one of the
    /// cells this Layout's window occupies. Column indices increase left-to-right
    /// and row indices increase top-to-bottom (row 0 is the top of the screen), so
    /// this reads straight off the two spans. Used to paint the editor's mini-grid
    /// preview and to describe which cells the window covers.
    public func occupies(column: Int, row: Int) -> Bool {
        columnSpan.start <= column && column <= columnSpan.end
            && rowSpan.start <= row && row <= rowSpan.end
    }

    /// Rejects Layouts whose span does not fit its division: an empty span (its
    /// `end` before its `start`) or a span reaching outside the division's cells
    /// (a negative `start`, or an `end` at or beyond `cellCount`).
    public func validate() throws {
        try Layout.validate(span: columnSpan, against: horizontalDivision, axis: .column)
        try Layout.validate(span: rowSpan, against: verticalDivision, axis: .row)
    }

    /// Whether this Layout passes ``validate()``.
    public var isValid: Bool {
        (try? validate()) != nil
    }

    private static func validate(
        span: LayoutSpan,
        against division: Division,
        axis: LayoutValidationError.Axis
    ) throws {
        guard span.end >= span.start else {
            throw LayoutValidationError.emptySpan(axis)
        }
        guard span.start >= 0, span.end < division.cellCount else {
            throw LayoutValidationError.spanOutOfBounds(axis)
        }
    }
}

/// Why a ``Layout`` is invalid, carrying which axis was at fault.
public enum LayoutValidationError: Error, Equatable {
    public enum Axis: Equatable, Sendable {
        case column
        case row
    }

    /// The span's `end` precedes its `start`, so it covers no cells.
    case emptySpan(Axis)
    /// The span reaches outside the division's cells (negative start, or end at
    /// or beyond the cell count).
    case spanOutOfBounds(Axis)
}
