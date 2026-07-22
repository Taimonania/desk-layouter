import SwiftUI

/// The minimum size shared by every full-window surface hosted in the editor
/// window (the board and the Settings surface), kept in one place so the two
/// cannot drift apart.
enum AppWindowMetrics {
    static let minWidth: CGFloat = 760
    static let minHeight: CGFloat = 640
}

/// The window's content root. It swaps between the board (`EditorView`) and the
/// full-window `SettingsView` based on the navigation state, so a full-window
/// surface replaces the board in place rather than opening a sheet or a second
/// window (issue #71). `AppDelegate` hosts this view in the editor window.
struct AppRootView: View {
    @ObservedObject var model: AppRootModel
    let editorModel: EditorModel

    /// Quits Desk Layouter — threaded through to the board's header, matching the
    /// existing lifecycle seam.
    let quit: () -> Void

    /// Triggers Sparkle's "Check for Updates" flow — threaded through to the board.
    let checkForUpdates: () -> Void

    var body: some View {
        switch model.navigation.surface {
        case .board:
            EditorView(
                model: editorModel,
                quit: quit,
                checkForUpdates: checkForUpdates,
                openSettings: { model.showSettings() }
            )
        case .settings:
            SettingsView(model: model)
        }
    }
}
