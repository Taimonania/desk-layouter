/// Owns the editor window's lifecycle from the menu bar: open it when it is
/// closed, focus the existing one when it is already open, and quit on request.
///
/// The window type and the three side effects (create, focus, terminate) are
/// injected so the open/focus/reuse decisions — the parts issue #40 cares about —
/// can be tested without an AppKit window or a running application. `AppDelegate`
/// supplies the real `NSWindow` factory and wires focus to activating the app and
/// ordering the window front, and terminate to `NSApplication.terminate`.
///
/// The presenter deliberately retains its window for the whole app lifetime and
/// never nils it on close. Closing the editor with the red window control leaves
/// Desk Layouter running (the app keeps a lightweight menu-bar presence), so the
/// next menu-bar click reuses the same window instead of creating a duplicate.
@MainActor
public final class EditorPresenter<Window: AnyObject> {
    private let makeWindow: () -> Window
    private let focusWindow: (Window) -> Void
    private let terminate: () -> Void

    /// The retained editor window, once opened. Reused for the app's lifetime,
    /// so window reuse is observable through this identity.
    public private(set) var window: Window?

    public init(
        makeWindow: @escaping () -> Window,
        focusWindow: @escaping (Window) -> Void,
        terminate: @escaping () -> Void
    ) {
        self.makeWindow = makeWindow
        self.focusWindow = focusWindow
        self.terminate = terminate
    }

    /// The menu-bar click action: open the editor when it is closed, or focus and
    /// raise the existing one when it is already open. Never creates a second
    /// window. Returns the live window either way.
    @discardableResult
    public func openOrFocusEditor() -> Window {
        if let window {
            focusWindow(window)
            return window
        }
        let created = makeWindow()
        window = created
        focusWindow(created)
        return created
    }

    /// Quits Desk Layouter immediately and unconditionally — no confirmation, even
    /// when Assignments are waiting to be applied. Pending edits are already stored
    /// as they are made, so nothing is lost by terminating here.
    public func quit() {
        terminate()
    }
}
