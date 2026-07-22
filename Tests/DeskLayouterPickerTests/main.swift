import DeskLayouterCore

@main
struct ApplicationCatalogTestRunner {
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

        func app(_ name: String, _ bundle: String, running: Bool = false) -> InstalledApplication {
            InstalledApplication(displayName: name, bundleIdentifier: bundle, isRunning: running)
        }

        // Merge: an installed app is marked running when its bundle identifier
        // appears in the running set, and left not-running otherwise.
        do {
            let merged = ApplicationCatalog.merge(
                installed: [
                    app("Writer", "com.example.Writer"),
                    app("Reader", "com.example.Reader"),
                ],
                running: [app("Writer", "com.example.Writer", running: true)]
            )
            check(
                "merge marks installed apps running when present in the running set",
                merged == [
                    app("Reader", "com.example.Reader", running: false),
                    app("Writer", "com.example.Writer", running: true),
                ],
                "got \(merged)"
            )
        }

        // Merge: a running app that is not among the installed locations is still
        // included and marked running in search results.
        do {
            let merged = ApplicationCatalog.merge(
                installed: [app("Reader", "com.example.Reader")],
                running: [app("Elsewhere", "com.example.Elsewhere", running: true)]
            )
            check(
                "merge includes running apps not found among installed apps",
                merged == [
                    app("Elsewhere", "com.example.Elsewhere", running: true),
                    app("Reader", "com.example.Reader", running: false),
                ],
                "got \(merged)"
            )
        }

        // Merge: the result is sorted case-insensitively by display name so the
        // picker order is stable regardless of scan order.
        do {
            let merged = ApplicationCatalog.merge(
                installed: [
                    app("banana", "com.example.banana"),
                    app("Apple", "com.example.Apple"),
                    app("cherry", "com.example.cherry"),
                ],
                running: []
            )
            check(
                "merge sorts by display name case-insensitively",
                merged.map(\.displayName) == ["Apple", "banana", "cherry"],
                "got \(merged.map(\.displayName))"
            )
        }

        // Merge: a duplicate bundle identifier keeps its first occurrence rather
        // than being listed twice.
        do {
            let merged = ApplicationCatalog.merge(
                installed: [
                    app("Writer", "com.example.Writer"),
                    app("Writer (copy)", "com.example.Writer"),
                ],
                running: []
            )
            check(
                "merge deduplicates by bundle identifier keeping the first",
                merged == [app("Writer", "com.example.Writer", running: false)],
                "got \(merged)"
            )
        }

        // Filter: an empty search returns every application unchanged.
        do {
            let apps = [
                app("Writer", "com.example.Writer"),
                app("Reader", "com.example.Reader"),
            ]
            let filtered = ApplicationCatalog.filtered(apps, searchText: "")
            check("filter with empty search returns all apps", filtered == apps, "got \(filtered)")
        }

        // Filter: search matches by name, case-insensitively.
        do {
            let apps = [
                app("Safari", "com.apple.Safari"),
                app("Mail", "com.apple.mail"),
                app("Messages", "com.apple.MobileSMS"),
            ]
            let filtered = ApplicationCatalog.filtered(apps, searchText: "M")
            check(
                "filter matches name case-insensitively",
                filtered.map(\.displayName) == ["Mail", "Messages"],
                "got \(filtered.map(\.displayName))"
            )
        }

        // Filter: leading/trailing whitespace in the search is ignored.
        do {
            let apps = [app("Safari", "com.apple.Safari"), app("Mail", "com.apple.mail")]
            let filtered = ApplicationCatalog.filtered(apps, searchText: "  safari  ")
            check(
                "filter trims surrounding whitespace from the search",
                filtered == [app("Safari", "com.apple.Safari")],
                "got \(filtered)"
            )
        }

        // Filter: running state is presentation data only. Search retains both
        // running and stopped apps so the removed Running-only behavior cannot
        // silently return in the catalog seam.
        do {
            let apps = [
                app("Safari", "com.apple.Safari", running: true),
                app("Mail", "com.apple.mail", running: false),
                app("Notes", "com.apple.Notes", running: true),
            ]
            let filtered = ApplicationCatalog.filtered(apps, searchText: "")
            check(
                "filter retains running and stopped apps with their indicators",
                filtered == apps,
                "got \(filtered)"
            )
        }

        if failures.isEmpty {
            print("Application catalog tests passed")
        } else {
            fatalError("Application catalog tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
