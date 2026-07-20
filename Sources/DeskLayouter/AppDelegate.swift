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
    private let windowArranger = WindowArranger()

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

    /// Builds the status-bar menu. The "Arrange Active Desktop" item is a
    /// TEMPORARY internal trigger (issue #25) so runtime Arrange is demoable
    /// before the real Arrange button (#27) exists — #27 replaces this item with
    /// the in-editor button and surfaces the returned ``ArrangeReport``.
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
        let arrange = NSMenuItem(
            title: "Arrange Active Desktop (Debug)",
            action: #selector(arrangeActiveDesktop),
            keyEquivalent: ""
        )
        arrange.target = self
        menu.addItem(arrange)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// TEMPORARY debug trigger for runtime Arrange (issue #25). Loads the saved
    /// configuration and arranges every managed app with a Layout on the active
    /// Desktop, then reports the outcome in an alert. Replaced by #27's Arrange
    /// button, which will call ``WindowArranger/arrange(managedApplications:)``
    /// the same way and surface the ``ArrangeReport``.
    @objc
    private func arrangeActiveDesktop() {
        let applications = (try? ConfigurationStore.default.load())?.managedApplications ?? []
        do {
            let report = try windowArranger.arrange(managedApplications: applications)
            presentArrangeReport(report)
        } catch WindowArrangeError.accessibilityNotGranted {
            presentInfo(
                title: "Accessibility permission needed",
                message: "Grant Desk Layouter Accessibility access in System Settings > "
                    + "Privacy & Security > Accessibility, then try again. Nothing was moved."
            )
        } catch {
            presentInfo(title: "Arrange failed", message: "\(error)")
        }
    }

    private func presentArrangeReport(_ report: ArrangeReport) {
        var lines: [String] = []
        lines.append("Arranged: \(report.arranged.count)")
        lines.append("Skipped (no eligible window): \(report.skipped.count)")
        lines.append("Resisted: \(report.resisted.count)")
        if report.hasResistance {
            lines.append("")
            lines.append("Windows that resisted (fixed-size / fullscreen / sheet):")
            for window in report.resisted {
                lines.append("  • \(window.displayName)")
            }
        }
        presentInfo(title: "Arrange complete", message: lines.joined(separator: "\n"))
    }

    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
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
