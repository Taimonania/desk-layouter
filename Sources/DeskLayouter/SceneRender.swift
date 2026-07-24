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
        [whatsNew, editorTwoDisplays, editorSingleDisplay]
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

    /// A two-Display × three-Desktop editor with apps placed across both Displays —
    /// the reusable multi-Display scaffolding Scene (issue #120). The whole
    /// Display/Desktop layout comes from an injected `SpacesAdapter` topology (the
    /// same `DisplayTopologySnapshot` fixtures the multi-Display tests hand-build),
    /// the app list from a fabricated applications provider, and every app is placed
    /// with `EditorModel.move(bundleIdentifier:toDisplay:desktopNumber:)` — all
    /// backed by throwaway per-process stores, so it touches no real board, presets,
    /// or hardware. Rendered through the faithful `NSHostingView` path so the
    /// `LazyVGrid`-in-`ScrollView` Desktop columns and the AppKit-backed
    /// Preset picker / "Add to" menu / search field all draw (not blank).
    ///
    /// Not-installed app icons fall back to a placeholder — a documented fidelity
    /// gap (spec #118), not a failure.
    static let editorTwoDisplays = Scene(
        key: "editor-two-displays",
        size: CGSize(width: 1280, height: 800)
    ) {
        let builtIn = DisplayIdentity(
            colorSyncUUID: "SCENE-BUILT-IN",
            lastKnownName: "Built-in Display",
            vendorID: 1,
            modelID: 10,
            serialNumber: 100
        )
        let studio = DisplayIdentity(
            colorSyncUUID: "SCENE-STUDIO",
            lastKnownName: "Studio Display",
            vendorID: 2,
            modelID: 20,
            serialNumber: 200
        )
        let topology = DisplayTopologySnapshot(
            displaysHaveSeparateSpaces: true,
            automaticallyRearrangesSpaces: false,
            sections: [
                sceneSection(primary: builtIn, main: true, x: 0, desktops: ["B1", "B2", "B3"]),
                sceneSection(primary: studio, main: false, x: 1000, desktops: ["S1", "S2", "S3"]),
            ]
        )

        // Six Desktops with varied per-Desktop counts, and the ticket's named
        // hero placements: Comet on Built-in Desktop 2, Conductor on Studio Desktop 3.
        return buildEditorScene(
            topology: topology,
            placements: [
                Placement(app: SceneApps.comet, display: builtIn, desktop: 2),
                Placement(app: SceneApps.xcode, display: builtIn, desktop: 1),
                Placement(app: SceneApps.terminal, display: builtIn, desktop: 1),
                Placement(app: SceneApps.notes, display: builtIn, desktop: 3),
                Placement(app: SceneApps.conductor, display: studio, desktop: 3),
                Placement(app: SceneApps.slack, display: studio, desktop: 1),
                Placement(app: SceneApps.figma, display: studio, desktop: 2),
            ]
        )
    }

    /// A single-Display editor with a few apps placed across its Desktops (issue
    /// #120). Same fabricated seams as ``editorTwoDisplays`` — injected topology,
    /// apps provider, throwaway stores, `move` for placement — narrowed to one
    /// Display so single-Display layout ACs are checkable without a second Display.
    static let editorSingleDisplay = Scene(
        key: "editor-single-display",
        size: CGSize(width: 1024, height: 720)
    ) {
        let builtIn = DisplayIdentity(
            colorSyncUUID: "SCENE-SOLO",
            lastKnownName: "Built-in Display",
            vendorID: 3,
            modelID: 30,
            serialNumber: 300
        )
        let topology = DisplayTopologySnapshot(
            displaysHaveSeparateSpaces: true,
            automaticallyRearrangesSpaces: false,
            sections: [
                sceneSection(primary: builtIn, main: true, x: 0, desktops: ["D1", "D2", "D3"]),
            ]
        )

        return buildEditorScene(
            topology: topology,
            placements: [
                Placement(app: SceneApps.safari, display: builtIn, desktop: 1),
                Placement(app: SceneApps.terminal, display: builtIn, desktop: 1),
                Placement(app: SceneApps.xcode, display: builtIn, desktop: 2),
                Placement(app: SceneApps.notes, display: builtIn, desktop: 3),
            ]
        )
    }

    /// One app to place on a fabricated Desktop while building an editor Scene.
    private struct Placement {
        let app: InstalledApplication
        let display: DisplayIdentity
        let desktop: Int
    }

    /// Builds an `EditorModel` from fabricated seams and returns the real
    /// `EditorView` to render. The topology comes from an injected `SpacesAdapter`,
    /// the picker catalog from a fabricated applications provider, and the board and
    /// preset libraries from throwaway per-process stores at a UUID-suffixed temp
    /// path (never the user's real Application Support), so nothing real is touched.
    /// Apps are seeded onto the board and then positioned with
    /// `EditorModel.move(bundleIdentifier:toDisplay:desktopNumber:)`.
    @MainActor
    private static func buildEditorScene(
        topology: DisplayTopologySnapshot,
        placements: [Placement]
    ) -> AnyView {
        let apps = orderedUnique(placements.map(\.app))

        // Seed the board with the placed apps (at Desktop 1) so they are already
        // managed; `move` below positions each on its final Desktop. Written to a
        // throwaway store so the user's real board-state.json is never read or hit.
        let seededBoard = BoardState(
            configuration: DeskLayouterConfiguration(
                managedApplications: placements.map { placement in
                    ManagedApplication(
                        bundleIdentifier: placement.app.bundleIdentifier,
                        displayName: placement.app.displayName,
                        display: placement.display,
                        desktopNumber: 1
                    )
                }
            )
        )

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-render-\(UUID().uuidString)", isDirectory: true)
        let boardStore = BoardStateStore(fileURL: scratch.appendingPathComponent("board-state.json"))
        let presetStore = PresetLibraryStore(fileURL: scratch.appendingPathComponent("presets.json"))
        try? boardStore.save(seededBoard)

        let model = EditorModel(
            spacesAdapter: SceneSpacesAdapter(topology: topology),
            boardStateStore: boardStore,
            presetLibraryStore: presetStore,
            applicationsProvider: SceneApplicationsProvider(catalog: apps)
        )
        // Load the fabricated topology + picker catalog into the model.
        model.refresh()
        // Place each app on its final Desktop through the real Move seam.
        for placement in placements {
            model.move(
                bundleIdentifier: placement.app.bundleIdentifier,
                toDisplay: placement.display,
                desktopNumber: placement.desktop
            )
        }

        return AnyView(
            EditorView(
                model: model,
                quit: {},
                checkForUpdates: {},
                openSettings: {},
                openHelp: {}
            )
        )
    }

    /// A `DisplayDesktopSectionSnapshot` for one physical Display, mirroring the
    /// helper the multi-Display tests use to hand-build topology fixtures.
    private static func sceneSection(
        primary: DisplayIdentity,
        main: Bool,
        x: Double,
        desktops: [String]
    ) -> DisplayDesktopSectionSnapshot {
        DisplayDesktopSectionSnapshot(
            primaryDisplay: primary,
            memberDisplays: [primary],
            isMain: main,
            bounds: DisplayBounds(x: x, y: 0, width: 1000, height: 800),
            orderedDesktopUUIDs: desktops
        )
    }

    /// The fabricated picker catalog the editor Scenes draw from. The bundle
    /// identifiers are realistic, but the injected `SceneApplicationsProvider`
    /// serves no icons, so every card falls back to the placeholder icon — a
    /// documented fidelity gap (spec #118), not a failure.
    private enum SceneApps {
        static func app(_ name: String, _ bundleIdentifier: String) -> InstalledApplication {
            InstalledApplication(displayName: name, bundleIdentifier: bundleIdentifier, isRunning: false)
        }

        static let comet = app("Comet", "com.perplexity.comet")
        static let conductor = app("Conductor", "com.conductor.app")
        static let safari = app("Safari", "com.apple.Safari")
        static let terminal = app("Terminal", "com.apple.Terminal")
        static let notes = app("Notes", "com.apple.Notes")
        static let xcode = app("Xcode", "com.apple.dt.Xcode")
        static let slack = app("Slack", "com.tinyspeck.slackmacgap")
        static let figma = app("Figma", "com.figma.Desktop")
    }

    /// Preserves first-seen order while removing duplicate apps placed on more than
    /// one Desktop, so the fabricated picker catalog lists each app once.
    private static func orderedUnique(_ apps: [InstalledApplication]) -> [InstalledApplication] {
        var seen: Set<String> = []
        return apps.filter { seen.insert($0.bundleIdentifier).inserted }
    }
}

