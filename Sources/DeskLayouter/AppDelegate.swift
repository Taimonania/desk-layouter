import AppKit
import CoreGraphics
import DeskLayouterCore
import DeskLayouterMacOS
import Sparkle
import SwiftUI

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let editorModel = EditorModel()

    // Sparkle's standard controller owns the whole update flow (scheduling, UI,
    // signature checks). It reads SUFeedURL/SUPublicEDKey from Info.plist and
    // starts checking on its own once created; `checkForUpdates:` is the manual
    // entry point wired to the menu item below.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Owns the editor window's open/focus/reuse lifecycle (issue #40). The window
    /// factory, focus behavior, and terminate are wired to AppKit here; the
    /// decision logic itself is tested at the `EditorPresenter` seam.
    private lazy var presenter = EditorPresenter<NSWindow>(
        makeWindow: { [unowned self] in makeEditorWindow() },
        focusWindow: { window in
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        },
        terminate: { NSApplication.shared.terminate(nil) }
    )

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep direct `swift run` launches out of the Dock too. The bundled app
        // also declares LSUIElement in Info.plist, so the app stays a menu-bar
        // (accessory) presence with no Dock icon even though it opens a window.
        NSApplication.shared.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.3.group",
                accessibilityDescription: "Desk Layouter"
            )
            button.image?.isTemplate = true
            button.toolTip = "Desk Layouter"
            // The menu-bar icon keeps the editor as its primary entry point (issue
            // #40): a left-click opens it, or focuses the existing window when it is
            // already open. A right-click instead pops a small menu for app-level
            // commands like "Check for Updates…" (issue #45), so both mouse-up
            // events are routed through `statusItemClicked`.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = statusItem

        startObservingDisplayReconfiguration()

        // Launch opens the editor window automatically (issue #69). It is the same
        // entry point as a menu-bar click, so the window the presenter retains is
        // reused for the rest of the app's lifetime — no duplicate is ever created.
        presenter.openOrFocusEditor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A re-launch of the (still-running) app, or any Dock/relaunch reopen request,
    /// opens the editor if it was closed or focuses the existing window otherwise
    /// (issue #69). Routing through the presenter reuses the retained window instead
    /// of spawning a duplicate.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        presenter.openOrFocusEditor()
        return true
    }

    /// Registers for display topology changes (connect/disconnect, lid open or
    /// close, main-display or mirroring change) so the board re-reads the active
    /// Display's Desktops whenever the topology changes while the editor is open.
    /// The saved board is never touched here, so pending edits are preserved
    /// across the change (issue #18, AC 7).
    private func startObservingDisplayReconfiguration() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            // The pre-change callback fires before CoreGraphics state is current;
            // act only on the post-change callback.
            guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
            Task { @MainActor in
                delegate.editorModel.refreshDesktops()
            }
        }, context)
    }

    @objc
    private func statusItemClicked() {
        // Left-click keeps the primary flow (open/focus the editor); right-click
        // pops the menu that hosts app-level commands like "Check for Updates…".
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            presenter.openOrFocusEditor()
        }
    }

    private func showStatusMenu() {
        guard let statusItem else { return }

        let menu = NSMenu()
        // Sparkle enables/disables this item via `validateMenuItem:`; the action
        // must be `checkForUpdates:` targeting the standard updater controller.
        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        menu.addItem(checkForUpdates)

        // Attaching the menu makes the status item present it for this click, then
        // we clear it so the next left-click routes through `statusItemClicked`.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeEditorWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Desk Layouter"
        window.center()
        // Closing the editor with the red control must leave Desk Layouter running
        // and keep the window instance alive so the presenter can reuse it on the
        // next menu-bar click without spawning a duplicate (issue #40).
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: EditorView(model: editorModel, quit: { [weak self] in self?.presenter.quit() })
        )
        window.setContentSize(NSSize(width: 720, height: 480))
        return window
    }
}
