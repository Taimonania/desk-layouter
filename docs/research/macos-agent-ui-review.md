# Letting a non-interactive agent visually review the macOS UI

Research backing spec #118 (Agent Acceptance Review) and its first slice #119
(the `--render-scene` mode + the What's-New Scene). This captures *why* we render
offscreen instead of capturing the screen, and the empirical finding (§9) that
picks the render mechanism.

## 1. Problem

Desk Layouter is a menu-bar SwiftUI app whose whole value is a *visual* editor
(Displays, Desktops, app tiles, the What's-New card, the Welcome tour). A large
class of acceptance criteria are only truly checkable by seeing the screen: text
renders bold vs. literal `**asterisks**`, a callout hugs its content vs. an
oversized empty card, an app tile lands on the right Desktop. The agent that
resolves an issue verifies with `/code-review`, which reads the diff and the spec
but never looks at the running UI — so these criteria get silently deferred, and
two such regressions shipped in v0.4.0.

## 2. Why not `screencapture` / ScreenCaptureKit

Both need **two** independent, non-negotiable grants:

1. **A live Aqua window-server session.** No windows exist to capture without one.
2. **A Screen Recording (TCC) grant attributed to the responsible process.** macOS
   attributes the grant up the responsible-process chain, which version-manager and
   `exec` shims break; `tccutil` can only *reset* a grant, never *create* one; the
   TCC store is SIP-protected, so it cannot be seeded from a script.

There is no robust, per-worktree way for a non-interactive CLI agent to obtain (2).
This is the unfixable case — we stop trying to capture the screen.

## 3. Reframe: render the app's own views, don't capture the screen

An app can render its *own* SwiftUI views to a bitmap in-process. That needs the
Aqua session (present in a Conductor GUI login) but **not** any Screen Recording
grant, no second Display, and no installed apps. It produces a *depiction* of a
fabricated state — not proof macOS enacted a layout, but exactly what's needed to
check that the UI *draws* a given state correctly.

## 4. Scenes

A **Scene** is a named, fabricated app state built from the model's existing
injectable seams (`EditorModel.init(spacesAdapter:applicationsProvider:…)`, an
injected `SpacesAdapter` topology, a fabricated applications provider,
`move(bundleIdentifier:toDisplay:desktopNumber:)`), backed by throwaway per-process
stores. It renders offscreen to `.build/scene-renders/<key>.png`. The committed
catalog is a small curated set of reusable scaffolding (a two-Display × three-Desktop
editor, a single-Display editor, the What's-New card), not a grow-forever regression
library; one-off Scenes for a specific criterion are authored temporarily and
reverted.

## 5. Two options considered

- **Option A — golden-image diffing suite.** Move the editor views into the library
  and add a diffing test target (e.g. swift-snapshot-testing under XCTest) that
  asserts pixel/structure against committed reference images. High fidelity as a
  regression gate, but a large commitment: a module-boundary change, a new test
  framework, and a reference-image maintenance burden. Deferred until regressions
  justify it.
- **Option B — render-and-`Read` gallery (chosen).** Render Scenes to PNG and let a
  vision-capable agent `Read` and judge them against the acceptance criteria. No new
  framework, no reference images, no module move. The executable contract tests
  assert only the observable behaviour (a PNG appears, exit codes, `all` vs single,
  unknown-key error); fidelity is judged by the agent's eye.

## 6. Isolation

Output lives under gitignored `.build/scene-renders/`, per-worktree, so N Conductor
agents render concurrently without contending on one display, window server, or
output path. Scenes use throwaway `UserDefaults` suites and in-memory stores, so a
render never touches the user's real board, presets, or Spaces.

## 7. Preconditions and fidelity caveats

- Needs a GUI (Aqua) login session (true in Conductor, false over raw SSH).
- Needs **no** Screen Recording/Accessibility TCC grant and **no** physical Display.
- Known fidelity gaps, to be surfaced when a verdict depends on them: materials /
  "glass" may render transparent; `AsyncImage`/remote content blanks; not-installed
  app icons fall back to placeholders; **dark mode must be set explicitly** (renders
  default to light Aqua). A render that produces no image is reported as a broken
  precondition — never a fabricated pass.

## 8. Out of scope

Proof macOS enacted a layout (the depiction-not-enactment limit); live interaction
(clicks, drags, hovers, animation — only model-driven before/after states are
covered); a golden-image assertion suite (Option A); embedding PNGs in the PR
(GitHub can't host a local file without an upload step — only textual verdicts with
local paths are posted); CI enforcement (deferred, #48).

## 9. Empirical: `ImageRenderer` vs. offscreen hosting window

Two in-process mechanisms were compared on the real views:

- **SwiftUI `ImageRenderer`.** Renders a `View` to a `CGImage`/`NSImage` directly,
  no window. On a provably-static view (a plain `Text` card) it works. On the
  **editor** it renders **blank**: the `LazyVGrid` inside a `ScrollView` never
  materializes its cells (lazy containers need a real scroll/layout pass), and
  AppKit-backed controls (`Menu`, `Picker`, `TextField`) come out as empty
  placeholders. So `ImageRenderer` is only trustworthy for static screens.

- **`NSHostingView` inside an offscreen `NSWindow` + `cacheDisplay` (chosen default).**
  Host the SwiftUI view in a real (borderless, buffered) `NSWindow` parked far
  offscreen (e.g. origin `(-30000, -30000)`), force a layout pass, spin the run loop
  briefly so SwiftUI flushes layout+draw and AppKit-backed/lazy content
  materializes, then `cacheDisplay(in:to:)` into a
  `bitmapImageRepForCachingDisplay` and encode PNG. Because it drives the *real*
  AppKit layout/draw pipeline, lazy grids and AppKit controls render faithfully.

**Decision:** the hosting-window path is the default entry point; `ImageRenderer` is
reserved for provably-static screens only. Both would live behind the one
`--render-scene` entry point. Verified in #119: the What's-New Scene renders its
`**bold**` highlights as actual bold via this path — the tracer that would have
caught the v0.4.0 literal-asterisks regression.
