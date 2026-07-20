import DeskLayouterCore

// Verifies the pure Arrange-report presenter (issue #34, ADR-0003): a successful
// pass names the affected application display names and the numbered active
// Desktop, using a deterministic natural-language list for multiple apps; the
// Desktops still armed for their first visit are named explicitly; applications
// with no available window are named as skipped without turning the pass into an
// error; the all-skipped case collapses to the "No available windows" summary; a
// window that refuses to move or resize reads as a distinct error; and a later
// armed-Desktop pass reports the newly active Desktop plus the remaining armed
// ones. No localization-inflection markup ever reaches the rendered string.
// Hand-rolled @main runner, no XCTest — matching the other test targets.

@main
struct ArrangeReportTestRunner {
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

        // MARK: - Single arranged application names the app and the Desktop.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 1,
                arranged: ["Comet"],
                skipped: [],
                resisted: [],
                pendingDesktops: []
            )
            check(
                "single arranged app names it and the numbered Desktop",
                a.message == "Arranged Comet on Desktop 1.",
                "got \(a.message)"
            )
            check("a clean pass reads as a success", a.tone == .success)
        }

        // MARK: - Multiple arranged applications use an "A and B" list.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 2,
                // Deliberately out of order to prove deterministic sorting.
                arranged: ["Notion", "Conductor"],
                skipped: [],
                resisted: [],
                pendingDesktops: []
            )
            check(
                "two arranged apps use a deterministic natural-language list",
                a.message == "Arranged Conductor and Notion on Desktop 2.",
                "got \(a.message)"
            )
        }

        // MARK: - Three arranged applications use an Oxford-comma serial list.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 3,
                arranged: ["Notion", "Comet", "Conductor"],
                skipped: [],
                resisted: [],
                pendingDesktops: []
            )
            check(
                "three arranged apps use an Oxford-comma serial list",
                a.message == "Arranged Comet, Conductor, and Notion on Desktop 3.",
                "got \(a.message)"
            )
        }

        // MARK: - A single pending (armed) Desktop is named explicitly.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 1,
                arranged: ["Comet"],
                skipped: [],
                resisted: [],
                pendingDesktops: [2]
            )
            check(
                "one armed Desktop is named with singular wording",
                a.message == "Arranged Comet on Desktop 1. Desktop 2 will be arranged when you visit it.",
                "got \(a.message)"
            )
        }

        // MARK: - Multiple pending Desktops are named with plural wording.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 1,
                arranged: ["Comet"],
                skipped: [],
                resisted: [],
                pendingDesktops: [3, 2]
            )
            check(
                "multiple armed Desktops are named with plural wording, sorted",
                a.message == "Arranged Comet on Desktop 1. Desktops 2 and 3 will be arranged when you visit them.",
                "got \(a.message)"
            )
        }

        // MARK: - Skipped apps are named without turning the pass into an error.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 1,
                arranged: ["Comet"],
                skipped: ["Slack"],
                resisted: [],
                pendingDesktops: []
            )
            check(
                "a skipped app is named alongside the arranged ones",
                a.message == "Arranged Comet on Desktop 1. Skipped Slack with no available window.",
                "got \(a.message)"
            )
            check("a skipped app does not make the pass an error", a.tone == .success)
        }

        // MARK: - No application has an available window.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 4,
                arranged: [],
                skipped: ["Slack", "Mail"],
                resisted: [],
                pendingDesktops: []
            )
            check(
                "an all-skipped pass collapses to the No-available-windows summary",
                a.message == "No available windows to arrange on Desktop 4.",
                "got \(a.message)"
            )
            check("the all-skipped pass is not an error", a.tone == .success)
        }

        // MARK: - A resistant window reads as a distinct error.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 1,
                arranged: ["Comet"],
                skipped: [],
                resisted: ["Notion"],
                pendingDesktops: []
            )
            check(
                "a resistant window is named distinctly as an error",
                a.message == "Arranged Comet on Desktop 1. Notion refused to move or resize.",
                "got \(a.message)"
            )
            check("a resistant window makes the pass an error", a.tone == .failure)
        }

        // MARK: - A resistant window when nothing else was arranged names the Desktop.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 2,
                arranged: [],
                skipped: [],
                resisted: ["Notion", "Comet"],
                pendingDesktops: []
            )
            check(
                "a resist-only pass names the Desktop and uses the serial list",
                a.message == "Comet and Notion refused to move or resize on Desktop 2.",
                "got \(a.message)"
            )
            check("a resist-only pass is an error", a.tone == .failure)
        }

        // MARK: - A later armed-Desktop pass reports the newly active Desktop.

        do {
            // Simulates visiting armed Desktop 2 with Desktop 3 still armed.
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 2,
                arranged: ["Notion"],
                skipped: [],
                resisted: [],
                pendingDesktops: [3]
            )
            check(
                "an armed-Desktop pass reports the newly active Desktop and the remaining one",
                a.message == "Arranged Notion on Desktop 2. Desktop 3 will be arranged when you visit it.",
                "got \(a.message)"
            )
        }

        // MARK: - An unidentifiable active Desktop degrades gracefully.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: nil,
                arranged: ["Comet"],
                skipped: [],
                resisted: [],
                pendingDesktops: []
            )
            check(
                "a nil active Desktop names the active Desktop generically",
                a.message == "Arranged Comet on the active Desktop.",
                "got \(a.message)"
            )
        }

        // MARK: - No inflection markup or formatting syntax leaks into the message.

        do {
            let messages = [
                ArrangeReportPresenter.announce(
                    activeDesktop: 1, arranged: ["Comet"], skipped: ["Slack"],
                    resisted: ["Notion"], pendingDesktops: [2, 3]
                ).message,
                ArrangeReportPresenter.announce(
                    activeDesktop: 1, arranged: [], skipped: ["Slack"],
                    resisted: [], pendingDesktops: []
                ).message,
            ]
            let markers = ["^[", "](inflect", "%", "{", "}"]
            check(
                "no localization-inflection markup or formatting syntax is rendered",
                messages.allSatisfy { message in markers.allSatisfy { !message.contains($0) } },
                "got \(messages)"
            )
        }

        if failures.isEmpty {
            print("Arrange report tests passed")
        } else {
            fatalError("Arrange report tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
