import AppKit
import CoreGraphics
import DeskLayouterCore
import DeskLayouterMacOS
import SwiftUI

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let editorModel = EditorModel()

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
        // also declares LSUIElement in Info.plist. Nothing opens the editor here,
        // so launch stays a quiet menu-bar presence (issue #40).
        NSApplication.shared.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.3.group",
                accessibilityDescription: "Desk Layouter"
            )
            button.image?.isTemplate = true
            button.toolTip = "Desk Layouter"
            // The menu-bar icon is a direct entry point to the editor rather than a
            // menu (issue #40): a left- or right-click opens it, or focuses the
            // existing window when it is already open. Handling both mouse-up events
            // gives right-click the same open-or-focus behavior.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = statusItem

        startObservingDisplayReconfiguration()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        presenter.openOrFocusEditor()
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
