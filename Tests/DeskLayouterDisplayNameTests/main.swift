import DeskLayouterCore

// Verifies the single user-facing application-naming rule (issue #39): a trailing
// ".app" is stripped case-insensitively, only when it is genuinely the trailing
// suffix, and every other name is left exactly as it was. The value types that
// carry a raw `displayName` expose a `presentedName` that routes through the same
// rule, and the Arrange feedback presenter cleans the names it renders — all
// covered here so the rule is proven once and reused everywhere.
// Hand-rolled @main runner, no XCTest — matching the other test targets.

@main
struct DisplayNameTestRunner {
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

        func expect(_ raw: String, _ expected: String, _ label: String) {
            let got = ApplicationDisplayName.presented(raw)
            check(label, got == expected, "presented(\(raw)) == \(got), expected \(expected)")
        }

        // MARK: - Ordinary names are untouched.

        expect("Spotify", "Spotify", "a name without a suffix is unchanged")
        expect("Visual Studio Code", "Visual Studio Code", "a multi-word name is unchanged")
        expect("", "", "an empty name is unchanged")

        // MARK: - A trailing .app is stripped, case-insensitively.

        expect("Spotify.app", "Spotify", "a lowercase .app suffix is stripped")
        expect("Spotify.App", "Spotify", "a mixed-case .App suffix is stripped")
        expect("Spotify.APP", "Spotify", "an uppercase .APP suffix is stripped")

        // MARK: - Only the trailing occurrence is removed.

        expect("Notes.app.app", "Notes.app", "only the final .app is stripped")
        expect(".app", "", "a bare .app becomes empty")

        // MARK: - Non-suffix occurrences of .app remain.

        expect("MyApp", "MyApp", "a name ending in App (no dot) is unchanged")
        expect("app.example", "app.example", "a leading app. is unchanged")
        expect("Foo.appliance", "Foo.appliance", ".app inside a longer word is unchanged")
        expect("Cool.app Suite", "Cool.app Suite", "a middle .app followed by more text is unchanged")

        // MARK: - Value types expose the cleaned name while preserving raw fields.

        do {
            let installed = InstalledApplication(
                displayName: "Slack.app",
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                isRunning: true
            )
            check("InstalledApplication.presentedName strips the suffix", installed.presentedName == "Slack")
            check("InstalledApplication.displayName stays raw", installed.displayName == "Slack.app")
            check("InstalledApplication.bundleIdentifier is untouched", installed.bundleIdentifier == "com.tinyspeck.slackmacgap")
        }

        do {
            // A legacy stored Assignment whose display name still ends in ".app"
            // must render cleanly without any manual recreation.
            let managed = ManagedApplication.legacy(
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari.app",
                desktopNumber: 2
            )
            check("ManagedApplication.presentedName strips a legacy suffix", managed.presentedName == "Safari")
            check("ManagedApplication.displayName stays raw for persistence", managed.displayName == "Safari.app")
        }

        do {
            let card = BoardCard(
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari.app",
                desktopNumber: 2
            )
            check("BoardCard.presentedName strips the suffix", card.presentedName == "Safari")
            check("BoardCard.displayName stays raw", card.displayName == "Safari.app")
        }

        // MARK: - Arrange feedback renders cleaned names.

        do {
            let a = ArrangeReportPresenter.announce(
                activeDesktop: 1,
                arranged: ["Spotify.app", "Notes.APP"],
                skipped: [],
                resisted: [],
                pendingDesktops: []
            )
            check(
                "Arrange feedback strips .app from every named app",
                a.message == "Arranged Notes and Spotify on Desktop 1.",
                "got \(a.message)"
            )
        }

        if failures.isEmpty {
            print("All DisplayName tests passed.")
        } else {
            print("\n\(failures.count) DisplayName test(s) failed.")
            exit(1)
        }
    }
}

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
