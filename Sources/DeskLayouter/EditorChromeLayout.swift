import Foundation

/// Shared, testable policy for the editor's chrome. SwiftUI consumes this model
/// when composing the footer, sizing the Preset row, and placing hover tooltips,
/// so the behavior tests exercise the same values the rendered view uses.
public enum EditorChromeLayout {
    public enum FooterAction: Hashable, Sendable {
        case apply
        case arrange
    }

    public enum FooterVersionElement: Hashable, Sendable {
        case checkForUpdates
        case version
    }

    public enum FooterRegion: Hashable, Sendable {
        case actions([FooterAction])
        case flexibleSpace
        case version([FooterVersionElement])
    }

    /// The footer is composed from these regions, rather than relying on visual
    /// offsets, so the flexible space remains between the two semantic groups.
    public static let footerRegions: [FooterRegion] = [
        .actions([.apply, .arrange]),
        .flexibleSpace,
        .version([.checkForUpdates, .version]),
    ]

    public static let footerActionSpacing: CGFloat = 6

    /// The widest label Apply can ever present. The action group reserves this
    /// label's rendered width (measured at runtime) for both buttons, so Arrange
    /// never shifts sideways as the pending-change count grows.
    public static let footerWidestActionLabel = "Apply (99)"

    /// Returns the two equal button widths for the action group, both set to the
    /// measured width of the widest label. Titles do not participate, so `Apply`
    /// and `Apply (3)` lay out identically and Arrange stays put.
    public static func footerActionWidths(buttonWidth: CGFloat) -> [CGFloat] {
        let width = max(0, buttonWidth)
        return [width, width]
    }

    public enum PresetControl: CaseIterable, Sendable {
        case selector
        case management
        case update
        case revert
    }

    public struct PresetControlMetrics: Equatable, Sendable {
        public let height: CGFloat
        public let width: CGFloat
        public let hidesMenuIndicator: Bool
    }

    public static let presetControlHeight: CGFloat = 24
    public static let presetManagementWidth: CGFloat = 28
    public static let minimumTextButtonWidth: CGFloat = 56

    public static func presetMetrics(for control: PresetControl) -> PresetControlMetrics {
        switch control {
        case .selector:
            return PresetControlMetrics(height: presetControlHeight, width: 120, hidesMenuIndicator: false)
        case .management:
            return PresetControlMetrics(
                height: presetControlHeight,
                width: presetManagementWidth,
                hidesMenuIndicator: true
            )
        case .update, .revert:
            return PresetControlMetrics(
                height: presetControlHeight,
                width: minimumTextButtonWidth,
                hidesMenuIndicator: false
            )
        }
    }

    public static let tooltipWindowPadding: CGFloat = 8

    /// Centers a single-line tooltip over its control, clamping that center so
    /// the tooltip's unchanged width remains within the window's horizontal inset.
    public static func tooltipCenterX(
        controlCenterX: CGFloat,
        tooltipWidth: CGFloat,
        windowWidth: CGFloat,
        padding: CGFloat = tooltipWindowPadding
    ) -> CGFloat {
        let halfWidth = max(0, tooltipWidth) / 2
        let minimumCenter = padding + halfWidth
        let maximumCenter = windowWidth - padding - halfWidth

        guard maximumCenter >= minimumCenter else {
            return windowWidth / 2
        }
        return min(max(controlCenterX, minimumCenter), maximumCenter)
    }
}
