import DeskLayouterCore
import DeskLayouterMacOS
import SwiftUI

/// The observable app-level hub for the window's root: which full-window surface
/// is shown (board vs. Settings) and the app-level preferences the Settings
/// surface edits. It wraps the pure `AppNavigation` seam and the `AppStateStore` so the
/// SwiftUI root can observe changes, while the navigation transitions and the
/// persistence themselves stay tested at their own seams (issue #71).
@MainActor
final class AppRootModel: ObservableObject {
    /// The current full-window surface. Mutating the value republishes because it
    /// is `@Published`, so the root view swaps content in response.
    @Published private(set) var navigation = AppNavigation()

    /// The Welcome guided tour's step and presentation state (issue #72). Seeded at
    /// init from the persisted `hasSeenWelcome` flag, so a fresh install shows the
    /// tour automatically over the board; the pure `WelcomeTour` seam owns the
    /// step/navigation logic while this model persists dismissal.
    @Published private(set) var welcomeTour: WelcomeTour

    /// The What's-New surface's content, present only when the app was launched on
    /// a newer version than last seen (issue #73). `nil` on a fresh install, a
    /// dev/unbundled build, or an equal/lower version — the pure `WhatsNew.onLaunch`
    /// seam decides, and this model persists `lastSeenVersion` in response.
    @Published private(set) var whatsNew: WhatsNew?

    private let appState: AppStateStore

    /// - Parameters:
    ///   - currentVersion: the running build's raw version (defaults to the real
    ///     bundle version; `nil` for the unbundled `swift run` build).
    ///   - changelogText: the bundled `CHANGELOG.md` text (defaults to the real
    ///     bundled resource; `nil` when unbundled).
    init(
        appState: AppStateStore,
        currentVersion: String? = AppVersion.currentSemanticVersion(),
        changelogText: String? = BundledChangelog.text()
    ) {
        self.appState = appState
        self.welcomeTour = WelcomeTour.onLaunch(hasSeenWelcome: appState.hasSeenWelcome)

        // Decide What's-New once, at launch, from the pure seam. Fresh installs
        // record a baseline (so a later upgrade announces itself) but show nothing,
        // leaving first-run to the Welcome tour; an upgrade opens the surface.
        let entries = changelogText.map(Changelog.parse) ?? []
        switch WhatsNew.onLaunch(
            currentVersion: currentVersion,
            lastSeenVersion: appState.lastSeenVersion,
            entries: entries
        ) {
        case .none:
            break
        case let .recordBaseline(version):
            appState.lastSeenVersion = version
        case let .present(whatsNew):
            self.whatsNew = whatsNew
            self.navigation = AppNavigation(surface: .whatsNew)
        }
    }

    /// Whether Sparkle installs updates automatically (`true`) or asks first
    /// (`false`). Read/written through to the persisted `AppStateStore`; the value
    /// is applied to Sparkle on the next launch. Automatic checking is unaffected
    /// and stays always-on.
    var automaticallyInstallUpdates: Bool {
        get { appState.automaticallyInstallUpdates }
        set {
            objectWillChange.send()
            appState.automaticallyInstallUpdates = newValue
        }
    }

    /// Swaps the window to the full-window Settings surface.
    func showSettings() {
        navigation.showSettings()
    }

    /// Returns to the board (the Settings surface's "Done" control).
    func showBoard() {
        navigation.showBoard()
    }

    /// Re-opens the Welcome tour from its first step (the header's Help `?`
    /// button). Available at any time regardless of `hasSeenWelcome`.
    func openWelcome() {
        welcomeTour.open()
    }

    /// Advances the tour to the next step.
    func welcomeNext() {
        welcomeTour.next()
    }

    /// Returns the tour to the previous step.
    func welcomeBack() {
        welcomeTour.back()
    }

    /// Dismisses the tour (Skip or Done) and records that the user has seen it, so
    /// it does not reappear automatically on later launches.
    func dismissWelcome() {
        welcomeTour.dismiss()
        appState.hasSeenWelcome = true
    }

    /// Dismisses the What's-New surface (its "Done" control): returns to the board
    /// and records the running version as `lastSeenVersion`, so the surface shows
    /// once per upgrade and not on the next launch of the same version (issue #73).
    func dismissWhatsNew() {
        guard let version = whatsNew?.version else { return }
        whatsNew?.dismiss()
        appState.lastSeenVersion = version
        navigation.showBoard()
    }
}
