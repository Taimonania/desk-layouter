import AppKit
import ApplicationServices
import CoreGraphics
import DeskLayouterCore
import Foundation

// Runtime window Arrange via the Accessibility API (issue #25, ADR-0003).
//
// Arrange enacts persisted Layouts on the *currently active Desktop*: for every
// managed app that has a Layout, it takes the frontmost standard, non-minimized
// window and sets its frame to the rect computed from the Layout and the
// screen's `visibleFrame`. The Accessibility API can only reach the active
// Space, and per the ADR we never try to reach others.
//
// The file is split into two halves so the error-prone parts are unit-testable
// without any live AXUIElement / NSScreen call:
//   * `ArrangeEngine` — the PURE logic: which apps qualify, the bottom-left →
//     top-left coordinate flip (the crux, taken against the primary display
//     height), and whether a window resisted being moved.
//   * `WindowArranger` + the `AccessibilityAuthorizing` / `WindowManipulating` /
//     `ScreenGeometryProviding` seams — the thin live side effects, injected so
//     the orchestration loop can be exercised against fakes.

// MARK: - Result types

/// A managed app eligible to be arranged: one carrying a non-nil, valid Layout.
public struct ArrangeCandidate: Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let layout: Layout

    public init(bundleIdentifier: String, displayName: String, layout: Layout) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.layout = layout
    }
}

/// A window whose final frame did not match the target after Arrange set it —
/// a fixed-size, fullscreen, or sheet window that clamped or ignored the move.
/// Collected rather than failing silently so #27 can surface it to the user.
public struct ResistedWindow: Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    /// The frame Arrange asked for, in the Accessibility top-left-origin plane.
    public let desiredFrame: CGRect
    /// The frame read back afterwards, in the same plane.
    public let actualFrame: CGRect

    public init(
        bundleIdentifier: String,
        displayName: String,
        desiredFrame: CGRect,
        actualFrame: CGRect
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.desiredFrame = desiredFrame
        self.actualFrame = actualFrame
    }
}

/// The outcome of one Arrange pass over the active Desktop.
public struct ArrangeReport: Equatable, Sendable {
    /// Bundle identifiers of apps whose window was moved and verified in place.
    public let arranged: [String]
    /// Bundle identifiers of managed-with-Layout apps that had no eligible
    /// window (not running, or only minimized/non-standard windows) — skipped
    /// without error per the acceptance criteria.
    public let skipped: [String]
    /// Windows that resisted the move; the primary signal #27 surfaces.
    public let resisted: [ResistedWindow]

    public init(arranged: [String], skipped: [String], resisted: [ResistedWindow]) {
        self.arranged = arranged
        self.skipped = skipped
        self.resisted = resisted
    }

    /// True when at least one window resisted, so a caller can decide whether to
    /// alert the user without inspecting the list.
    public var hasResistance: Bool { !resisted.isEmpty }
}

/// One Arrange pass may cover multiple saved physical identities while those
/// Displays are mirrored. Reporting stays attached to each Assignment's saved
/// physical destination even though Accessibility uses the mirror primary's
/// shared screen geometry for the actual move.
public struct PhysicalDisplayArrangeReport: Equatable, Sendable {
    public let display: DisplayIdentity
    public let report: ArrangeReport

    public init(display: DisplayIdentity, report: ArrangeReport) {
        self.display = display
        self.report = report
    }
}

public enum WindowArrangeError: Error, Equatable {
    /// The Accessibility permission is not granted. Arrange prompts for it and
    /// moves nothing (acceptance criteria).
    case accessibilityNotGranted
    /// No active screen could be resolved to arrange against.
    case noActiveScreen
}

// MARK: - Pure engine

/// The pure, side-effect-free heart of Arrange. Every function here is a value
/// transformation with no AXUIElement, NSScreen, or NSWorkspace dependency, so
/// the parts most likely to be wrong — candidate selection, the coordinate flip,
/// and resisted-window detection — are directly unit-testable.
public enum ArrangeEngine {
    /// The managed applications assigned to `desktopNumber` — the only ones a
    /// single Arrange pass over that Desktop may touch (issue #61). Applications
    /// assigned to any other Desktop are excluded here, so they are never moved
    /// nor reported as arranged, skipped, or resistant during this Desktop's pass;
    /// the arranger only reaches the active Space, so passing them would misreport
    /// windows that simply live elsewhere. Layout validity is enforced separately
    /// by ``candidates(from:)``.
    public static func applications(
        _ applications: [ManagedApplication],
        assignedToDesktop desktopNumber: Int
    ) -> [ManagedApplication] {
        applications.filter { $0.desktopNumber == desktopNumber }
    }

