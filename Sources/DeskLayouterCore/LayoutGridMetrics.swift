import CoreGraphics

/// The geometry of the Layout editor's mini-grid: one cell's on-screen extent and
/// the gap between neighbouring cells. Its job is the pure, testable half of the
/// interactive preview — turning a pointer offset (a click or drag location
/// within the grid) into the 0-based cell index it lands on. The SwiftUI grid
/// stays a thin layer that lays cells out at these metrics and feeds locations
/// back through ``cellIndex(at:cellCount:)``.
public struct LayoutGridMetrics: Equatable, Sendable {
    /// One cell's width/height in points.
    public var cellSize: CGFloat
    /// The gap between neighbouring cells in points.
    public var spacing: CGFloat

    public init(cellSize: CGFloat, spacing: CGFloat) {
        self.cellSize = cellSize
        self.spacing = spacing
    }

    /// The distance from one cell's leading edge to the next's — a cell plus the
    /// gap that follows it.
    public var cellPitch: CGFloat { cellSize + spacing }

    /// The 0-based cell index the given offset (measured from the grid's leading
    /// edge along one axis) falls on, clamped into `[0, cellCount - 1]`. Offsets
    /// before the grid or past its trailing edge clamp to the first or last cell
    /// so a drag that strays outside still selects an edge cell rather than
    /// nothing; a `cellCount` of 1 (a Full axis) always yields 0.
    public func cellIndex(at offset: CGFloat, cellCount: Int) -> Int {
        let raw = Int((offset / cellPitch).rounded(.down))
        return min(max(raw, 0), max(cellCount - 1, 0))
    }
}
