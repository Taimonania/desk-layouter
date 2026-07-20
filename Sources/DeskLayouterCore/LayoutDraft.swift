import Foundation

/// The editable, always-valid working state behind the Layout editor UI: the two
/// divisions and the column/row spans the user is choosing before committing a
/// ``Layout`` to a managed application.
///
/// This is the pure, unit-tested seam the AppKit/SwiftUI editor drives. It owns
/// the invariant the view must not have to think about: **the spans always fit
/// their divisions and are never empty.** Changing a division re-clamps the
/// affected span (dropping from fourths to halves pulls a span that reached cell
/// 3 back inside cells 0–1); moving one end of a span past the other drags the
/// other end along. Because of that invariant ``layout`` can always produce a
/// valid ``Layout`` — the view never builds an out-of-bounds one.
///
/// Column indices increase left-to-right and **row indices increase
/// top-to-bottom** (row 0 is the top of the screen), matching ``Layout``.
public struct LayoutDraft: Equatable, Sendable {
    public private(set) var horizontalDivision: Division
    public private(set) var verticalDivision: Division
    public private(set) var columnSpan: LayoutSpan
    public private(set) var rowSpan: LayoutSpan

    /// The draft shown for an app that has no Layout yet: the left half of the
    /// screen (two columns, window in the left one; full height). A recognizable,
    /// useful starting point that also shows the grid the user is editing rather
    /// than a fully-filled "whole screen" that would teach nothing.
    public init() {
        horizontalDivision = .halves
        verticalDivision = .halves
        columnSpan = .single(0)
        rowSpan = LayoutSpan(start: 0, end: 1)
    }

    /// Seeds a draft from an existing ``Layout`` for editing. Any span that does
    /// not fit its division (e.g. from a tolerantly decoded, hand-authored, or
    /// otherwise out-of-range config) is clamped in, so the draft is always valid
    /// even when its source Layout was not.
    public init(_ layout: Layout) {
        horizontalDivision = layout.horizontalDivision
        verticalDivision = layout.verticalDivision
        columnSpan = LayoutDraft.clamp(layout.columnSpan, toCellCount: layout.horizontalDivision.cellCount)
        rowSpan = LayoutDraft.clamp(layout.rowSpan, toCellCount: layout.verticalDivision.cellCount)
    }

    /// The valid ``Layout`` this draft represents, ready to persist on a managed
    /// application. Always valid by construction (see the type's invariant).
    public var layout: Layout {
        Layout(
            horizontalDivision: horizontalDivision,
            verticalDivision: verticalDivision,
            columnSpan: columnSpan,
            rowSpan: rowSpan
        )
    }

    // MARK: - Editing

    /// Changes how the width is divided, re-clamping the column span so it still
    /// fits (a span that reached a now-removed column is pulled back to the last
    /// remaining one).
    public mutating func setHorizontalDivision(_ division: Division) {
        horizontalDivision = division
        columnSpan = LayoutDraft.clamp(columnSpan, toCellCount: division.cellCount)
    }

    /// Changes how the height is divided, re-clamping the row span so it still
    /// fits.
    public mutating func setVerticalDivision(_ division: Division) {
        verticalDivision = division
        rowSpan = LayoutDraft.clamp(rowSpan, toCellCount: division.cellCount)
    }

    /// Sets the first occupied column, clamped into range; if it passes the
    /// current end, the end moves with it so the span never inverts.
    public mutating func setColumnStart(_ start: Int) {
        columnSpan = LayoutDraft.spanSettingStart(start, on: columnSpan, cellCount: horizontalDivision.cellCount)
    }

    /// Sets the last occupied column, clamped into range; if it precedes the
    /// current start, the start moves with it.
    public mutating func setColumnEnd(_ end: Int) {
        columnSpan = LayoutDraft.spanSettingEnd(end, on: columnSpan, cellCount: horizontalDivision.cellCount)
    }

    /// Sets the first (top-most) occupied row, clamped into range; if it passes
    /// the current end, the end moves with it.
    public mutating func setRowStart(_ start: Int) {
        rowSpan = LayoutDraft.spanSettingStart(start, on: rowSpan, cellCount: verticalDivision.cellCount)
    }

    /// Sets the last (bottom-most) occupied row, clamped into range; if it
    /// precedes the current start, the start moves with it.
    public mutating func setRowEnd(_ end: Int) {
        rowSpan = LayoutDraft.spanSettingEnd(end, on: rowSpan, cellCount: verticalDivision.cellCount)
    }

    // MARK: - Mini-grid mapping

    /// Whether the cell at the given 0-based `column` and `row` is occupied by the
    /// draft's region — the mapping the mini-grid preview paints. Row 0 is the top.
    public func isCellOccupied(column: Int, row: Int) -> Bool {
        layout.occupies(column: column, row: row)
    }

    // MARK: - Clamping

    private static func clamp(_ span: LayoutSpan, toCellCount cellCount: Int) -> LayoutSpan {
        let maxIndex = max(cellCount - 1, 0)
        let end = min(max(span.end, 0), maxIndex)
        let start = min(max(span.start, 0), end)
        return LayoutSpan(start: start, end: end)
    }

    private static func spanSettingStart(_ start: Int, on span: LayoutSpan, cellCount: Int) -> LayoutSpan {
        let maxIndex = max(cellCount - 1, 0)
        let clampedStart = min(max(start, 0), maxIndex)
        return LayoutSpan(start: clampedStart, end: max(span.end, clampedStart))
    }

    private static func spanSettingEnd(_ end: Int, on span: LayoutSpan, cellCount: Int) -> LayoutSpan {
        let maxIndex = max(cellCount - 1, 0)
        let clampedEnd = min(max(end, 0), maxIndex)
        return LayoutSpan(start: min(span.start, clampedEnd), end: clampedEnd)
    }
}
