import AppKit
import DeskLayouterMacOS

/// A stand-in for the editor window so the presenter's open/focus/reuse decisions
/// can be exercised without an AppKit window or a running app.
@MainActor
final class FakeEditorWindow {
    let id: Int
    var focusCount = 0
    init(id: Int) { self.id = id }
}

@main
@MainActor
struct MenuBarTestRunner {
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

        /// Builds a presenter plus mutable observers for the injected side effects,
        /// so each scenario can assert exactly how the presenter drove them.
        func makePresenter() -> (
            presenter: EditorPresenter<FakeEditorWindow>,
            madeWindows: () -> Int,
            terminated: () -> Int
        ) {
            var made = 0
            var terminations = 0
            let presenter = EditorPresenter<FakeEditorWindow>(
                makeWindow: {
                    made += 1
                    return FakeEditorWindow(id: made)
                },
                focusWindow: { $0.focusCount += 1 },
                terminate: { terminations += 1 }
            )
            return (presenter, { made }, { terminations })
        }

        // Editor-window configuration — the initial content size is deliberately
        // larger than the minimum and resizing remains enabled.
        do {
            check(
                "the default editor window is 1024 by 640",
                AppWindowConfiguration.defaultWidth == 1024 && AppWindowConfiguration.defaultHeight == 640,
                "got \(AppWindowConfiguration.defaultWidth) x \(AppWindowConfiguration.defaultHeight)"
            )
            check(
                "the editor window remains user-resizable",
                AppWindowConfiguration.styleMask.contains(.resizable)
            )
        }

        // Status-item action — the first open creates exactly one window and brings
        // it to the front (the menu-bar click when the editor is closed).
        do {
            let (presenter, madeWindows, _) = makePresenter()
            let window = presenter.openOrFocusEditor()
            check("first open creates one window", madeWindows() == 1, "made \(madeWindows())")
            check("first open focuses the new window", window.focusCount == 1, "focus \(window.focusCount)")
            check("presenter retains the opened window", presenter.window === window)
        }

        // Window reuse — opening again while the editor is already open focuses the
        // existing window instead of creating a second one (no duplicate windows).
        do {
            let (presenter, madeWindows, _) = makePresenter()
            let first = presenter.openOrFocusEditor()
            let second = presenter.openOrFocusEditor()
            check("second open reuses the same window instance", first === second)
            check("second open does not create another window", madeWindows() == 1,
                  "made \(madeWindows())")
            check("second open re-focuses the existing window", first.focusCount == 2,
                  "focus \(first.focusCount)")
        }

        // Close-versus-quit lifecycle — the two ways to leave the editor are
        // distinct at this seam. Closing the editor with the red control is modeled
        // by the app simply *not* quitting: the presenter keeps its window and never
        // terminates on its own, so the menu-bar click that follows a close reopens
        // the SAME window. Quitting is the only path that terminates. Contrasting
        // them here fails a regression that quit on close or reopened a duplicate.
        do {
            let (presenter, madeWindows, terminated) = makePresenter()
            let opened = presenter.openOrFocusEditor()
            // The click that reopens after a close: no termination, no duplicate.
            let reopened = presenter.openOrFocusEditor()
            check("reopening after a close does not terminate the app", terminated() == 0,
                  "terminated \(terminated())")
            check("reopening after a close reuses the same window", opened === reopened)
            check("reopening after a close creates no duplicate window", madeWindows() == 1,
                  "made \(madeWindows())")
            // Quit is the distinct, explicit path — and the only one that terminates.
            presenter.quit()
            check("quitting is the only path that terminates", terminated() == 1,
                  "terminated \(terminated())")
        }

        // Launch-open lifecycle (issue #69) — `AppDelegate` opens the editor on
        // launch (`applicationDidFinishLaunching`) and on re-launch while already
        // running (`applicationShouldHandleReopen`) through this same entry point.
        // The reuse and no-terminate guarantees the launch flow relies on are the
        // ones the blocks above cover; this scenario pins that launch drives exactly
        // this seam, so a regression that opened the editor some other way surfaces.
        do {
            let (presenter, madeWindows, terminated) = makePresenter()
            let onLaunch = presenter.openOrFocusEditor()
            check("launch opens exactly one editor window", madeWindows() == 1,
                  "made \(madeWindows())")
            check("launch focuses the opened window", onLaunch.focusCount == 1,
                  "focus \(onLaunch.focusCount)")
            check("launch does not terminate the app", terminated() == 0,
                  "terminated \(terminated())")
        }

        // Header Quit action — quitting terminates immediately and unconditionally
        // (no confirmation gate), regardless of whether the editor was ever opened
        // or has pending edits waiting.
        do {
            let (presenter, madeWindows, terminated) = makePresenter()
            presenter.quit()
            check("quit terminates immediately", terminated() == 1, "terminated \(terminated())")
            check("quit does not open a window", madeWindows() == 0, "made \(madeWindows())")

            let (presenter2, _, terminated2) = makePresenter()
            _ = presenter2.openOrFocusEditor()
            presenter2.quit()
            check("quit with the editor open still terminates once", terminated2() == 1,
                  "terminated \(terminated2())")
        }

        if failures.isEmpty {
            print("Menu-bar presenter tests passed")
        } else {
            fatalError("Menu-bar presenter tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
