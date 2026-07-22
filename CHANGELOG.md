# Changelog

The single source of truth for Desk Layouter's per-version release highlights.
Each release is a `## <version> — <date>` section with user-facing bullet
highlights (newest first). The app bundles this file and shows the newest
highlights on the first launch after an upgrade (the What's-New screen); the
release pipeline derives each GitHub release's notes from the matching section.

## 0.2.1 — 2026-07-22

- The editor now groups Apply and Arrange together, aligns Preset controls consistently, and keeps hover tooltips fully visible at window edges.

## 0.2.0 — 2026-07-22

- Arrange now targets only applications assigned to the live active Desktop, avoiding stale Desktop information and leaving other Desktops untouched.
- Arrange waits for Desktop transitions and application windows to settle before acting, preventing early or misleading results during gestures and rapid switches.
- Desk Layouter now has a complete app icon in Finder, the Dock, and the application bundle.
- The editor opens automatically at launch and comes back into focus when the running app is opened again.
- The editor now shows its version with a direct Check for Updates control, plus Settings for choosing whether updates are downloaded automatically.
- A guided Welcome tour introduces the core workflow on first launch and remains available from Help.
- After an upgrade, a What's New view presents the highlights for every newly installed version.
- Presets always keep exactly one selection, including safe startup migration and deletion of the selected Preset.
- Edited Presets are clearly marked and can be updated or reverted independently of unapplied layout changes.
- Preset switching now stays in the selector, while create, rename, and delete actions live in a compact management menu.
- Onboarding and the primary editor controls have been polished with a clearer four-page tour, faster tooltips, simpler search and status presentation, and easier problem reporting.
- Application search now keeps icon discovery and loading out of the typing path, keeping large application catalogs responsive.

## 0.1.1 — 2026-07-22

- In-app auto-update: Desk Layouter now checks for and installs new versions itself (right-click the menu-bar icon → "Check for Updates…"), powered by Sparkle over a signed appcast.
- Presets: create, load, and update named Presets; rename and delete them; modified working copies are protected when switching.
- Unavailable Preset applications and Desktops are now surfaced instead of silently dropped.

## 0.1.0 — 2026-07-21

- First public release of Desk Layouter.
