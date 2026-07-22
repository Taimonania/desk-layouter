import DeskLayouterMacOS
import SwiftUI

/// The window's content root. It swaps between the board (`EditorView`) and the
/// full-window surfaces — `SettingsView` (issue #71) and the What's-New
/// `WhatsNewView` (issue #73) — based on the navigation state, so a full-window
/// surface replaces the board in place rather than opening a sheet or a second
/// window. `AppDelegate` hosts this view in the editor window.
struct AppRootView: View {
    @ObservedObject var model: AppRootModel
    let editorModel: EditorModel

    /// Quits Desk Layouter — threaded through to the board's header, matching the
    /// existing lifecycle seam.
    let quit: () -> Void

    /// Triggers Sparkle's "Check for Updates" flow — threaded through to the board.
    let checkForUpdates: () -> Void

    var body: some View {
        surface
            // The Welcome tour floats over the board as a live spotlight overlay
            // (issue #72). It reads the anchors the board's controls publish so it
            // can dim around them; the overlay is shown only over the board, the
            // only surface those controls (and the Help button) live on.
            .overlayPreferenceValue(WelcomeAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if model.welcomeTour.isPresented, model.navigation.surface == .board {
                        let frames = model.welcomeTour.currentStep.spotlightTargets
                            .compactMap { anchors[$0] }
                            .map { proxy[$0] }
                        WelcomeTourOverlay(
                            tour: model.welcomeTour,
                            spotlightFrames: frames,
                            onNext: { model.welcomeNext() },
                            onBack: { model.welcomeBack() },
                            onSkip: { model.dismissWelcome() },
                            onFinish: { model.dismissWelcome() }
                        )
                    }
                }
            }
            .hoverTooltipContainer()
    }

    @ViewBuilder
    private var surface: some View {
        switch model.navigation.surface {
        case .board:
            EditorView(
                model: editorModel,
                quit: quit,
                checkForUpdates: checkForUpdates,
                openSettings: { model.showSettings() },
                openHelp: { model.openWelcome() }
            )
        case .settings:
            SettingsView(model: model)
        case .whatsNew:
            WhatsNewView(model: model)
        }
    }
}
