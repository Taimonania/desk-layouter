## Highlights

- In-app auto-update: Desk Layouter now checks for and installs new versions
  itself (right-click the menu-bar icon → "Check for Updates…"), powered by
  Sparkle over a signed appcast.
- Presets: create, load, and update named Presets; rename and delete them;
  modified working copies are protected when switching.
- Unavailable Preset applications and Desktops are now surfaced instead of
  silently dropped.

## Notes

- macOS 13+; universal (Apple Silicon + Intel).
- Signed with a Developer ID identity and notarized by Apple, so it opens
  without Gatekeeper warnings and keeps its Accessibility grant across updates.
- Updates are delivered as EdDSA-signed archives; the app verifies each update's
  signature before installing.