    /// Multi-Display scoping: match both the logical mirror/extended section and
    /// positional Desktop number before any Accessibility operation occurs.
    public static func applications(
        _ applications: [ManagedApplication],
        assignedTo destination: DesktopAddress,
        in topology: DisplayTopologySnapshot
    ) -> [ManagedApplication] {
        guard let destinationSection = topology.section(containing: destination.display) else {
            return []
        }
        return applications.filter { application in
            guard let display = application.display else { return false }
            return destinationSection.contains(display)
                && application.desktopNumber == destination.desktopNumber
        }
    }

    /// Partitions a logical Display pass back into its saved physical Assignment
    /// destinations. Extended Displays naturally produce one partition; a mirror
    /// group can produce one per member without misreporting an app under the
    /// group's primary identity.
    public static func reportsByAssignedDisplay(
        _ report: ArrangeReport,
        applications: [ManagedApplication]
    ) -> [PhysicalDisplayArrangeReport] {
        var displays: [DisplayIdentity] = []
        var displayByBundleIdentifier: [String: DisplayIdentity] = [:]
        for application in applications {
            guard let display = application.display else { continue }
            displayByBundleIdentifier[application.bundleIdentifier.lowercased()] = display
            if !displays.contains(where: { $0.identifiesSameDisplay(as: display) }) {
                displays.append(display)
            }
        }

        func belongs(_ bundleIdentifier: String, to display: DisplayIdentity) -> Bool {
            displayByBundleIdentifier[bundleIdentifier.lowercased()]?
                .identifiesSameDisplay(as: display) == true
        }

        return displays.compactMap { display in
            let partition = ArrangeReport(
                arranged: report.arranged.filter { belongs($0, to: display) },
                skipped: report.skipped.filter { belongs($0, to: display) },
                resisted: report.resisted.filter { belongs($0.bundleIdentifier, to: display) }
            )
            guard !partition.arranged.isEmpty
                    || !partition.skipped.isEmpty
                    || !partition.resisted.isEmpty
            else { return nil }
            return PhysicalDisplayArrangeReport(display: display, report: partition)
        }
    }

    /// The managed apps eligible to be arranged: those carrying a non-nil Layout
    /// that also validates. `Layout.targetFrame(in:)` does not validate, so an
    /// invalid Layout is filtered out here rather than producing a garbage rect.
    public static func candidates(from applications: [ManagedApplication]) -> [ArrangeCandidate] {
        applications.compactMap { application in
            guard let layout = application.layout, layout.isValid else { return nil }
            return ArrangeCandidate(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.displayName,
                layout: layout
            )
        }
    }