/// A fabricated `SpacesAdapter` that serves a fixed, hand-built topology (issue
/// #120). It reads no macOS `com.apple.spaces` store and mutates nothing — Apply
/// is a no-op because a Scene render only depicts fabricated state, never enacts
/// it. Only the members the editor render path exercises carry real behaviour.
private struct SceneSpacesAdapter: SpacesAdapter {
    let topology: DisplayTopologySnapshot

    func currentDesktopSnapshot() throws -> DesktopSnapshot {
        guard let section = topology.sections.first else {
            throw SpacesAdapterError.noActiveDisplay
        }
        return DesktopSnapshot(
            display: section.primaryDisplay,
            orderedDesktopUUIDs: section.orderedDesktopUUIDs
        )
    }

    func currentDisplayTopology() throws -> DisplayTopologySnapshot { topology }

    func activeDesktopNumber() throws -> Int? { 1 }

    func apply(
        managedBindings: [String: String],
        managedBundleIdentifiers: Set<String>,
        expectedSnapshot: DesktopSnapshot?
    ) throws {}
}

/// A fabricated applications provider that serves a fixed picker catalog and no
/// icons (issue #120). Every card therefore falls back to the placeholder icon —
/// the documented not-installed fidelity gap (spec #118), not a failure.
@MainActor
private struct SceneApplicationsProvider: InstalledApplicationsProviding {
    let catalog: [InstalledApplication]

    func applications() -> [InstalledApplication] { catalog }

    func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? { nil }
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
