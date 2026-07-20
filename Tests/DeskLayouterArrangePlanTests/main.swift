import DeskLayouterMacOS

// Verifies the pure arming state machine `DesktopArrangePlan` (issue #27,
// ADR-0003): pressing arms every OTHER Desktop with a Layout, each armed Desktop
// is arranged exactly once on its first visit and then disarmed, the observation
// is torn down after the last armed Desktop is arranged, a Desktop never visited
// (or with no Layout) is never arranged, and pressing again re-arms from scratch.
// Hand-rolled @main runner, no XCTest — matching the other test targets.

@main
struct ArrangePlanTestRunner {
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

        // MARK: - Press arms every OTHER Desktop that has a Layout.

        do {
            var plan = DesktopArrangePlan()
            let outcome = plan.press(desktopsWithLayouts: [1, 2, 3], activeDesktop: 1)
            check(
                "press arms every Desktop with a Layout except the active one",
                plan.armedDesktops == [2, 3],
                "got \(plan.armedDesktops)"
            )
            check("observation starts because other Desktops are armed", outcome.shouldObserve)
            check("isObserving reflects the armed set", plan.isObserving)
        }

        // MARK: - Active Desktop without a Layout: still arm the others.

        do {
            var plan = DesktopArrangePlan()
            let outcome = plan.press(desktopsWithLayouts: [2, 3], activeDesktop: 1)
            check("only Desktops with Layouts are armed", plan.armedDesktops == [2, 3], "got \(plan.armedDesktops)")
            check("observation still starts for the armed Desktops", outcome.shouldObserve)
        }

        // MARK: - Only the active Desktop has a Layout: no observation.

        do {
            var plan = DesktopArrangePlan()
            let outcome = plan.press(desktopsWithLayouts: [1], activeDesktop: 1)
            check("nothing is armed when only the active Desktop has a Layout", plan.armedDesktops.isEmpty)
            check("no observation is started when nothing is armed", outcome.shouldObserve == false)
            check("isObserving is false", plan.isObserving == false)
        }

        // MARK: - No Desktops have Layouts at all.

        do {
            var plan = DesktopArrangePlan()
            let outcome = plan.press(desktopsWithLayouts: [], activeDesktop: 1)
            check("nothing armed with no Layouts anywhere", plan.armedDesktops.isEmpty)
            check("no observation started", outcome.shouldObserve == false)
        }

        // MARK: - Arrange once per visit, then disarm; tear down after the last.

        do {
            var plan = DesktopArrangePlan()
            plan.press(desktopsWithLayouts: [1, 2, 3], activeDesktop: 1) // armed {2,3}

            let firstVisit = plan.desktopBecameActive(2)
            check(
                "first visit to an armed Desktop arranges it and is not the last",
                firstVisit == .arrange(tearDownAfter: false),
                "got \(firstVisit)"
            )
            check("the visited Desktop is disarmed", plan.armedDesktops == [3], "got \(plan.armedDesktops)")

            let revisit = plan.desktopBecameActive(2)
            check("revisiting an already-arranged Desktop is ignored", revisit == .ignore, "got \(revisit)")
            check("the armed set is unchanged by the revisit", plan.armedDesktops == [3], "got \(plan.armedDesktops)")

            let lastVisit = plan.desktopBecameActive(3)
            check(
                "visiting the last armed Desktop arranges it and signals teardown",
                lastVisit == .arrange(tearDownAfter: true),
                "got \(lastVisit)"
            )
            check("the armed set is empty after the last visit", plan.armedDesktops.isEmpty)
            check("observation is over after the last armed Desktop", plan.isObserving == false)
        }

        // MARK: - A Desktop never visited (or with no Layout) is never arranged.

        do {
            var plan = DesktopArrangePlan()
            plan.press(desktopsWithLayouts: [2, 3], activeDesktop: 1) // armed {2,3}
            let unarmed = plan.desktopBecameActive(4) // Desktop 4 has no Layout
            check("visiting a Desktop with no Layout is ignored", unarmed == .ignore, "got \(unarmed)")
            check("nothing is disarmed by an unarmed visit", plan.armedDesktops == [2, 3], "got \(plan.armedDesktops)")
            // Desktop 3 is never visited here, so it stays armed forever and is
            // never arranged — coverage is over time, not instantaneous.
            check("an unvisited armed Desktop remains armed and unarranged", plan.armedDesktops.contains(3))
        }

        // MARK: - An unknown active Desktop is ignored on a Space change.

        do {
            var plan = DesktopArrangePlan()
            plan.press(desktopsWithLayouts: [2, 3], activeDesktop: 1)
            let unknown = plan.desktopBecameActive(nil)
            check("an unidentifiable active Desktop is ignored", unknown == .ignore, "got \(unknown)")
            check("the armed set survives an unknown Space change", plan.armedDesktops == [2, 3])
        }

        // MARK: - A nil active Desktop at press arms everything with a Layout.

        do {
            var plan = DesktopArrangePlan()
            let outcome = plan.press(desktopsWithLayouts: [1, 2, 3], activeDesktop: nil)
            check("a nil active Desktop arms every Desktop with a Layout", plan.armedDesktops == [1, 2, 3])
            check("observation starts", outcome.shouldObserve)
        }

        // MARK: - Pressing again re-arms all Desktops with Layouts.

        do {
            var plan = DesktopArrangePlan()
            plan.press(desktopsWithLayouts: [1, 2, 3], activeDesktop: 1) // armed {2,3}
            plan.desktopBecameActive(2)
            plan.desktopBecameActive(3) // torn down, armed empty
            check("precondition: observation ended", plan.isObserving == false)

            let outcome = plan.press(desktopsWithLayouts: [1, 2, 3], activeDesktop: 1)
            check("re-pressing re-arms the other Desktops from scratch", plan.armedDesktops == [2, 3], "got \(plan.armedDesktops)")
            check("re-press restarts observation", outcome.shouldObserve)

            // Re-press mid-cycle also resets, rather than accumulating.
            var mid = DesktopArrangePlan()
            mid.press(desktopsWithLayouts: [1, 2, 3], activeDesktop: 1) // armed {2,3}
            mid.desktopBecameActive(2) // armed {3}
            mid.press(desktopsWithLayouts: [1, 2, 3, 4], activeDesktop: 2) // re-press, active now 2
            check("re-pressing mid-cycle recomputes the armed set", mid.armedDesktops == [1, 3, 4], "got \(mid.armedDesktops)")
        }

        if failures.isEmpty {
            print("Arrange plan tests passed")
        } else {
            fatalError("Arrange plan tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
