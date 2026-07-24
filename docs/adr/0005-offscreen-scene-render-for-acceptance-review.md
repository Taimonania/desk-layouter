# Offscreen Scene rendering for Acceptance Review

Status: Accepted (render mode + first static Scene implemented in #119; the
`acceptance-review` skill and the editor Scene catalog land in follow-ups #120/#121).
Spec: #118.

## Context

When an agent resolves an issue in Desk Layouter it verifies its work with
`/code-review`, which reads the diff and the spec but never *looks at the running
UI*. For a menu-bar SwiftUI app whose whole point is a visual editor, a large class
of acceptance criteria are only truly checkable by seeing the screen — "the
What's-New text renders bold, not literal `**asterisks**`", "the Welcome callout
hugs its content", "Comet lands on Built-in Desktop 2". A non-interactive CLI agent
cannot see the screen, and the obvious tools are both blocked:

`screencapture` and ScreenCaptureKit each require **two** independent grants — (a) a
live Aqua window-server session **and** (b) a Screen Recording (TCC) grant that
macOS attributes to the *responsible* process. Version-manager/`exec` shims break
that attribution; `tccutil` can only *reset* a grant, never *create* one; the TCC
store is SIP-protected. There is no robust, per-worktree way to give a CLI agent
capture permission, so "check the real UI" gets silently deferred — and visual
regressions (the two v0.4.0 ones) ship.

## Decision

Add a hidden **`--render-scene [key|all]`** launch mode to the app. Launched with the
flag, the app renders one or more named **Scenes** — fabricated app states built
from the model's existing injectable seams — offscreen to
`.build/scene-renders/<key>.png` and exits, **before** installing any menu-bar item,
window, or updater. Without the flag it boots exactly as today.

Rendering uses an **`NSHostingView` inside an offscreen `NSWindow` + `cacheDisplay`**,
parked far offscreen. This drives the real AppKit layout/draw pipeline, so lazy
content (the editor's `LazyVGrid` in a `ScrollView`) and AppKit-backed controls
(`Menu`/`Picker`/`TextField`) render faithfully. An agent then `Read`s the PNG and
judges each UI-observable acceptance criterion against it — the **Acceptance Review**
loop: *fabricate state → render offscreen → `Read` the PNG → judge*.

The mode needs a GUI (Aqua) login session (true in Conductor, false over raw SSH)
but **no** Screen Recording/Accessibility TCC grant and **no** physical or second
Display. Output is gitignored (`.build/`) and per-worktree, so N parallel agents
never contend on one display or one path. Scenes are backed by throwaway
per-process stores, so a render never reads or corrupts the user's real board,
presets, or Spaces.

## Hard limits (why this is a review aid, not proof)

- **Dual TCC + Aqua gates rule out screencapture.** This is the unfixable case; we
  render the app's own views instead of capturing the screen.
- **Depiction, not enactment.** A Scene is the app's *depiction* of a fabricated
  state — not evidence macOS placed real windows on real Spaces across real
  monitors. A UI criterion about enactment stays a manual/human check.
- **Fidelity gaps are documented caveats, not bugs.** Materials/"glass" may render
  transparent; `AsyncImage`/remote content blanks; not-installed app icons fall back
  to placeholders; dark mode must be set explicitly (renders default to light Aqua).
  A verdict that depends on one of these must surface the caveat rather than assert a
  pass the render can't support.
- **`ImageRenderer` is not the default path.** Bare SwiftUI `ImageRenderer` renders
  the control-/grid-heavy editor **blank** (lazy cells never materialize; AppKit
  controls become placeholders — empirical finding in
  `docs/research/macos-agent-ui-review.md` §9). It is reserved for provably-static
  screens; the hosting-window path is the default.

## Consequences

- One new seam: the `--render-scene` mode + `Scene` catalog in the `DeskLayouter`
  app target. No production seam is added to the `DeskLayouterMacOS` library and the
  editor views are **not** migrated into the library — that is research "Option A"
  (a golden-image diffing suite), explicitly deferred until regressions justify the
  larger commitment. This is "Option B": a render-and-`Read` gallery.
- Golden-image / pixel-diff assertions are out of scope. Fidelity of the *image* is
  judged by the agent's `Read`, not asserted in code; the executable contract tests
  assert only the observable behaviour (a non-empty PNG at the documented path,
  exit codes, `all` vs single, unknown-key error).
- No CI enforcement (CI is deferred, #48); Acceptance Review is an agent-run
  convention wired into `/implement`, feeding the existing `AGENTS.md` merge bar
  rather than inventing a new gate.
