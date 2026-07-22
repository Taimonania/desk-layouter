import DeskLayouterMacOS
import Foundation

@main
struct AppStateTestRunner {
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

        /// A fresh, isolated `UserDefaults` suite so tests never touch the shared
        /// standard defaults and never leak state into one another.
        func makeDefaults() -> (UserDefaults, String) {
            let suiteName = "DeskLayouterAppStateTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            return (defaults, suiteName)
        }

        // MARK: - AppStateStore

        do {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = AppStateStore(defaults: defaults)
            check(
                "automatic install defaults to Ask (false) with no stored value",
                store.automaticallyInstallUpdates == false,
                "got \(store.automaticallyInstallUpdates)"
            )
        }

        do {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = AppStateStore(defaults: defaults)
            store.automaticallyInstallUpdates = true
            check(
                "setting automatic install to true reads back true",
                store.automaticallyInstallUpdates == true
            )
            store.automaticallyInstallUpdates = false
            check(
                "toggling back to Ask reads back false",
                store.automaticallyInstallUpdates == false
            )
        }

        do {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            AppStateStore(defaults: defaults).automaticallyInstallUpdates = true
            // A separate store over the same defaults sees the persisted choice —
            // the value survives across store instances (i.e. across launches).
            let reloaded = AppStateStore(defaults: defaults)
            check(
                "the choice persists across store instances",
                reloaded.automaticallyInstallUpdates == true
            )
        }

        // MARK: - AppNavigation

        do {
            let navigation = AppNavigation()
            check(
                "navigation starts on the board",
                navigation.surface == .board,
                "got \(navigation.surface)"
            )
        }

        do {
            var navigation = AppNavigation()
            navigation.showSettings()
            check(
                "showSettings swaps to the Settings surface",
                navigation.surface == .settings,
                "got \(navigation.surface)"
            )
            navigation.showBoard()
            check(
                "showBoard (Done) returns to the board",
                navigation.surface == .board,
                "got \(navigation.surface)"
            )
        }

        do {
            var navigation = AppNavigation(surface: .settings)
            navigation.showSettings()
            check(
                "showSettings is idempotent when already on Settings",
                navigation.surface == .settings
            )
        }

        if failures.isEmpty {
            print("App state tests passed")
        } else {
            fatalError("App state tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
