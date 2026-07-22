import CoreGraphics
import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

// Deterministic coverage for issue #62: the bounded settling/retry policy that
// waits for a Desktop transition to settle before completing an armed Desktop.
//
// `ArrangeTransitionCoordinator` owns the policy; every live seam — resolving the
// live active Desktop, running the Arrange pass, presenting feedback, tearing the
// observation down — is an injected closure, and retries run through an injected
// `TransitionScheduler`. So the whole retry/settling behavior is exercised here
// with a hand-driven scheduler and no real sleeps, `NSWorkspace`, or Accessibility.
//
// Hand-rolled @main runner, no XCTest — matching the other test targets. The body
// runs under `MainActor.assumeIsolated` because the coordinator and scheduler are
// main-actor isolated (as they are in the app), and the executable's entry point
// already runs on the main thread.

/// A scheduler that records the retries it is handed and fires them only when the
/// test asks, so a transition's timeline is fully under the test's control.
@MainActor
final class ManualScheduler: TransitionScheduler {
    private var pending: [@MainActor () -> Void] = []

    var pendingCount: Int { pending.count }

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        pending.append(work)
    }

    /// Fires the earliest pending retry (which may itself schedule another).
    @discardableResult
    func runNext() -> Bool {
        guard !pending.isEmpty else { return false }
        let work = pending.removeFirst()
        work()
        return true
    }

    /// Drains every pending retry, counting how many fired. The `limit` guards a
    /// runaway loop from hanging the suite if the policy ever failed to bound.
    @discardableResult
    func runAll(limit: Int = 1000) -> Int {
        var fired = 0
        while fired < limit, runNext() { fired += 1 }
        return fired
    }
}

/// The scriptable world a coordinator runs against: the test sets the live active
/// Desktop and the Arrange outcome per attempt, and reads back what was arranged,
/// presented, and torn down.
@MainActor
final class Harness {
    let scheduler = ManualScheduler()
    var liveActiveDesktop: Int?
    var arrange: (Int) -> ArrangeReport? = { _ in nil }
    private(set) var arrangeCalls: [Int] = []
    private(set) var presentations: [(desktop: Int, report: ArrangeReport, pending: [Int])] = []
    private(set) var stopObservingCount = 0
    var coordinator: ArrangeTransitionCoordinator!

    init(configuration: ArrangeTransitionCoordinator.Configuration) {
        coordinator = ArrangeTransitionCoordinator(
            scheduler: scheduler,
            configuration: configuration,
            resolveActiveDesktop: { [weak self] in self?.liveActiveDesktop ?? nil },
            performArrange: { [weak self] desktop in
                guard let self else { return nil }
                arrangeCalls.append(desktop)
                return arrange(desktop)
            },
            presentReport: { [weak self] report, desktop, pending in
                self?.presentations.append((desktop: desktop, report: report, pending: pending))
            },
            stopObserving: { [weak self] in self?.stopObservingCount += 1 }
        )
    }
}

func arranged(_ bundleIdentifiers: String...) -> ArrangeReport {
    ArrangeReport(arranged: bundleIdentifiers, skipped: [], resisted: [])
}

func skipped(_ bundleIdentifiers: String...) -> ArrangeReport {
    ArrangeReport(arranged: [], skipped: bundleIdentifiers, resisted: [])
}

