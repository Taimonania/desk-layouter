import AppKit
import Combine
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

    // Keeps the badge subscription alive for the app's lifetime (issue #128).
    private var cancellables = Set<AnyCancellable>()

    // App-level preferences that live outside the board/preset domain model —
    // currently just the automatic-update-install choice (issue #71), persisted in
    // UserDefaults and applied to Sparkle at launch.
    private let appState = AppStateStore()

    // Owns the window's full-window screen state (board vs. Settings) and exposes
    // the app-level preferences the Settings screen edits.
    private lazy var rootModel = AppRootModel(appState: appState)

    // The Sparkle user-driver delegate for the gentle-reminder path (issue #127): a
    // translation shim that declares gentle-reminder support (silencing Sparkle's
    // launch warning), suppresses Sparkle's scheduled-update window, and forwards
    // found-update and dismissal events into the `AppRootModel`'s pure seam. It is
    // an initializer parameter of the updater controller and so must exist before
    // it, which is why the controller below is lazy.
    private lazy var userDriverDelegate = UpdateReminderUserDriverDelegate(
        onFoundUpdate: { [weak self] handledBySparkle, versionName in
            self?.rootModel.recordFoundUpdate(handledBySparkle: handledBySparkle, versionName: versionName)
        },
        onDismiss: { [weak self] in
            self?.rootModel.dismissUpdateReminder()
        }
    )

    // Sparkle's standard controller owns the whole update flow (scheduling, UI,
    // signature checks). It reads SUFeedURL/SUPublicEDKey (and the
    // SUScheduledCheckInterval) from Info.plist and starts checking on its own once
    // created; `checkForUpdates:` is the manual entry point wired to the menu item
    // below. Lazily initialized so `userDriverDelegate` exists first; its first use
    // stays in `applicationDidFinishLaunching`, so the updater starts at launch as
    // before.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: userDriverDelegate
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
        // Acceptance-Review render mode (issue #119): launched with `--render-scene`,
        // the app renders the selected Scene(s) offscreen to PNG and exits here,
        // before any menu-bar item, window, or Sparkle updater is installed. Without
        // the flag this returns false and the app boots exactly as today.
        if SceneRender.runIfRequested() { return }

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

        // Automatic update *checking* stays always-on; whether an available update
        // *installs* on its own follows the user's persisted choice (issue #71),
        // which defaults to Ask. Syncing here — at launch — is why the choice takes
        // effect on the next restart.
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = appState.automaticallyInstallUpdates

        // Check once on every launch so quitting and reopening is a reliable way to
        // discover a pending update, rather than depending on where the four-hour
        // scheduler happens to sit (issue #129). `checkForUpdatesInBackground()` is
        // Sparkle's supported entry point for forcing a launch check: it routes
        // through the gentle-reminder path (so a discovery yields the toast, not a
        // modal) and does not resurface versions the user has skipped — unlike the
        // manual `checkForUpdates(nil)`, which correctly does resurface them. It must
        // be called here, immediately after the automatic-check settings are applied;
        // Sparkle's docs warn that calling it later can interfere with the scheduler.
        // Gated on automatic checking being enabled so a user who has turned checks
        // off is not force-checked on launch; today that is always true, but the guard
        // keeps the launch check honouring the setting if it ever becomes toggleable.
        // A failed check stays silent — the background path surfaces no error.
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.statusItemImage(badged: false)
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

        // Drive the menu-bar badge from the same pending-update state the toast reads
        // (issue #128), so the two surfaces can never disagree. Badge visibility is a
        // property of that state alone — independent of the window's surface or of
        // whether the window is open at all — so the icon carries the badge for as
        // long as an update is pending and clears it on dismissal, attention, or
        // session end. `@Published` delivers the current value on subscription, so
        // the icon starts in the right state too.
        rootModel.$updateReminder
            .map(\.isBadgeVisible)
            .removeDuplicates()
            .sink { [weak self] badged in
                self?.statusItem?.button?.image = Self.statusItemImage(badged: badged)
            }
            .store(in: &cancellables)

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

    /// The status-item image: the app's `rectangle.3.group` symbol, with a small
    /// filled dot composed into the top-right corner while an update is pending
    /// (issue #128). Both the plain and badged images are returned as *template*
    /// images so AppKit tints them to the current menu bar, which keeps the dot
    /// monochrome and adapting to light and dark rather than a fixed colour.
    ///
    /// This AppKit image composition is deliberately not unit tested — the status
    /// item is not a SwiftUI scene, so `--render-scene` cannot reach it, and the
    /// badge's legibility in a real menu bar needs manual verification. The *decision*
    /// of when to badge lives in the pure `UpdateReminder` seam and is tested there.
    private static func statusItemImage(badged: Bool) -> NSImage? {
        let base = NSImage(
            systemSymbolName: "rectangle.3.group",
            accessibilityDescription: badged ? "Desk Layouter — update available" : "Desk Layouter"
        )
        base?.isTemplate = true

        guard badged, let base else {
            return base
        }

        let size = base.size
        let composed = NSImage(size: size)
        composed.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))

        // A small dot in the top-right corner, with a transparent halo knocked out
        // first so the badge reads as a distinct mark rather than merging into the
        // symbol's strokes — keeping the badged icon recognisable as the same app.
        // Sizes are fractions of the icon height so the badge scales with the symbol:
        // a dot a little under half the icon, nudged in from the corner, ringed by a
        // thin transparent gap.
        let dotFraction = 0.42
        let cornerInsetFraction = 0.08
        let haloFraction = 0.06

        let dotDiameter = (size.height * dotFraction).rounded()
        let cornerInset = (size.height * cornerInsetFraction).rounded()
        let dotRect = NSRect(
            x: size.width - dotDiameter - cornerInset,
            y: size.height - dotDiameter - cornerInset,
            width: dotDiameter,
            height: dotDiameter
        )
        let haloWidth = (size.height * haloFraction).rounded()
        let haloRect = dotRect.insetBy(dx: -haloWidth, dy: -haloWidth)

        if let context = NSGraphicsContext.current {
            context.compositingOperation = .clear
            NSBezierPath(ovalIn: haloRect).fill()
            context.compositingOperation = .sourceOver
        }
        NSColor.black.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        composed.unlockFocus()
        composed.isTemplate = true
        return composed
    }

    private func makeEditorWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AppWindowConfiguration.defaultWidth,
                height: AppWindowConfiguration.defaultHeight
            ),
            styleMask: AppWindowConfiguration.styleMask,
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
            // The root wrapper swaps the window between the board and the
            // full-window Settings screen in place (issue #71); the board itself
            // owns none of that navigation state.
            rootView: AppRootView(
                model: rootModel,
                editorModel: editorModel,
                quit: { [weak self] in self?.presenter.quit() },
                // Route the editor's version control through the same standard
                // updater the menu bar uses (issue #70); passing `nil` as sender
                // is the manual "Check for Updates" entry point.
                checkForUpdates: { [weak self] in self?.updaterController.checkForUpdates(nil) }
            )
        )
        window.setContentSize(
            NSSize(
                width: AppWindowConfiguration.defaultWidth,
                height: AppWindowConfiguration.defaultHeight
            )
        )
        return window
    }
}
