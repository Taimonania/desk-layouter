# Runtime window Arrange via the Accessibility API, one-shot per Desktop

Status: Accepted (implemented; extended to multiple physical Displays in #22)

## Context

Assignment decides *which* Desktop an application opens on. The follow-on **Layout** feature (foreshadowed at the end of [ADR-0001](./0001-declarative-desktop-assignment.md)) decides *where on that Desktop* an application's window sits — a per-app horizontal and vertical split (halves/thirds/fourths) with the window occupying a chosen cell or span.

This crosses a line the app has held until now. [ADR-0002](./0002-native-swift-appkit-menu-bar.md) and `CONTEXT.md` state that "the app does not move windows at runtime" — Assignment is written to the `com.apple.spaces` store and macOS enforces it forever. Layout has no such declarative mechanism. macOS exposes **no public API** to position a window on a Space; the only supported tool is the **Accessibility API** (`AXUIElement`), which requires the app itself to grab a window and set its frame at runtime. Two properties of that API shape everything below:

1. It can only read or set a window's frame on the **currently active Space**. Windows on inactive Desktops are unreachable.
2. It does not move windows between Spaces — but it never needs to here, because Assignment already puts each app's windows on the right Desktop.

The user's goal is "lay out all my Desktops from one action." Because of constraint (1), that is only literally achievable by making each Desktop active in turn.

## Decision

**Layout is persisted declarative desired state; enacting it (Arrange) is a distinct runtime act.** The declarative config stays declarative — a `Layout` is stored per managed application like an Assignment — and only enactment is runtime. Arrange is a separate verb from Apply: Apply writes the Spaces store and restarts the Dock; Arrange moves live windows via Accessibility and touches neither.

Triggering Arrange (the "Arrange" button):

1. Immediately arranges the **currently active Desktop**: for each managed app on it that has a Layout, take the frontmost standard window (`kAXStandardWindowSubrole`, skipping minimized) and set its frame within `NSScreen.visibleFrame`, then read the frame back and report any window that resisted (fixed-size/fullscreen/sheet).
2. **Arms** every other Desktop that has Layouts defined. The first time such a Desktop becomes active (`NSWorkspace.activeSpaceDidChangeNotification`), it is arranged **once**, then disarmed.
3. Once every armed Desktop has been visited and arranged, the app **stops observing entirely**. It is not a permanent background observer. Pressing Arrange again re-arms.

With multiple extended Displays, the unit of arming is the pair **physical
Display + positional Desktop number**, never the Desktop number alone. Arrange
immediately handles the currently visible Desktop on every connected Display,
using that Display's `NSScreen.visibleFrame`; it then arms each remaining pair
that contains a valid Layout. Live per-Display Space state comes from the
dynamically resolved SkyLight managed-display-spaces snapshot and fails closed
when unavailable. Reports always name both the physical Display and Desktop.

Overlaps and gaps between apps' Layouts are allowed and unvalidated; apps with no Layout are never touched.

### Considered options

- **Private SkyLight / `CGSSpaces` APIs.** Rejected. Their only added capability over Accessibility is moving windows across *different* Spaces — which Arrange never does. They are undocumented and unstable, are only honored fully from `Dock.app` (requiring code injection into a system process), and that injection requires partially disabling SIP (weakening system security machine-wide, silently re-enabled by Apple repairs). They are both the costly path and an unnecessary one. See [macOS app stack research §2a, §2e](../research/macos-app-stack.md).
- **Forced walk of all Desktops on one press** — synthesize the "switch Space" keystrokes, wait for each animation, arrange, repeat. Rejected as the app's most breakage-prone surface: there is no public "go to Desktop N" call, so it relies on synthesized keystrokes and animation-timing waits; the "automatically rearrange Spaces based on most recent use" setting can scramble order; and multi-display makes the shortcut ambiguous. It is also visually jarring (the screen flips through every Space).

The one-shot-per-Desktop observer delivers the same outcome — every Desktop ends up arranged — as a natural consequence of the user moving between Desktops, without the fragile keystroke walk and without a permanent background agent.

## Consequences

- The app becomes a runtime window-mover for Layout, a deliberate departure from the strictly declarative Assignment model. The departure is contained: only enactment is runtime; the config remains declarative and is never seeded from live window state.
- Arrange requires the Accessibility permission (`AXIsProcessTrustedWithOptions`) — the same permission the app already needs — and needs **no SIP changes and no permanently running agent**.
- "All Desktops" is coverage-over-time, not instantaneous. A Desktop the user never visits after pressing Arrange is never arranged. This is surfaced in the UI (a tooltip explaining "this Desktop now, others the first time you visit them").
- Coordinate handling is the primary correctness risk: the Accessibility plane is top-left origin while `NSScreen` is bottom-left, both anchored to the primary display; the y-flip must be taken against the primary display height, and set size→position→size to defeat per-app clamping (see [in-desktop window layout research](../research/macos-in-desktop-window-layout.md)).
- Multi-window apps arrange only their frontmost standard window in this version.
