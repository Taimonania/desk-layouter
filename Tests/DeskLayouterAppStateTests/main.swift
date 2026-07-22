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

        // MARK: - AppStateStore: hasSeenWelcome

        do {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = AppStateStore(defaults: defaults)
            check(
                "hasSeenWelcome defaults to false on a fresh install",
                store.hasSeenWelcome == false,
                "got \(store.hasSeenWelcome)"
            )
        }

        do {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            AppStateStore(defaults: defaults).hasSeenWelcome = true
            // A separate store over the same defaults sees the persisted flag — the
            // tour stays dismissed across launches once it has been seen.
            let reloaded = AppStateStore(defaults: defaults)
            check(
                "hasSeenWelcome persists across store instances",
                reloaded.hasSeenWelcome == true
            )
        }

        // MARK: - AppStateStore: lastSeenVersion

        do {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = AppStateStore(defaults: defaults)
            check(
                "lastSeenVersion is nil on a fresh install",
                store.lastSeenVersion == nil,
                "got \(String(describing: store.lastSeenVersion))"
            )
        }

        do {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            AppStateStore(defaults: defaults).lastSeenVersion = "0.1.2"
            // A separate store over the same defaults sees the persisted version,
            // so the What's-New screen shows once per upgrade, not every launch.
            let reloaded = AppStateStore(defaults: defaults)
            check(
                "lastSeenVersion persists across store instances",
                reloaded.lastSeenVersion == "0.1.2",
                "got \(String(describing: reloaded.lastSeenVersion))"
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

        do {
            var navigation = AppNavigation()
            navigation.showWhatsNew()
            check(
                "showWhatsNew swaps to the What's-New surface",
                navigation.surface == .whatsNew,
                "got \(navigation.surface)"
            )
            navigation.showBoard()
            check(
                "showBoard (Done) returns to the board from What's-New",
                navigation.surface == .board,
                "got \(navigation.surface)"
            )
        }

        if failures.isEmpty {
            print("App state tests passed")
        } else {
            fatalError("App state tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
