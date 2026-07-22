import AppKit
import DeskLayouterCore
import DeskLayouterMacOS

@MainActor
private final class CountingApplicationsProvider: InstalledApplicationsProviding {
    let catalog: [InstalledApplication]
    let icon: NSImage?
    private(set) var applicationsCallCount = 0
    private(set) var iconCallCount = 0

    init(catalog: [InstalledApplication], icon: NSImage?) {
        self.catalog = catalog
        self.icon = icon
    }

    func applications() -> [InstalledApplication] {
        applicationsCallCount += 1
        return catalog
    }

    func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        iconCallCount += 1
        return icon
    }
}

@main
struct ApplicationCatalogTestRunner {
    @MainActor
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

        // Performance regression: catalog discovery and icon resolution are
        // initial-load work. Searching a representative 240-app catalog must not
        // invoke either side-effectful provider operation per keystroke.
        do {
            let apps = (0..<240).map { index in
                app(
                    String(format: "Representative Application %03d.app", index),
                    "com.example.representative.\(index)",
                    running: index.isMultiple(of: 3)
                )
            }
            let provider = CountingApplicationsProvider(
                catalog: apps,
                icon: NSImage(size: NSSize(width: 20, height: 20))
            )
            let store = ApplicationPickerStore(provider: provider)
            store.refresh()

            let queries = ["r", "re", "rep", "representative", "application 1"]
            for query in queries {
                let matches = ApplicationCatalog.filtered(store.applications, searchText: query)
                for application in matches.prefix(6) {
                    _ = application.presentedName
                    _ = store.icon(forBundleIdentifier: application.bundleIdentifier)
                }
            }

            check(
                "search keystrokes do not rediscover the application catalog",
                provider.applicationsCallCount == 1,
                "catalog discovery ran \(provider.applicationsCallCount) times"
            )
            check(
                "search keystrokes reuse icons resolved during initial catalog load",
                provider.iconCallCount == apps.count,
                "icon resolution ran \(provider.iconCallCount) times for \(apps.count) apps"
            )
        }

        // Negative icon results are cached as well: an uninstalled app must not
        // trigger a repeated NSWorkspace lookup every time SwiftUI evaluates a row.
        do {
            let missing = app("Missing App", "com.example.missing")
            let provider = CountingApplicationsProvider(catalog: [missing], icon: nil)
            let store = ApplicationPickerStore(provider: provider)
            store.refresh()
            _ = store.icon(forBundleIdentifier: missing.bundleIdentifier)
            _ = store.icon(forBundleIdentifier: missing.bundleIdentifier)
            check(
                "missing application icons are negatively cached",
                provider.iconCallCount == 1,
                "missing icon was resolved \(provider.iconCallCount) times"
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
