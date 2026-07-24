import AppKit
import DeskLayouterCore
import DeskLayouterMacOS
import SwiftUI

/// A named, fabricated app state rendered offscreen to a PNG for Acceptance Review
/// (issue #119, spec #118). A Scene pairs a stable `key` (its filename and CLI
/// selector) with a `size` and a `builder` that fabricates the app state — from the
/// model's existing pure/injectable seams, backed by throwaway per-process stores —
/// and returns the SwiftUI view to render. It touches no real hardware, Spaces, or
/// the user's saved board.
///
/// "Scene" is deliberately not "Snapshot": `CONTEXT.md` reserves "Snapshot" for
/// point-in-time reads of live macOS state (`DesktopSnapshot`, `DisplayTopologySnapshot`).
struct Scene {
    /// Stable identifier — the `--render-scene <key>` selector and the `<key>.png`
    /// output filename.
    let key: String

    /// The offscreen render size in points.
    let size: CGSize

    /// Fabricates the app state and returns the view to render. Runs on the main
    /// actor because it builds `@MainActor` models and SwiftUI views.
    let builder: @MainActor () -> AnyView
}

/// The committed catalog of reusable scaffolding Scenes. Kept deliberately small —
/// a curated set of broadly useful states, not a grow-forever regression library.
/// Issue #119 seeds it with the single static tracer Scene (the What's-New card);
/// the editor Scenes land in #120.
enum SceneCatalog {
    /// Every catalog Scene, in a stable order. `--render-scene all` (and a bare
    /// `--render-scene`) renders each of these.
    static var all: [Scene] {
        [whatsNew]
    }

    /// The available Scene keys, for the unknown-key error message.
    static var keys: [String] {
        all.map(\.key)
    }

    /// The What's-New card, fabricated on an upgrade from 0.3.0 to 0.4.0 so its
    /// highlights render. The seed changelog carries `**bold**` emphasis: this Scene
    /// is the static tracer that would have caught the v0.4.0 regression where the
    /// card showed literal `**asterisks**` instead of bold text (issue #116).
    ///
    /// Built from the app's real seams — an isolated `UserDefaults` suite behind
    /// `AppStateStore` plus injected `currentVersion`/`changelogText` — so it never
    /// reads or writes the user's real preferences.
    static let whatsNew = Scene(
        key: "whats-new",
        size: CGSize(width: 900, height: 640)
    ) {
        let changelog = """
        # Changelog

        ## 0.4.0 — 2026-07-22
        - What's-New now renders **bold** inline Markdown instead of literal asterisks
        - The Welcome callout **hugs its content** instead of an oversized empty card
        - Assignments target the **physical Display**, not the Main role

        ## 0.3.0 — 2026-06-01
        - An earlier release the user has already seen
        """

        // Throwaway, per-process defaults: fabricating a Scene never touches the
        // real app preferences. A UUID-suffixed suite keeps parallel renders isolated.
        let defaults = UserDefaults(suiteName: "scene-render-\(UUID().uuidString)") ?? .standard
        let appState = AppStateStore(defaults: defaults)
        // Seed a lower last-seen version so the pure `WhatsNew.onLaunch` seam presents
        // the surface for the 0.4.0 upgrade.
        appState.lastSeenVersion = "0.3.0"

        let model = AppRootModel(
            appState: appState,
            currentVersion: "0.4.0",
            changelogText: changelog
        )

        return AnyView(WhatsNewView(model: model))
    }
}

/// The hidden `--render-scene [key|all]` launch mode (issue #119). Launched with the
/// flag, the app renders the selected Scene(s) offscreen to `.build/scene-renders/<key>.png`
/// and exits — before any menu-bar item or window is installed. Without the flag it
/// boots exactly as today.
///
/// Rendering uses an `NSHostingView` inside an offscreen `NSWindow` + `cacheDisplay`
/// (parked far offscreen), which drives the real AppKit layout/draw pipeline so
/// control- and grid-heavy views render faithfully. Bare SwiftUI `ImageRenderer` is
/// reserved for provably-static screens (it renders the editor blank — see
/// `docs/research/macos-agent-ui-review.md`). Needs a GUI (Aqua) session but **no**
/// Screen Recording (TCC) grant and no physical Display.
@MainActor
enum SceneRender {
    /// The output directory, `<cwd>/.build/scene-renders`, gitignored and per-worktree.
    static var outputDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/scene-renders", isDirectory: true)
    }

    /// Renders the requested Scenes and exits, or returns without side effects.
    ///
    /// - Returns `false` when `--render-scene` is absent: the caller boots the normal
    ///   menu-bar app unchanged.
    /// - Returns `true` after writing every requested Scene's PNG: the caller returns
    ///   from `main` and the process exits 0, having installed no menu-bar item.
    /// - Terminates the process with a non-zero status on an unknown key (listing the
    ///   available keys plus `all`) or a render that produces no image.
    static func runIfRequested() -> Bool {
        guard let selection = SceneRenderArguments.parse(CommandLine.arguments) else {
            return false
        }

        let scenes: [Scene]
        switch selection {
        case .all:
            scenes = SceneCatalog.all
        case let .key(key):
            guard let scene = SceneCatalog.all.first(where: { $0.key == key }) else {
                let available = (SceneCatalog.keys + [SceneRenderArguments.allKeyword])
                    .joined(separator: ", ")
                fail("unknown scene '\(key)'. Available: \(available)", code: 64)
            }
            scenes = [scene]
        }

        // Initialize the shared application so AppKit view rendering has a live
        // NSApp, but never enter its run loop or install any UI. `.prohibited`
        // keeps the render from stealing focus or appearing anywhere.
        NSApplication.shared.setActivationPolicy(.prohibited)

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fail("could not create output directory \(outputDirectory.path): \(error)", code: 74)
        }

        for scene in scenes {
            guard let png = renderPNG(scene), !png.isEmpty else {
                fail("scene '\(scene.key)' produced no image", code: 70)
            }
            let url = outputDirectory.appendingPathComponent("\(scene.key).png")
            do {
                try png.write(to: url)
            } catch {
                fail("could not write \(url.path): \(error)", code: 74)
            }
            FileHandle.standardOutput.write(Data("rendered \(scene.key) -> \(url.path)\n".utf8))
        }

        return true
    }

    /// Renders one Scene offscreen and returns PNG bytes, or `nil` if AppKit could
    /// not produce a bitmap.
    private static func renderPNG(_ scene: Scene) -> Data? {
        let hosting = NSHostingView(
            rootView: scene.builder()
                .frame(width: scene.size.width, height: scene.size.height)
        )
        hosting.frame = CGRect(origin: .zero, size: scene.size)

        // Park the window far offscreen so it never flashes on any physical Display,
        // yet is real enough for AppKit to lay out and draw its contents.
        let window = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: scene.size.width, height: scene.size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Dark mode must be set explicitly; render in a deterministic light Aqua.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()

        hosting.layoutSubtreeIfNeeded()
        // Spin the run loop briefly so SwiftUI flushes a layout+draw pass and any
        // AppKit-backed / lazy content materializes before we capture.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.orderOut(nil)
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }

    /// Reports a fatal render error to stderr and exits with `code`.
    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("render-scene: \(message)\n".utf8))
        exit(code)
    }
}
