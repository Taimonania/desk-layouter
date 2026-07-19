import AppKit
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
            button.target = self
            button.action = #selector(openEditorWindow)
            button.toolTip = "Desk Layouter"
        }
        self.statusItem = statusItem
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
