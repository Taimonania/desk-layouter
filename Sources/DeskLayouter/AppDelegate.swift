import AppKit
import CoreGraphics
import DeskLayouterCore
import DeskLayouterMacOS
import SwiftUI

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var editorWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let editorModel = EditorModel()

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep direct `swift run` launches out of the Dock too. The bundled app
        // also declares LSUIElement in Info.plist.
        NSApplication.shared.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.3.group",
                accessibilityDescription: "Desk Layouter"
            )
            button.image?.isTemplate = true
            button.toolTip = "Desk Layouter"
        }
        statusItem.menu = makeStatusMenu()
        self.statusItem = statusItem

        startObservingDisplayReconfiguration()
    }

    /// Builds the status-bar menu: open the editor (which now hosts the Arrange
    /// button, issue #27) and quit.
    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(
            title: "Open Desk Layouter",
            action: #selector(openEditorWindow),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
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
    private func openEditorWindow() {
        let window = editorWindow ?? makeEditorWindow()
        editorWindow = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorView(model: editorModel))
        window.setContentSize(NSSize(width: 720, height: 480))
        return window
    }
}
