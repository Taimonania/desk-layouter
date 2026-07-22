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

        // MARK: - Support report

        do {
            let url = SupportReport.githubIssueURL(
                appVersion: "1.2.3",
                macOSVersion: "macOS 15.5 (24F74)"
            )
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = Dictionary(
                uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )
            check(
                "Report a Problem opens the repository's new-issue path",
                components?.scheme == "https"
                    && components?.host == "github.com"
                    && components?.path == "/Taimonania/desk-layouter/issues/new",
                "got \(url.absoluteString)"
            )
            check(
                "the support issue is prefilled with version and behavior prompts",
                query["body"]?.contains("Desk Layouter version\n1.2.3") == true
                    && query["body"]?.contains("macOS version\nmacOS 15.5 (24F74)") == true
                    && query["body"]?.contains("Expected behavior") == true
                    && query["body"]?.contains("Actual behavior") == true,
                "got \(query["body"] ?? "<missing body>")"
            )
        }

        // MARK: - Shared editor status

        do {
            let status = EditorStatusPresentation.resolve(
                feedback: .success("Applied 2 Assignments."),
                pendingChangeCount: 3,
                applyBlockedExplanation: "Apply is disabled.",
                desktopCount: 0
            )
            check(
                "latest action feedback takes priority in the shared status area",
                status.message == "Applied 2 Assignments."
            )
        }

        do {
            let status = EditorStatusPresentation.resolve(
                feedback: .none,
                pendingChangeCount: 2,
                applyBlockedExplanation: nil,
                desktopCount: 3
            )
            check(
                "pending Assignment changes fill an otherwise idle status area",
                status.message == "2 unapplied changes."
            )
        }

        do {
            let blocked = EditorStatusPresentation.resolve(
                feedback: .none,
                pendingChangeCount: 1,
                applyBlockedExplanation: "Move apps off unavailable Desktop 4.",
                desktopCount: 3
            )
            check(
                "a disabled Apply explanation takes priority over a pending count",
                blocked.message == "Move apps off unavailable Desktop 4."
            )

            let noDesktops = EditorStatusPresentation.resolve(
                feedback: .none,
                pendingChangeCount: 1,
                applyBlockedExplanation: nil,
                desktopCount: 0
            )
            check(
                "status explains disabled Apply when no Desktops are available",
                noDesktops.message == "Apply is disabled because no Desktops are available on the active Display."
            )

            let clean = EditorStatusPresentation.resolve(
                feedback: .none,
                pendingChangeCount: 0,
                applyBlockedExplanation: nil,
                desktopCount: 3
            )
            check(
                "status explains disabled Apply for a clean board",
                clean.message == "No changes to apply."
            )
        }

        // MARK: - Editor chrome layout

        do {
            check(
                "footer keeps Apply and Arrange together on the left and update plus version on the right",
                EditorChromeLayout.footerRegions == [
                    .actions([.apply, .arrange]),
                    .flexibleSpace,
                    .version([.checkForUpdates, .version]),
                ]
            )
            check(
                "footer action buttons use the required 6 point gap",
                EditorChromeLayout.footerActionSpacing == 6,
                "got \(EditorChromeLayout.footerActionSpacing)"
            )
            check(
                "the reserved footer label is the widest possible Apply count",
                EditorChromeLayout.footerWidestActionLabel == "Apply (99)",
                "got \(EditorChromeLayout.footerWidestActionLabel)"
            )
            let widths = EditorChromeLayout.footerActionWidths(buttonWidth: 84)
            check(
                "Apply and Arrange both reserve the measured widest-label width",
                widths == [84, 84],
                "got \(widths)"
            )
            let clamped = EditorChromeLayout.footerActionWidths(buttonWidth: -5)
            check(
                "a not-yet-measured (negative) width clamps to zero for both buttons",
                clamped == [0, 0],
                "got \(clamped)"
            )
        }

        do {
            let metrics = EditorChromeLayout.PresetControl.allCases.map {
                EditorChromeLayout.presetMetrics(for: $0)
            }
            check(
                "every Preset-row control has one uniform rendered height",
                Set(metrics.map(\.height)).count == 1,
                "got \(metrics.map(\.height))"
            )

            let management = EditorChromeLayout.presetMetrics(for: .management)
            check(
                "Preset management stays compact and hides its menu indicator",
                management.width == EditorChromeLayout.presetManagementWidth
                    && management.width < EditorChromeLayout.minimumTextButtonWidth
                    && management.hidesMenuIndicator
            )
        }

        do {
            let windowWidth: CGFloat = 760
            let tooltipWidth: CGFloat = 160
            let padding = EditorChromeLayout.tooltipWindowPadding

            let leftCenter = EditorChromeLayout.tooltipCenterX(
                controlCenterX: 10,
                tooltipWidth: tooltipWidth,
                windowWidth: windowWidth
            )
            check(
                "a tooltip at the left edge shifts inward without changing width",
                leftCenter - tooltipWidth / 2 == padding,
                "got center \(leftCenter)"
            )

            let rightCenter = EditorChromeLayout.tooltipCenterX(
                controlCenterX: 750,
                tooltipWidth: tooltipWidth,
                windowWidth: windowWidth
            )
            check(
                "a tooltip at the right edge shifts inward without changing width",
                rightCenter + tooltipWidth / 2 == windowWidth - padding,
                "got center \(rightCenter)"
            )

            check(
                "an interior tooltip remains centered over its control",
                EditorChromeLayout.tooltipCenterX(
                    controlCenterX: 380,
                    tooltipWidth: tooltipWidth,
                    windowWidth: windowWidth
                ) == 380
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
