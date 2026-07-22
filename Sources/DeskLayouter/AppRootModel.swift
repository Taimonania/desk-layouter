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

    private let appState: AppStateStore

    init(appState: AppStateStore) {
        self.appState = appState
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
}