    /// Converts a rect from `NSScreen`'s bottom-left-origin global space into the
    /// Accessibility API's top-left-origin plane.
    ///
    /// This is the crux of ADR-0003 and the most error-prone step: both planes
    /// are anchored to the primary display's top-left, and the y-flip must be
    /// taken against the **primary display height** — not the height of the
    /// screen the window sits on — so it stays correct when a secondary display
    /// is taller/shorter or offset above/below the primary. The x coordinate is
    /// identical in both planes; only y flips.
    ///
    ///     axY = primaryDisplayHeight - screenY - height
    public static func topLeftFrame(
        fromScreenFrame frame: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect {
        let flippedY = primaryDisplayHeight - frame.origin.y - frame.height
        return CGRect(
            x: frame.origin.x,
            y: flippedY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Whether two frames match within a small tolerance. Window servers round
    /// to integral points and some apps snap to a size increment, so an exact
    /// equality check would produce false "resisted" reports; a couple of points
    /// of slack absorbs that without masking a genuine clamp (fixed-size /
    /// fullscreen / sheet windows miss by far more).
    public static func framesMatch(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 2
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

// MARK: - Live seams

/// Requests / checks the Accessibility permission. Injectable so the
/// orchestration can be tested without touching the real trust database.
public protocol AccessibilityAuthorizing {
    /// Returns whether the process is trusted for Accessibility. When
    /// `promptIfNeeded` is true and it is not yet trusted, the system shows its
    /// "grant access" prompt as a side effect.
    func ensureTrusted(promptIfNeeded: Bool) -> Bool
}

/// Positions an app's frontmost standard window via the Accessibility API.
/// Injectable so the Arrange loop (candidate filtering, skipping, resisted
/// collection) can be unit-tested against a fake with no live AXUIElement.
public protocol WindowManipulating {
    /// Moves the frontmost standard, non-minimized window of the app with the
    /// given bundle identifier to `topLeftFrame` (in the Accessibility top-left
    /// plane), using size → position → size to defeat per-app clamping, then
    /// returns the frame read back afterwards. Returns `nil` when the app is not
    /// running or has no eligible window (so the caller skips it without error).
    func moveFrontmostStandardWindow(
        bundleIdentifier: String,
        toTopLeftFrame topLeftFrame: CGRect
    ) -> CGRect?
}

/// Supplies the screen geometry Arrange needs. Injectable so the coordinate
/// wiring can be tested with synthetic single- and multi-display geometry.
public protocol ScreenGeometryProviding {
    /// The usable area of the active Desktop's screen (bottom-left origin,
    /// global coordinates), or `nil` when no screen is active.
    var activeVisibleFrame: CGRect? { get }
    /// The primary display's height — the anchor for the top-left y-flip.
    var primaryDisplayHeight: CGFloat { get }
    /// The usable frame for a specific physical Display.
    func visibleFrame(for display: DisplayIdentity) -> CGRect?
}

public extension ScreenGeometryProviding {
    func visibleFrame(for display: DisplayIdentity) -> CGRect? { activeVisibleFrame }
}

// MARK: - Orchestrator

/// The runtime Arrange engine. `arrange(managedApplications:)` is the entry
/// point a trigger (the temporary debug menu item today, the Arrange button in
/// #27 tomorrow) calls; it returns an ``ArrangeReport`` describing what moved,
/// what was skipped, and which windows resisted.
public final class WindowArranger {
    private let authorizer: AccessibilityAuthorizing
    private let windowManipulator: WindowManipulating
    private let screenGeometry: ScreenGeometryProviding

    public init(
        authorizer: AccessibilityAuthorizing = SystemAccessibilityAuthorizer(),
        windowManipulator: WindowManipulating = AccessibilityWindowManipulator(),
        screenGeometry: ScreenGeometryProviding = MainScreenGeometryProvider()
    ) {
        self.authorizer = authorizer
        self.windowManipulator = windowManipulator
        self.screenGeometry = screenGeometry
    }

    /// Arranges every managed app with a Layout on the currently active Desktop.
    ///
    /// Throws ``WindowArrangeError/accessibilityNotGranted`` (after prompting)
    /// when the permission is missing, so nothing is moved; throws
    /// ``WindowArrangeError/noActiveScreen`` when no screen resolves.
    public func arrange(managedApplications: [ManagedApplication]) throws -> ArrangeReport {
        try arrange(managedApplications: managedApplications, visibleFrame: screenGeometry.activeVisibleFrame)
    }

    /// Arranges one Display/Desktop pass against that physical Display's usable
    /// area. The caller scopes `managedApplications` to the matching Assignment
    /// destination, so another Display's app is never moved or reported here.
    public func arrange(
        managedApplications: [ManagedApplication],
        on display: DisplayIdentity
    ) throws -> ArrangeReport {
        try arrange(
            managedApplications: managedApplications,
            visibleFrame: screenGeometry.visibleFrame(for: display)
        )
    }

    private func arrange(
        managedApplications: [ManagedApplication],
        visibleFrame: CGRect?
    ) throws -> ArrangeReport {
        guard authorizer.ensureTrusted(promptIfNeeded: true) else {
            throw WindowArrangeError.accessibilityNotGranted
        }
        // Both the usable area and a usable (non-zero) primary height are
        // required for a meaningful flip. Treat a missing frame or a zero height
        // as "no active screen" and fail closed rather than flipping against a
        // bogus height and silently placing windows off-screen.
        guard let visibleFrame else {
            throw WindowArrangeError.noActiveScreen
        }
        let primaryHeight = screenGeometry.primaryDisplayHeight
        guard primaryHeight > 0 else {
            throw WindowArrangeError.noActiveScreen
        }

        var arranged: [String] = []
        var skipped: [String] = []
        var resisted: [ResistedWindow] = []

        for candidate in ArrangeEngine.candidates(from: managedApplications) {
            // Layout computes the rect in the bottom-left screen plane; flip it
            // into the Accessibility top-left plane against the PRIMARY height.
            let screenFrame = candidate.layout.targetFrame(in: visibleFrame)
            let desired = ArrangeEngine.topLeftFrame(
                fromScreenFrame: screenFrame,
                primaryDisplayHeight: primaryHeight
            )

            guard let actual = windowManipulator.moveFrontmostStandardWindow(
                bundleIdentifier: candidate.bundleIdentifier,
                toTopLeftFrame: desired
            ) else {
                skipped.append(candidate.bundleIdentifier)
                continue
            }

            if ArrangeEngine.framesMatch(desired, actual) {
                arranged.append(candidate.bundleIdentifier)
            } else {
                resisted.append(
                    ResistedWindow(
                        bundleIdentifier: candidate.bundleIdentifier,
                        displayName: candidate.displayName,
                        desiredFrame: desired,
                        actualFrame: actual
                    )
                )
            }
        }

        return ArrangeReport(arranged: arranged, skipped: skipped, resisted: resisted)
    }
}

// MARK: - Live implementations

/// The production Accessibility authorizer, backed by `AXIsProcessTrustedWithOptions`.
public struct SystemAccessibilityAuthorizer: AccessibilityAuthorizing {
    public init() {}

    public func ensureTrusted(promptIfNeeded: Bool) -> Bool {
        // The `kAXTrustedCheckOptionPrompt` global is not concurrency-safe under
        // Swift 6; its value is the stable documented key string.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// The production window manipulator, driving real `AXUIElement`s.
public struct AccessibilityWindowManipulator: WindowManipulating {
    public init() {}

    public func moveFrontmostStandardWindow(
        bundleIdentifier: String,
        toTopLeftFrame topLeftFrame: CGRect
    ) -> CGRect? {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = frontmostStandardWindow(of: appElement) else {
            return nil
        }

        // Set size → position → size. Many apps clamp a position change to the
        // window's current size, so sizing first lets the position land, and
        // sizing again afterwards settles any size the position step disturbed.
        setSize(topLeftFrame.size, on: window)
        setPosition(topLeftFrame.origin, on: window)
        setSize(topLeftFrame.size, on: window)

        // Read the frame back so the caller can detect a window that clamped or
        // ignored the move. A read failure yields a null rect, which never
        // matches the target and is therefore reported as resisted.
        guard let origin = position(of: window), let size = size(of: window) else {
            return .null
        }
        return CGRect(origin: origin, size: size)
    }

    private func frontmostStandardWindow(of appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else {
            return nil
        }
        // The windows attribute is ordered front-to-back, so the first eligible
        // window is the frontmost one.
        return windows.first(where: isEligible)
    }

    private func isEligible(_ window: AXUIElement) -> Bool {
        guard copyString(window, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String) else {
            return false
        }
        if let minimized = copyBool(window, kAXMinimizedAttribute), minimized {
            return false
        }
        return true
    }

    // MARK: Attribute helpers

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else {
            return nil
        }
        return value as? String
    }

    private func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else {
            return nil
        }
        return value as? Bool
    }

    private func position(of window: AXUIElement) -> CGPoint? {
        guard let axValue = copyValue(window, kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func size(of window: AXUIElement) -> CGSize? {
        guard let axValue = copyValue(window, kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func copyValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else {
            return nil
        }
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private func setPosition(_ point: CGPoint, on window: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, on window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }
}

/// The production screen geometry, reading live `NSScreen` state.
public struct MainScreenGeometryProvider: ScreenGeometryProviding {
    public init() {}

    public var activeVisibleFrame: CGRect? {
        NSScreen.main?.visibleFrame
    }

    public var primaryDisplayHeight: CGFloat {
        // The primary display is the one anchored at the global origin; both
        // coordinate planes flip against its height. `NSScreen.main` (the screen
        // with the active/key Space) is only a fallback for the degenerate case
        // where no screen sits at the origin.
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        return primary?.frame.height ?? 0
    }

    public func visibleFrame(for display: DisplayIdentity) -> CGRect? {
        NSScreen.screens.first { screen in
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber,
                let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            else { return false }
            let value = CFUUIDCreateString(nil, uuid) as String
            return value.caseInsensitiveCompare(display.colorSyncUUID) == .orderedSame
        }?.visibleFrame
    }
}
