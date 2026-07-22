# Desk Layouter

A personal macOS utility that decides which Desktop each application opens on. The user configures Assignments; macOS enforces them at app launch and at login.

## Language

**Display**:
A physical display on which macOS hosts an ordered set of Desktops. An Assignment identifies the physical Display independently of temporary roles such as Main.
_Avoid_: Screen, Monitor.

**Desktop**:
A macOS Space belonging to a Display, shown to the user positionally within that Display as "Desktop 1, 2, 3…". The unit an application is assigned to.
_Avoid_: Space (the internal/API term), Screen, Monitor.

**Assignment**:
A persistent rule that a given application should open on a specific numbered Desktop of a specific physical Display. Once written, macOS itself enforces it at launch and at login — the app does not move windows at runtime.
_Avoid_: Binding (the internal `com.apple.spaces` plist term), mapping, rule.

**Unavailable Display**:
A physical Display referenced by an Assignment that cannot currently be resolved as an independent destination, because it is disconnected or cannot be identified uniquely. Its Assignments remain part of the board.
_Avoid_: Missing screen, removed Display.

**Unavailable Desktop**:
A numbered Desktop referenced by an Assignment that does not exist on its currently available Display. Distinct from an Unavailable Display: the Display is known and connected, but the positional destination is invalid.
_Avoid_: Unavailable Display, missing Space.

**Preset**:
A named, persistent snapshot of the complete editable board, including every managed application's physical-Display Assignment and optional Layout. Loading creates a working copy without enacting it; later edits change the Preset only when the user explicitly updates it, while Apply and Arrange remain separate actions.
_Avoid_: Profile, template, configuration.

**Apply**:
Writing the current Assignments into macOS's Spaces store and restarting the Dock so they take effect.
_Avoid_: Sync, save, flush.

**Layout**:
A persistent rule for where a managed application's window sits on its Desktop's usable area, expressed as a horizontal and vertical division (full, halves, thirds, or fourths) and the cell or span the window occupies on each axis. “Full” covers the complete usable axis without entering macOS fullscreen. Assignment decides _which_ Desktop; Layout decides _where on it_. Per-application and independent — two apps' Layouts may overlap or leave gaps.
_Avoid_: Tile, arrangement, region, split.

**Arrange**:
Enacting Layouts at runtime by positioning and sizing each application's window via the Accessibility API. Distinct from Apply: Apply writes the Spaces store, Arrange moves live windows. It only affects the currently active Desktop directly; other Desktops with Layouts are arranged once each, the first time they become active after Arrange is triggered, after which the app stops observing.
_Avoid_: Apply, tile, layout (the verb), snap.
