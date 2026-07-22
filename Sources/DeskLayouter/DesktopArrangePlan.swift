import DeskLayouterCore

// The arming state machine for runtime Arrange (issue #27, ADR-0003).
//
// Pressing Arrange arranges the active Desktop immediately and then "arms" every
// OTHER Desktop that has Layouts: the first time such a Desktop becomes active it
// is arranged once and disarmed, and once the last armed Desktop has been visited
// the app stops observing Space changes entirely (it is not a permanent
// background observer). Pressing Arrange again re-arms.
//
// That policy is the crux of the feature and the part most likely to be wrong, so
// it lives here as a pure, side-effect-free value type — no `NSWorkspace`, no
// arrange engine, no clock. It only decides, given the set of Desktops with
// Layouts and which Desktop is active, which Desktops to arm, which Desktop to
// arrange on each Space change, and exactly when to tear the observation down. The
// live notification wiring and the arrange calls are the caller's job (see
// `EditorModel`), driven entirely by this type's decisions.
public struct DesktopArrangePlan: Equatable, Sendable {
    /// The Desktops still waiting to be arranged on their first visit. Empty when
    /// idle (never pressed, or every armed Desktop has since been arranged).
    public private(set) var armedDesktops: Set<Int>

    public init() {
        armedDesktops = []
    }

    /// Whether the caller should currently be observing Space changes. True
    /// exactly while at least one Desktop is armed; the caller starts observing
    /// when this becomes true and tears the observation down when it becomes
    /// false.
    public var isObserving: Bool { !armedDesktops.isEmpty }

    /// The result of pressing Arrange.
    public struct PressOutcome: Equatable, Sendable {
        /// Whether any other Desktop was armed, so the caller should start
        /// observing Space changes. False means the whole job finished with the
        /// immediate pass and no observation should be started.
        public let shouldObserve: Bool
    }

    /// What to do when a Desktop becomes active while observing.
    public enum Visit: Equatable, Sendable {
        /// The Desktop is not armed (no Layouts, already arranged, or unknown).
        /// Do nothing.
        case ignore
        /// Arrange this Desktop once. `tearDownAfter` is true when it was the last
        /// armed Desktop, so the caller stops observing afterwards.
        case arrange(tearDownAfter: Bool)
    }

    /// Presses Arrange: arms every Desktop that has a Layout except the active one
    /// (which the caller arranges immediately), discarding any prior arming so a
    /// re-press starts a fresh cycle.
    ///
    /// A `nil` `activeDesktop` (the active Desktop could not be identified) arms
    /// every Desktop with a Layout, so nothing is silently dropped; the immediate
    /// pass still runs and simply re-arranges the active one again on its "first"
    /// visit if it is ever revisited.
    @discardableResult
    public mutating func press(desktopsWithLayouts: Set<Int>, activeDesktop: Int?) -> PressOutcome {
        if let activeDesktop {
            armedDesktops = desktopsWithLayouts.subtracting([activeDesktop])
        } else {
            armedDesktops = desktopsWithLayouts
        }
        return PressOutcome(shouldObserve: isObserving)
    }

    /// Records that `desktop` became active. Returns whether to arrange it and,
    /// when arranged, whether it was the last armed Desktop (so the caller tears
    /// the observation down). A Desktop is arranged at most once per press: it is
    /// removed from the armed set here, so a later revisit is ignored. An unknown
    /// (`nil`) or un-armed Desktop is ignored, so a Desktop never visited after the
    /// press is never arranged.
    @discardableResult
    public mutating func desktopBecameActive(_ desktop: Int?) -> Visit {
        guard let desktop, armedDesktops.contains(desktop) else { return .ignore }
        armedDesktops.remove(desktop)
        return .arrange(tearDownAfter: armedDesktops.isEmpty)
    }
}

/// Multi-Display Arrange arming. The destination key includes physical Display
/// identity and Desktop number, so Desktop 2 on two Displays is armed twice and
/// each is completed only by visiting that exact destination.
public struct MultiDisplayArrangePlan: Equatable, Sendable {
    public private(set) var armedDestinations: Set<DesktopAddress> = []

    public init() {}

    public var isObserving: Bool { !armedDestinations.isEmpty }

    @discardableResult
    public mutating func press(
        destinationsWithLayouts: Set<DesktopAddress>,
        visibleDestinations: Set<DesktopAddress>
    ) -> Bool {
        armedDestinations = destinationsWithLayouts.subtracting(visibleDestinations)
        return isObserving
    }

    /// Completes only destinations that were armed. Returns those completed by
    /// this visit so callers never arrange/report another Assignment destination.
    @discardableResult
    public mutating func completeVisible(
        _ destinations: Set<DesktopAddress>
    ) -> Set<DesktopAddress> {
        let completed = armedDestinations.intersection(destinations)
        armedDestinations.subtract(completed)
        return completed
    }
}
