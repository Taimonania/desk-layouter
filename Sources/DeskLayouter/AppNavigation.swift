/// The full-window surfaces the editor window can show. The app has no
/// `NavigationStack`/`NavigationSplitView`; navigation is a simple in-window
/// content swap between the board and a full-window surface (issue #71). This
/// mechanism is reused later (e.g. the What's-New surface).
///
/// (Named "surface" rather than "screen" deliberately — CONTEXT.md reserves
/// "Screen" as an avoided synonym for Display/Desktop.)
public enum AppSurface: Equatable {
    /// The Desktops board — the app's primary canvas and default surface.
    case board
    /// The full-window Settings surface.
    case settings
    /// The full-window What's-New surface shown after an upgrade (issue #73).
    case whatsNew
}

/// The window's current surface plus the transitions between surfaces. Kept as a
/// pure value type so the navigation logic is tested at its seam without a running
/// app or SwiftUI; the executable wraps it in an `ObservableObject` to drive the
/// SwiftUI content swap.
public struct AppNavigation: Equatable {
    /// The surface currently shown. Starts on the board.
    public private(set) var surface: AppSurface

    public init(surface: AppSurface = .board) {
        self.surface = surface
    }

    /// Swaps the window content to the full-window Settings surface.
    public mutating func showSettings() {
        surface = .settings
    }

    /// Swaps the window content to the full-window What's-New surface (issue #73),
    /// shown on the first launch after an upgrade.
    public mutating func showWhatsNew() {
        surface = .whatsNew
    }

    /// Returns to the board (the "Done" control on a full-window surface).
    public mutating func showBoard() {
        surface = .board
    }
}
