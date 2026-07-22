import DeskLayouterCore
import DeskLayouterMacOS

@main
struct WhatsNewTestRunner {
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

        // Three released versions, newest first (as parsed from CHANGELOG.md).
        let entries = [
            ChangelogEntry(version: "0.3.0", date: "2026-09-01", highlights: ["Three-a", "Three-b"]),
            ChangelogEntry(version: "0.2.0", date: "2026-08-01", highlights: ["Two-a"]),
            ChangelogEntry(version: "0.1.0", date: "2026-07-01", highlights: ["One-a"]),
        ]

        // MARK: - Fresh install: Welcome takes precedence, baseline recorded

        do {
            let launch = WhatsNew.onLaunch(currentVersion: "0.3.0", lastSeenVersion: nil, entries: entries)
            check(
                "a fresh install records the baseline and shows nothing",
                launch == .recordBaseline(version: "0.3.0"),
                "\(launch)"
            )
        }

        // MARK: - Dev / unbundled build: nothing

        do {
            let launch = WhatsNew.onLaunch(currentVersion: nil, lastSeenVersion: "0.1.0", entries: entries)
            check("a dev build (no current version) shows nothing", launch == .none, "\(launch)")
        }

        do {
            let launch = WhatsNew.onLaunch(currentVersion: nil, lastSeenVersion: nil, entries: entries)
            check("a dev build on a fresh install shows nothing", launch == .none, "\(launch)")
        }

        // MARK: - Equal / downgrade: nothing

        do {
            let launch = WhatsNew.onLaunch(currentVersion: "0.2.0", lastSeenVersion: "0.2.0", entries: entries)
            check("an equal version shows nothing", launch == .none, "\(launch)")
        }

        do {
            let launch = WhatsNew.onLaunch(currentVersion: "0.1.0", lastSeenVersion: "0.2.0", entries: entries)
            check("a downgrade shows nothing", launch == .none, "\(launch)")
        }

        // MARK: - Single-version upgrade

        do {
            let launch = WhatsNew.onLaunch(currentVersion: "0.2.0", lastSeenVersion: "0.1.0", entries: entries)
            guard case let .present(whatsNew) = launch else {
                check("a single-version upgrade presents What's-New", false, "\(launch)")
                report(failures)
                return
            }
            check("presented on upgrade", whatsNew.isPresented)
            check("headline version is the current version", whatsNew.version == "0.2.0", whatsNew.version)
            check(
                "only the newly-reached version is shown",
                whatsNew.sections.map(\.version) == ["0.2.0"],
                "\(whatsNew.sections.map(\.version))"
            )
        }

        // MARK: - Skipped multiple versions: grouped, newest first

        do {
            let launch = WhatsNew.onLaunch(currentVersion: "0.3.0", lastSeenVersion: "0.1.0", entries: entries)
            guard case let .present(whatsNew) = launch else {
                check("a multi-version upgrade presents What's-New", false, "\(launch)")
                report(failures)
                return
            }
            check(
                "every skipped version above lastSeen is grouped, newest first",
                whatsNew.sections.map(\.version) == ["0.3.0", "0.2.0"],
                "\(whatsNew.sections.map(\.version))"
            )
            check(
                "the last-seen version itself is excluded from the sections",
                !whatsNew.sections.contains { $0.version == "0.1.0" }
            )
            check("headline is the current version", whatsNew.version == "0.3.0", whatsNew.version)
        }

        // MARK: - Version bump with no changelog entry: headline only

        do {
            let launch = WhatsNew.onLaunch(currentVersion: "0.9.9", lastSeenVersion: "0.3.0", entries: entries)
            guard case let .present(whatsNew) = launch else {
                check("a bump beyond the changelog still presents", false, "\(launch)")
                report(failures)
                return
            }
            check("no matching sections when the changelog lacks the version", whatsNew.sections.isEmpty)
            check("headline still shows the current version", whatsNew.version == "0.9.9")
        }

        // MARK: - Dismissal

        do {
            var whatsNew = WhatsNew(isPresented: true, version: "0.2.0", sections: [])
            whatsNew.dismiss()
            check("dismiss hides the surface", !whatsNew.isPresented)
        }

        report(failures)
    }

    static func report(_ failures: [String]) {
        if failures.isEmpty {
            print("What's-New tests passed")
        } else {
            fatalError("What's-New tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
