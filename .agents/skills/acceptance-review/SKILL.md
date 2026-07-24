---
name: acceptance-review
description: Visually confirm a change's UI-observable acceptance criteria by rendering the app's own SwiftUI views offscreen to PNG (via `--render-scene`) and judging each criterion against the image. A peer of `/code-review`'s Spec axis — code-review reads the diff and spec but never looks at the running UI. Use when the user wants to verify UI acceptance criteria, review a branch/PR visually, or asks to "acceptance-review" a change.
---

Visually verify the UI-observable acceptance criteria of a change by rendering the
app's real SwiftUI views **offscreen** to PNG and judging each criterion against the
rendered image. This is the sight that `/code-review` lacks: code-review reads the diff
and the spec, but for a visual editor a large class of acceptance criteria are only
truly checkable by **seeing the screen** ("the What's-New text renders bold, not literal
`**asterisks**`"; "the Welcome callout hugs its content"; "Comet lands on Built-in
Desktop 2").

The review runs entirely without a Screen Recording (TCC) grant, a physical or second
Display, or installed apps — it uses the app's `--render-scene` offscreen render mode
(see `docs/adr/0005-offscreen-scene-render-for-acceptance-review.md` and
`docs/research/macos-agent-ui-review.md`). The loop is: **fabricate state → render
offscreen → `Read` the PNG → judge**.

The issue tracker should have been provided to you — run `/setup-matt-pocock-skills` if
`docs/agents/issue-tracker.md` is missing.

## Authority

Advisory tooling feeding the existing `AGENTS.md` bar — "every acceptance criterion is
genuinely met". A UI acceptance criterion that renders `fail` or **can't be visually
confirmed** counts as *not genuinely met* ⇒ not ready to merge. This invents **no new
gate**: there is no CI in this repo (CI #48 is intentionally deferred), so "runs on every
PR" means an agent-run step, not a GitHub check.

## Preconditions and caveats (surface these when they bear on a verdict)

- **Needs a GUI (Aqua) login session** — true inside Conductor, false over raw SSH. The
  render drives the real AppKit layout/draw pipeline via an offscreen `NSWindow`.
- **A render that produces no image STOPS the review** — `--render-scene` exits non-zero
  when a Scene produces no bitmap. Report the broken precondition and stop; never fabricate
  a verdict for a Scene that didn't render.
- **Documented fidelity gaps** — surface each only when it actually affects a call:
  - Not-installed app icons fall back to a **placeholder** (no real bundle to read).
  - Materials / "glass" may render **transparent**.
  - Dark mode must be set **explicitly** (Scenes render in deterministic light Aqua).
  - The render is a **depiction, not proof of enactment** — it shows the app's rendering
    of a fabricated state, never evidence macOS placed real windows on real Spaces.
  - `AsyncImage` / remote content renders blank.

## Process

### 1. Pin the diff and find the originating issue

The fixed point is whatever the user supplied; absent one, use `origin/main` — i.e. the
diff is `git diff origin/main...HEAD` (three-dot, against the merge-base). Note the commit
list with `git log origin/main..HEAD --oneline`. Confirm the fixed point resolves
(`git rev-parse`) and the diff is non-empty before going further.

Find the originating issue **exactly as code-review's Spec axis does**: issue references
in the commit messages (`#123`, `Closes #45`) → fetch via the workflow in
`docs/agents/issue-tracker.md` (`gh issue view <n> --comments`). Extract its **acceptance
criteria**. If the issue links a parent spec/PRD, read that too — the spec is authoritative.
If no AC list is found, ask the user; failing that, fall back to the change description
(the PR/commit bodies) as the criteria to review against, and say so.

### 2. Classify EVERY acceptance criterion into a ledger

So none falls through the gap between this skill and code-review, produce a ledger row for
**every** criterion, classified into exactly one bucket:

- **UI-observable** — checkable by looking at a rendered screen. **This skill's job.**
- **Non-visual** — logic, data, file output, wiring. Marked ***delegated to
  code-review/tests***.
- **Interaction-only** — a true click / drag / hover / animation outcome. Marked
  ***manual check required***. A **state transition** ("clicking Done returns to the board")
  can still be covered here as **before/after model-mutation renders** — two Scenes that
  mutate the model directly — so classify those as UI-observable; only genuinely
  un-modellable interaction stays manual.

**If no criterion is UI-observable** (a skill-only, docs-only, or pure-logic change with no
UI surface), report **"no UI acceptance surface"** and **PASS** — this is a graceful pass,
not a failure. Still emit the full ledger so coverage is auditable, then stop.

### 3. Choose or author a Scene per UI-observable criterion

A **Scene** is a fabricated app state rendered offscreen (see `CONTEXT.md`). For each
UI-observable criterion:

- **Reuse a catalog Scene** when one shows the needed state. Current catalog keys:
  `whats-new`, `editor-two-displays`, `editor-single-display` (see
  `Sources/DeskLayouter/SceneRender.swift`, `SceneCatalog`). List keys with an unknown-key
  render, e.g. `swift run DeskLayouter --render-scene __list`.
- **Author a temporary one-off Scene** when the catalog doesn't cover it — add it to
  `SceneCatalog` built from the app's existing injectable seams (`EditorModel.init(spacesAdapter:
  applicationsProvider:…)`, an injected `DisplayTopologySnapshot` topology, a fabricated
  applications provider, `move(bundleIdentifier:toDisplay:desktopNumber:)`, throwaway
  per-process stores). Reuse the exact fixtures the multi-Display tests hand-build.
- For a **state transition**, author before/after Scenes that mutate the model directly.
- **Revert** every temporary one-off Scene before returning, **unless** it is broadly useful
  for future features — only then promote it into the committed catalog (the "useful for
  future features" bar; the catalog is a small curated set, not a regression library).

### 4. Render + judge in a `general-purpose` sub-agent

Delegate the image-heavy build/render/judge work to a **single `general-purpose`
sub-agent** so it stays out of the main context and runs in parallel with code-review's
axes. Give the sub-agent:

- The diff command and commit list.
- The **UI-observable criteria** with the Scene key(s) chosen or authored for each, and any
  before/after transition pairing.
- Any one-off Scene source it must add (and the instruction to **revert** it before
  returning unless told to promote it).
- This brief:

  > For each UI-observable criterion: render its Scene(s) with `swift run DeskLayouter
  > --render-scene <key>` (or `make render-scenes SCENE=<key>`), which writes
  > `.build/scene-renders/<key>.png`. **`Read` each PNG** (you are vision-capable) and
  > return, per criterion: **verdict** (`pass` / `fail` / `not-visually-verifiable`), the
  > **Scene key(s) + PNG path(s)** as evidence, **one sentence** describing what the image
  > shows, and any **fidelity caveat** that affected the call. If a render exits non-zero or
  > produces no image, **stop and report that** for the affected criterion rather than
  > guessing a verdict. Revert any temporary one-off Scene edits before returning (leave the
  > working tree as you found it) unless told to promote it.

### 5. Report — per-AC table + ledger, and post to the PR

Present:

- The **classification ledger**: every criterion → bucket (UI-observable / non-visual→delegated
  / interaction-only→manual).
- A **per-AC table** for the UI-observable ones: **AC → verdict → evidence (Scene / PNG) → note**
  (the one-sentence description and any fidelity caveat).
- A one-line summary: counts of pass / fail / not-visually-verifiable, and whether any UI
  criterion is unmet (fail or not-visually-verifiable ⇒ not ready to merge under the
  `AGENTS.md` bar).

When a **PR exists** for this branch, post the **textual** per-AC verdicts and ledger via
`GH_HOST=github.com gh pr comment <n> --body "..."`. PNGs are referenced by **local path**
only — embedding images in the PR is out of scope (GitHub can't host a local PNG without an
upload step this repo doesn't have; PNGs stay ephemeral under `.build/`).

## Why a separate skill from code-review

`/code-review` reads the diff and the spec but never looks at the running UI, so a visual
regression (like the two v0.4.0 ones — literal `**asterisks**` in What's-New, the oversized
Welcome callout) passes its review and ships. Acceptance-review is the sight it lacks: it
renders the affected screens and judges the UI-observable criteria against the pixels. The
two run in the same verification pass (wired into `/implement`) and report separately — one
never masks the other.
