/// The full-window screens the editor window can show. The app has no
/// `NavigationStack`/`NavigationSplitView`; navigation is a simple in-window
/// content swap between the board and a full-window screen (issue #71). This
/// mechanism is reused later (e.g. the What's-New screen).
public enum AppScreen: Equatable {
    /// The Desktops board — the app's primary canvas and default screen.
    case board
    /// The full-window Settings screen.
    case settings
}

/// The window's current screen plus the transitions between screens. Kept as a
/// pure value type so the navigation logic is tested at its seam without a running
/// app or SwiftUI; the executable wraps it in an `ObservableObject` to drive the
/// SwiftUI content swap.
public struct AppNavigation: Equatable {
    /// The screen currently shown. Starts on the board.
    public private(set) var screen: AppScreen

    public init(screen: AppScreen = .board) {
        self.screen = screen
    }

    /// Swaps the window content to the full-window Settings screen.
    public mutating func showSettings() {
        screen = .settings
    }

    /// Returns to the board (the "Done" control on a full-window screen).
    public mutating func showBoard() {
        screen = .board
    }
}