@main
struct TransitionTestRunner {
    static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    static func run() {
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

        let config = ArrangeTransitionCoordinator.Configuration(maxRetries: 3, retryInterval: 0)

        // MARK: - Notification fires before the live Space actually changes.

        do {
            let h = Harness(configuration: config)
            // Press on Desktop 1 with Layouts on 1 and 2 → arms {2}.
            h.coordinator.press(desktopsWithLayouts: [1, 2], activeDesktop: 1)
            check("press arms the other Desktop", h.coordinator.armedDesktops == [2])

            // The notification arrives but the live active Space is still reporting
            // the previous Desktop (1, which is not armed).
            h.liveActiveDesktop = 1
            h.coordinator.spaceChangeNotified()
            check("no Arrange pass runs while the live Desktop is still the previous one", h.arrangeCalls.isEmpty)
            check("nothing is disarmed by the stale pre-transition attempt", h.coordinator.armedDesktops == [2])
            check("no feedback is presented during the transition", h.presentations.isEmpty)
            check("a retry is pending", h.scheduler.pendingCount == 1)

            // The live Space now flips to Desktop 2 with its windows present.
            h.liveActiveDesktop = 2
            h.arrange = { _ in arranged("com.desktop2.app") }
            h.scheduler.runAll()
            check("Arrange runs once against the settled Desktop 2", h.arrangeCalls == [2], "got \(h.arrangeCalls)")
            check("Desktop 2 is disarmed after the settled pass", h.coordinator.armedDesktops.isEmpty)
            check("feedback is presented exactly once for Desktop 2", h.presentations.count == 1)
            check("the presentation names the settled Desktop 2", h.presentations.first?.desktop == 2)
            check("observation is torn down after the last armed Desktop", h.stopObservingCount == 1)
            check("the coordinator stops observing", h.coordinator.isObserving == false)
        }

        // MARK: - Live Space changes before the Accessibility windows appear.

        do {
            let h = Harness(configuration: config)
            h.coordinator.press(desktopsWithLayouts: [1, 2], activeDesktop: 1) // arms {2}
            h.liveActiveDesktop = 2

            // The window set is not ready yet: the first two passes find no window
            // (all skipped), the third finds the real window.
            var passes = 0
            h.arrange = { _ in
                passes += 1
                return passes < 3 ? skipped("com.desktop2.app") : arranged("com.desktop2.app")
            }

            h.coordinator.spaceChangeNotified()
            check("the first empty pass does not disarm Desktop 2", h.coordinator.armedDesktops == [2])
            check("the first empty pass presents no misleading skipped feedback", h.presentations.isEmpty)

            h.scheduler.runAll()
            check("Arrange retried until the window set appeared", h.arrangeCalls == [2, 2, 2], "got \(h.arrangeCalls)")
            check("Desktop 2 is disarmed only after the real pass", h.coordinator.armedDesktops.isEmpty)
            check("feedback is presented exactly once, for the settled pass", h.presentations.count == 1)
            check("the settled presentation reports the arranged window", h.presentations.first?.report.arranged == ["com.desktop2.app"])
            check("observation is torn down", h.stopObservingCount == 1)
        }

        // MARK: - Genuinely window-less apps are still skipped once settled.

        do {
            let h = Harness(configuration: config)
            h.coordinator.press(desktopsWithLayouts: [1, 2], activeDesktop: 1) // arms {2}
            h.liveActiveDesktop = 2
            h.arrange = { _ in skipped("com.desktop2.app") } // never has a window

            h.coordinator.spaceChangeNotified()
            h.scheduler.runAll()
            check("Arrange was attempted up to the retry bound", h.arrangeCalls == [2, 2, 2, 2], "got \(h.arrangeCalls)")
            check("the genuinely window-less app is reported as skipped once settled", h.presentations.first?.report.skipped == ["com.desktop2.app"])
            check("Desktop 2 is disarmed after the bounded settle", h.coordinator.armedDesktops.isEmpty)
            check("feedback is presented exactly once", h.presentations.count == 1)
            check("observation is torn down", h.stopObservingCount == 1)
        }

        // MARK: - Duplicate Space-change notifications do not double-arrange.

        do {
            let h = Harness(configuration: config)
            h.coordinator.press(desktopsWithLayouts: [1, 2], activeDesktop: 1) // arms {2}
            h.liveActiveDesktop = 1 // still stale, so the first cycle keeps retrying

            h.coordinator.spaceChangeNotified()
            let pendingAfterFirst = h.scheduler.pendingCount
            h.coordinator.spaceChangeNotified() // duplicate while settling
            check("a duplicate notification does not start a second settling cycle", h.scheduler.pendingCount == pendingAfterFirst, "got \(h.scheduler.pendingCount)")

            h.liveActiveDesktop = 2
            h.arrange = { _ in arranged("com.desktop2.app") }
            h.scheduler.runAll()
            check("Desktop 2 is arranged exactly once despite the duplicate notification", h.arrangeCalls == [2], "got \(h.arrangeCalls)")
            check("feedback is presented exactly once", h.presentations.count == 1)
        }

        // MARK: - A transition that never resolves within the retry bound.

        do {
            let h = Harness(configuration: config)
            h.coordinator.press(desktopsWithLayouts: [1, 2], activeDesktop: 1) // arms {2}
            h.liveActiveDesktop = nil // the active Desktop never becomes identifiable

            h.coordinator.spaceChangeNotified()
            let firedRetries = h.scheduler.runAll()
            check("the cycle retries exactly maxRetries times then gives up", firedRetries == config.maxRetries, "got \(firedRetries)")
            check("no Arrange pass runs while the Desktop is unidentifiable", h.arrangeCalls.isEmpty)
            check("nothing is disarmed by a transition that never settles", h.coordinator.armedDesktops == [2])
            check("no misleading feedback is presented", h.presentations.isEmpty)
            check("observation is not torn down; the Desktop stays eligible", h.stopObservingCount == 0)
            check("the coordinator is still observing for a later change", h.coordinator.isObserving)

            // A later, identifiable change still settles normally.
            h.liveActiveDesktop = 2
            h.arrange = { _ in arranged("com.desktop2.app") }
            h.coordinator.spaceChangeNotified()
            h.scheduler.runAll()
            check("a later identifiable change still arranges the armed Desktop", h.arrangeCalls == [2])
            check("Desktop 2 is disarmed after the eventual settle", h.coordinator.armedDesktops.isEmpty)
        }

        // MARK: - Rapid multi-Desktop moves arrange under the right number.

        do {
            let h = Harness(configuration: config)
            h.coordinator.press(desktopsWithLayouts: [1, 2, 3], activeDesktop: 1) // arms {2, 3}
            // The user swept 1 → 2 → 3; by the time the pass runs the live active
            // Desktop is 3. The armed Desktop 2 was passed over, not landed on.
            h.liveActiveDesktop = 3
            h.arrange = { desktop in arranged("com.desktop\(desktop).app") }

            h.coordinator.spaceChangeNotified()
            h.scheduler.runAll()
            check("only the live-resolved Desktop 3 is arranged, not the passed-over 2", h.arrangeCalls == [3], "got \(h.arrangeCalls)")
            check("the passed-over Desktop 2 remains armed for a later visit", h.coordinator.armedDesktops == [2])
            check("observation continues while a Desktop is still armed", h.coordinator.isObserving)
            check("the presentation names Desktop 3", h.presentations.first?.desktop == 3)

            // Later the user returns to Desktop 2, which finally settles.
            h.liveActiveDesktop = 2
            h.coordinator.spaceChangeNotified()
            h.scheduler.runAll()
            check("returning to the still-armed Desktop 2 arranges it", h.arrangeCalls == [3, 2], "got \(h.arrangeCalls)")
            check("every armed Desktop has now been visited", h.coordinator.armedDesktops.isEmpty)
            check("observation stops after the last armed Desktop", h.stopObservingCount == 1)
        }

        // MARK: - Pressing Arrange again mid-transition starts a fresh cycle.

        do {
            let h = Harness(configuration: config)
            h.coordinator.press(desktopsWithLayouts: [1, 2], activeDesktop: 1) // arms {2}
            h.liveActiveDesktop = 1 // stale, so a retry stays pending
            h.coordinator.spaceChangeNotified()
            check("a retry is pending from the first cycle", h.scheduler.pendingCount == 1)

            // Re-press: a fresh cycle arming {3}. The pending retry is now obsolete.
            h.coordinator.press(desktopsWithLayouts: [1, 3], activeDesktop: 1)
            check("the re-press recomputes the armed set", h.coordinator.armedDesktops == [3])

            // Firing the obsolete retry must not touch the new cycle's state.
            h.liveActiveDesktop = 2
            h.arrange = { _ in arranged("com.desktop2.app") }
            h.scheduler.runAll()
            check("the obsolete attempt runs no Arrange pass", h.arrangeCalls.isEmpty, "got \(h.arrangeCalls)")
            check("the obsolete attempt presents no feedback", h.presentations.isEmpty)
            check("the obsolete attempt leaves the fresh cycle's armed set intact", h.coordinator.armedDesktops == [3])

            // The fresh cycle still settles normally on its own notification.
            h.liveActiveDesktop = 3
            h.arrange = { _ in arranged("com.desktop3.app") }
            h.coordinator.spaceChangeNotified()
            h.scheduler.runAll()
            check("the fresh cycle arranges its own Desktop 3", h.arrangeCalls == [3], "got \(h.arrangeCalls)")
            check("the fresh cycle disarms Desktop 3", h.coordinator.armedDesktops.isEmpty)
        }

        if failures.isEmpty {
            print("Arrange transition tests passed")
        } else {
            fatalError("Arrange transition tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
