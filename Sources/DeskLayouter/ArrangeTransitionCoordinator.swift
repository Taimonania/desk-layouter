import Foundation

// The bounded settling/retry policy for runtime Arrange across Desktop
// transitions (issue #62), built on the live active-Desktop resolution and
// per-Desktop scoping from issue #61.
//
// `NSWorkspace.activeSpaceDidChangeNotification` fires the instant a Desktop
// change *begins*, before the new Desktop's Accessibility window set is ready and
// sometimes before the live active Space has even flipped in WindowServer. Acting
// synchronously on that notification — as the code did before this change — armed
// a Desktop could be "completed" from an early or stale pass: the previous
// Desktop's windows arranged and the new Desktop's windows falsely reported
// unavailable.
//
// This coordinator waits for the transition to settle before completing an armed
// Desktop. On each Space-change notification it starts a bounded retry cycle:
// every attempt re-resolves the LIVE active Desktop (never trusting the Desktop
// number captured when the notification fired, so rapid multi-Desktop moves land
// on the right one) and only arranges — and only then disarms — when that live
// Desktop is armed and its window set is actually present. Transient unknown /
// stale / previous-Desktop states retry rather than disarm or emit misleading
// feedback; a re-press starts a fresh cycle whose new generation invalidates any
// still-pending attempt.
//
// The arming set itself stays in the pure `DesktopArrangePlan`; the live side
// effects (resolving the active Desktop, running the Arrange pass, presenting
// feedback, tearing observation down) are injected as closures so the whole
// policy is exercised deterministically in tests against a controllable
// `TransitionScheduler` — no real sleeps, no `NSWorkspace`, no Accessibility.

/// Schedules a delayed settling retry. Injected so tests drive the retry cadence
/// deterministically instead of waiting on a real clock. Production schedules on
/// the main queue.
@MainActor
public protocol TransitionScheduler {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

/// The production scheduler: each retry runs on the main run loop after the given
/// delay, matching where the Space-change notification and the Accessibility work
/// already live.
@MainActor
public final class MainQueueTransitionScheduler: TransitionScheduler {
    public init() {}

    public func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { work() }
        }
    }
}

@MainActor
public final class ArrangeTransitionCoordinator {
    /// The retry bound. `maxRetries` retries follow the immediate first attempt, so
    /// a cycle makes at most `maxRetries + 1` attempts over roughly
    /// `maxRetries * retryInterval` seconds before giving up on a transition that
    /// never settles.
    public struct Configuration: Sendable {
        public var maxRetries: Int
        public var retryInterval: TimeInterval

        public init(maxRetries: Int = 25, retryInterval: TimeInterval = 0.1) {
            self.maxRetries = maxRetries
            self.retryInterval = retryInterval
        }
    }

    private let scheduler: TransitionScheduler
    private let configuration: Configuration
    private let resolveActiveDesktop: () -> Int?
    private let performArrange: (Int) -> ArrangeReport?
    private let presentReport: (ArrangeReport, Int, [Int]) -> Void
    private let stopObserving: () -> Void

    private var plan = DesktopArrangePlan()
    // Increments on every press. A still-pending retry captures the generation it
    // was scheduled under and drops itself when a newer press has moved on, so an
    // obsolete attempt can never overwrite the new cycle's state or feedback.
    private var generation = 0
    // Whether a settling cycle is in flight. Guards against a second cycle being
    // started by a duplicate notification while one is already running.
    private var isSettling = false
    // Retries left in the current cycle before it gives up.
    private var attemptsRemaining = 0

    public init(
        scheduler: TransitionScheduler,
        configuration: Configuration = Configuration(),
        resolveActiveDesktop: @escaping () -> Int?,
        performArrange: @escaping (Int) -> ArrangeReport?,
        presentReport: @escaping (ArrangeReport, Int, [Int]) -> Void,
        stopObserving: @escaping () -> Void
    ) {
        self.scheduler = scheduler
        self.configuration = configuration
        self.resolveActiveDesktop = resolveActiveDesktop
        self.performArrange = performArrange
        self.presentReport = presentReport
        self.stopObserving = stopObserving
    }

    /// The Desktops still armed for their first successful visit.
    public var armedDesktops: Set<Int> { plan.armedDesktops }

    /// Whether the caller should currently be observing Space changes.
    public var isObserving: Bool { plan.isObserving }

    /// Begins a fresh Arrange cycle. The caller has already run the immediate pass
    /// against `activeDesktop`; this arms every OTHER Desktop with a Layout and
    /// invalidates any settling attempt still pending from a previous press.
    /// Returns whether the caller should observe Space changes.
    @discardableResult
    public func press(desktopsWithLayouts: Set<Int>, activeDesktop: Int?) -> Bool {
        generation += 1
        isSettling = false
        attemptsRemaining = 0
        return plan.press(
            desktopsWithLayouts: desktopsWithLayouts,
            activeDesktop: activeDesktop
        ).shouldObserve
    }

    /// Handles a Space-change notification. Starts a bounded settling cycle, unless
    /// nothing is armed (ignore) or a cycle is already in flight (dedupe duplicate
    /// notifications — the running cycle already re-resolves the live Desktop on
    /// every attempt, so it will pick up wherever the user actually landed).
    public func spaceChangeNotified() {
        guard plan.isObserving, !isSettling else { return }
        isSettling = true
        attemptsRemaining = configuration.maxRetries
        attempt(generation: generation)
    }

    private func attempt(generation attemptGeneration: Int) {
        // Drop an attempt left over from a superseded cycle.
        guard attemptGeneration == generation, isSettling else { return }

        let active = resolveActiveDesktop()
        guard let active, plan.armedDesktops.contains(active) else {
            // Unknown, stale, or a passed-through Desktop with no Layout: never
            // arrange it and never disarm anything. Retry within the bound in case
            // the live active Desktop is still catching up to the transition.
            retryOrGiveUp(generation: attemptGeneration)
            return
        }

        guard let report = performArrange(active) else {
            // The pass could not run at all (e.g. Accessibility not granted); the
            // caller has already surfaced that failure. End the cycle without
            // disarming so the Desktop stays eligible for a later attempt.
            isSettling = false
            return
        }

        let foundWindows = !report.arranged.isEmpty || !report.resisted.isEmpty
        guard foundWindows || attemptsRemaining == 0 else {
            // The armed Desktop is live-active but none of its windows have
            // appeared yet: keep waiting rather than emit a misleading skipped
            // result. Nothing moved, since every candidate was skipped.
            scheduleRetry(generation: attemptGeneration)
            return
        }

        // Settled: either the Desktop's window set is ready, or the bound is
        // reached and genuinely window-less apps are now legitimately skipped.
        // Disarm and present exactly once against the settled, correctly
        // identified Desktop.
        let visit = plan.desktopBecameActive(active)
        isSettling = false
        presentReport(report, active, Array(plan.armedDesktops))
        if case .arrange(true) = visit {
            stopObserving()
        }
    }

    private func retryOrGiveUp(generation: Int) {
        guard attemptsRemaining > 0 else {
            // Bound reached without ever landing on an armed, identified Desktop.
            // Give up this cycle without disarming or emitting feedback; the armed
            // Desktops stay eligible and observation continues for a later change.
            isSettling = false
            return
        }
        scheduleRetry(generation: generation)
    }

    private func scheduleRetry(generation: Int) {
        attemptsRemaining -= 1
        scheduler.schedule(after: configuration.retryInterval) { [weak self] in
            self?.attempt(generation: generation)
        }
    }
}
