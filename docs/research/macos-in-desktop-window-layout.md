# Arranging windows within a Desktop via the Accessibility API (2026)

Research on how to concretely implement a per-app, per-Desktop **tiled layout** feature on
modern macOS (Sequoia 15 / macOS 26), for the existing personal menu-bar utility. This picks up
where [`macos-app-stack.md`](./macos-app-stack.md) left off: **which Desktop an app opens on is
already settled** (via the `com.apple.spaces` `app-bindings` mechanism). This document is about
the *follow-on* feature — once the app's windows are on their Desktop, size and place them into a
grid region of that Desktop's screen.

The prior research established the tool: the **Accessibility API (`AXUIElement`)** can move/resize
windows **within the current Space** and is the chosen mechanism here. Private SkyLight/Spaces
APIs and moving windows *between* Spaces are out of scope and not repeated. Everything below is
about the *how* of placing a window into a rectangle.

---

## Recommendation / TL;DR

- **The call sequence is small and well-established.** `AXUIElementCreateApplication(pid)` →
  read `kAXWindowsAttribute` → for each target window, set **`kAXSizeAttribute`, then
  `kAXPositionAttribute`, then `kAXSizeAttribute` again**, each value wrapped with
  `AXValueCreate`. The size-position-size dance is not superstition: Rectangle does it verbatim
  because macOS clamps a window's size to what fits at its *current* position, so you must resize,
  move, then resize again. This is the single most important implementation detail.
- **The coordinate flip is the #1 source of bugs.** `NSScreen` uses a **bottom-left** origin;
  the Accessibility API uses a **global top-left** origin spanning all displays. The conversion is
  a single y-flip against the **primary display's height** (not the target display's):
  `ax.y = NSScreen.screens[0].frame.maxY − cocoaRect.maxY`. Both Rectangle and AeroSpace flip
  against the *main* monitor. x is unchanged. Everything is in **points**, so
  `backingScaleFactor` does *not* enter this math.
- **Compute the target rect from `NSScreen.visibleFrame`** (which already excludes the menu bar
  and Dock), then subdivide by the fraction grid. Optional gaps/padding are a trivial inset.
- **You can only reliably tile windows on the currently-active Space.** This is a hard AX
  constraint and it shapes the whole feature: the layout for "Desktop 3" can only be *applied* when
  Desktop 3 is the active Space. So apply on triggers — app launch
  (`didLaunchApplicationNotification`), app activation
  (`didActivateApplicationNotification`), a global hotkey, or an explicit "re-tile now" menu
  action — and treat the stored layout as a *desired state* re-asserted idempotently, exactly like
  the existing Assignment model re-asserts bindings on Apply.
- **Some windows simply won't cooperate** (fixed-size, native-fullscreen, sheets/dialogs). `AX`
  setters fail silently-ish (return an `AXError`, or the app clamps the value). The robust pattern
  — which mirrors this app's existing read-back verification in `MacOSSpacesAdapter` — is to
  **read the geometry back** after setting and report/skip the ones that didn't take.
- **Data model:** add an optional `layout` to `ManagedApplication` describing the grid
  (horizontal divisions, vertical divisions) and the occupied cell span. Keep it optional and
  tolerant-decoded so existing configurations load unchanged.

---

## 1. The exact Accessibility API call sequence

### 1a. Get the application element and its windows

An app-level accessibility element is created from a **pid**, not a bundle id
([`AXUIElementCreateApplication`](https://developer.apple.com/documentation/applicationservices/1462075-axuielementcreateapplication)).
The windows come from reading
[`kAXWindowsAttribute`](https://developer.apple.com/documentation/applicationservices/kaxwindowsattribute)
(documented as "an array of accessibility objects representing an application's windows").

```swift
import ApplicationServices

let appElement = AXUIElementCreateApplication(pid)   // pid_t from NSRunningApplication

var windowsValue: CFTypeRef?
let err = AXUIElementCopyAttributeValue(
    appElement,
    kAXWindowsAttribute as CFString,   // "AXWindows"
    &windowsValue
)
guard err == .success,
      let windows = windowsValue as? [AXUIElement] else { /* zero windows / not ready */ }
```

Rectangle does exactly this: it builds the app element from a pid
(`AXUIElementCreateApplication(pid)`) and reads windows via the `.windows` attribute
([Rectangle `AccessibilityElement.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift)).
`AXUIElementCopyAttributeValue` is the canonical read call
([Apple: `AXUIElementCopyAttributeValue`](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)).

### 1b. Wrap a CGPoint / CGSize in an AXValue

Position and size are not plain numbers to the AX API — they are opaque `AXValue` boxes created
with [`AXValueCreate`](https://developer.apple.com/documentation/applicationservices/axvaluecreate)
using the type constants
[`kAXValueTypeCGPoint` / `kAXValueTypeCGSize`](https://developer.apple.com/documentation/applicationservices/axvaluetype)
(older name `kAXValueCGPointType` / `kAXValueCGSizeType`).

```swift
func axValue(_ point: CGPoint) -> AXValue {
    var p = point
    return AXValueCreate(.cgPoint, &p)!   // kAXValueType.cgPoint
}
func axValue(_ size: CGSize) -> AXValue {
    var s = size
    return AXValueCreate(.cgSize, &s)!    // kAXValueType.cgSize
}
```

Rectangle's helper is the same shape — `setValue(_:CGPoint)` / `setValue(_:CGSize)` delegate to a
`setWrappedValue(..., .cgPoint / .cgSize)` that calls `AXValueCreate`, and reads unwrap via
`AXValueGetValue`
([Rectangle `Utilities/AXExtension.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Utilities/AXExtension.swift)).

### 1c. Set size, position, size — in that order — and why

```swift
func setFrame(_ window: AXUIElement, _ axRect: CGRect) {
    // 1. size first so the window can shrink to fit before moving
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue(axRect.size))
    // 2. move
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue(axRect.origin))
    // 3. size again — macOS clamps size to what fits at the *previous* position,
    //    so the first size may have been truncated
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue(axRect.size))
}
```

This double-set is taken directly from Rectangle's `setFrame(_:adjustSizeFirst:)`, whose own
comment is the authoritative rationale:

> "The Accessibility API only allows size & position adjustments individually. To handle moving to
> different displays, we have to adjust the size then the position, then the size again since macOS
> will enforce sizes that fit on the current display."

([Rectangle `AccessibilityElement.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift)).
`kAXPositionAttribute` and `kAXSizeAttribute` are the standard settable geometry attributes
([Apple: `kAXPositionAttribute`](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute),
[`kAXSizeAttribute`](https://developer.apple.com/documentation/applicationservices/kaxsizeattribute)),
set with
[`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue).

**The `AXEnhancedUserInterface` gotcha.** Apps built on certain toolkits (anything that has
VoiceOver's "enhanced UI" turned on — historically Electron/Chromium and some others) animate or
reject geometry changes, producing wrong final frames. Rectangle detects this by reading the
application element's `AXEnhancedUserInterface` attribute, temporarily setting it to `false` around
the `setFrame` call, and restoring it
([Rectangle `AccessibilityElement.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift)).
Worth replicating if any managed app misbehaves.

AeroSpace confirms the same public-API surface from a modern (2024+) codebase: it sets window
geometry through a single `setAxFrame(topLeft, size)` that writes `kAXPositionAttribute` /
`kAXSizeAttribute`, and it is emphatically **public AX only** apart from one private symbol
(`_AXUIElementGetWindow`) used purely to obtain a window id — irrelevant to placement
([AeroSpace `MacWindow.swift`](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/tree/MacWindow.swift),
[AeroSpace README](https://github.com/nikitabobko/AeroSpace)).

---

## 2. Coordinate systems — the flip (critical)

Two coordinate spaces are in play and they disagree on the y-axis:

| Space | Origin | y direction | Units | Spans displays? |
| --- | --- | --- | --- | --- |
| **`NSScreen.frame` / `visibleFrame`** (Cocoa) | **bottom-left** of the **primary** display | up | points | yes — secondary displays sit at ± offsets around primary |
| **Accessibility (`kAXPosition`)** | **top-left** of the **primary** display | down | points | yes — one global top-left plane |

Both are **global** planes anchored to the **primary display** (the one with the menu bar,
`NSScreen.screens[0]`), and both are in **points**. So converting a Cocoa rect (as you get from
`NSScreen`) to an AX rect is a **single y-flip about the primary display's height**, with **x
unchanged**:

```
ax.origin.x = cocoa.origin.x
ax.origin.y = primaryDisplayHeight − (cocoa.origin.y + cocoa.height)
            = NSScreen.screens[0].frame.maxY − cocoa.maxY
ax.size     = cocoa.size          // unchanged
```

This is **exactly** Rectangle's implementation (its `screenFlipped` on `CGRect`):

```swift
// Rectangle — Utilities/CGExtension.swift
var screenFlipped: CGRect {
    guard !isNull else { return self }
    return .init(
        origin: .init(x: origin.x, y: NSScreen.screens[0].frame.maxY - maxY),
        size: size
    )
}
```

([Rectangle `Utilities/CGExtension.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Utilities/CGExtension.swift)).
Rectangle applies this flip immediately before handing the rect to the AX setters
(`let normalizedRect = rect.screenFlipped` in
[`ScreenDetection.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/ScreenDetection.swift)).

AeroSpace does the identical thing, flipping against `mainMonitor.height` (again the **main/primary**
monitor, not the target one), with a code comment calling the bottom-left convention "crazy":

```swift
// AeroSpace — Sources/AppBundle/model/Rect.swift
extension CGRect {
    func monitorFrameNormalized() -> Rect {
        let mainMonitorHeight: CGFloat = mainMonitor.height
        let rect = toRect()
        return rect.copy(\.topLeftY, mainMonitorHeight - rect.topLeftY)
    }
}
```

([AeroSpace `Rect.swift`](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/model/Rect.swift),
[`Monitor.swift`](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/model/Monitor.swift)).

### Multi-display consequence

Because the flip reference is always the **primary** display's height (`screens[0].frame.maxY`),
the same formula works for a window on **any** display without special-casing. A secondary display
above the primary has a Cocoa `frame.origin.y` greater than the primary's height; a display below
has a negative `origin.y`. The subtraction against the primary height maps all of them into the one
top-left AX plane correctly. **Do not** flip against the target screen's own height — that is the
classic multi-monitor bug (see the widely-reported symptom that a full-screen window on a secondary
screen reads `y = -1080` in the Accessibility Inspector while `NSScreen` reports `y = 900`;
[Swindler issue #62](https://github.com/tmandry/Swindler/issues/62)).

### backingScaleFactor

`NSScreen.frame`/`visibleFrame` and the AX position/size attributes are both expressed in
**points**, not pixels. [`NSScreen.backingScaleFactor`](https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor)
(1.0 or 2.0 on Retina) only matters if you cross into **pixel** space — e.g. the `CGWindowList` /
screenshot APIs — which this feature does not. So `backingScaleFactor` does **not** appear in the
tiling math. (It is still worth reading once if you ever want to reason about physical pixels, but
placement is pure points.)

---

## 3. Computing the target rect from the grid

Use [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)
as the usable area: it is the screen rect **minus the menu bar and the Dock** (and, on notched
displays, the menu-bar inset), in Cocoa bottom-left coordinates. `frame` is the whole display; you
almost always want `visibleFrame` so tiles don't slide under the Dock or menu bar. Rectangle builds
on `visibleFrame` for exactly this reason (its `adjustedVisibleFrame()` starts from `visibleFrame`
and then subtracts optional gaps;
[Rectangle `ScreenDetection.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/ScreenDetection.swift)).

The feature's model = **(fraction grid) + (occupied cell span)**. Let the usable area be
`v = screen.visibleFrame`, with `hDiv` horizontal columns (2 = halves, 3 = thirds, 4 = fourths) and
`vDiv` vertical rows (1 = full, 2 = halves, …, 4 = fourths). A tile occupies columns
`[col0, col1]` and rows `[row0, row1]` (0-based, inclusive spans).

```swift
let colW = v.width  / CGFloat(hDiv)
let rowH = v.height / CGFloat(vDiv)

// Cocoa (bottom-left) target rect. Rows are indexed from the TOP for a natural
// "first row = top" UX, so convert to a bottom-left y here:
let x      = v.minX + CGFloat(col0) * colW
let width  = CGFloat(col1 - col0 + 1) * colW
let height = CGFloat(row1 - row0 + 1) * rowH
let yTopDown = CGFloat(row0) * rowH                 // distance from top of visibleFrame
let y      = v.maxY - yTopDown - height             // Cocoa bottom-left y within the display

var cocoaRect = CGRect(x: x, y: y, width: width, height: height)
// then: let axRect = cocoaRect.screenFlipped   (Section 2)
```

Worked examples (screen usable area `v`):

- **"Halves, first half, vertically full"** (Comet): `hDiv=2, col0=col1=0, vDiv=1, row0=row1=0`
  → `x=v.minX, width=v.width/2, full height` → **left 50%**.
- **"Halves, last half, vertically full"** (Conductor): `hDiv=2, col0=col1=1`
  → `x=v.minX + v.width/2, width=v.width/2` → **right 50%**.
- **"Thirds, last third"**: `hDiv=3, col0=col1=2` → `x=v.minX + 2·(v.width/3), width=v.width/3`.
- **"Fourths, span first two columns"**: `hDiv=4, col0=0, col1=1`
  → `width = 2·(v.width/4) = v.width/2`.
- **Vertical split** (top half): `vDiv=2, row0=row1=0` → top `v.height/2`.

**Optional gaps/padding** are a simple inset applied after computing the tile
(`cocoaRect.insetBy(dx: gap/2, dy: gap/2)` for inner gaps, or subtract an outer margin from `v`
first). Rectangle exposes exactly these as configurable screen-edge and inter-window gaps in
`adjustedVisibleFrame()`
([`ScreenDetection.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/ScreenDetection.swift)).
For an MVP this is optional; edge-to-edge tiling is fine.

Rounding: round the final rect to integer points to avoid sub-point seams between adjacent tiles
(e.g. `col1`'s left edge should equal `col0`'s computed right edge — compute edges from the same
`colW` multiplications, not by adding widths, so cumulative rounding doesn't drift).

---

## 4. Identifying the right window(s) per app

The app's identity in the config is a **bundle identifier**; the AX API needs a **pid**. Bridge via
[`NSRunningApplication`](https://developer.apple.com/documentation/appkit/nsrunningapplication):

```swift
let running = NSRunningApplication
    .runningApplications(withBundleIdentifier: "com.example.Comet")   // may be several
for app in running {
    let pid = app.processIdentifier
    let appElement = AXUIElementCreateApplication(pid)
    // ... read kAXWindowsAttribute (Section 1a)
}
```

Then filter the window list to real, placeable windows:

- **Role / subrole.** Keep only windows whose
  [`kAXRoleAttribute`](https://developer.apple.com/documentation/applicationservices/kaxroleattribute)
  is `kAXWindowRole` (`"AXWindow"`) and whose
  [`kAXSubroleAttribute`](https://developer.apple.com/documentation/applicationservices/kaxsubroleattribute)
  is `kAXStandardWindowSubrole` (`"AXStandardWindow"`). This drops panels, popovers, sheets
  (`AXDialog`/`AXSystemDialog`), and toolbars. (Role/subrole constants live in Apple's
  [`AXRoleConstants.h`](https://developer.apple.com/documentation/applicationservices/axroleconstants_h).)
- **Minimized.** Skip windows whose
  [`kAXMinimizedAttribute`](https://developer.apple.com/documentation/applicationservices/kaxminimizedattribute)
  is `true` — you cannot meaningfully place a minimized window (and setting geometry may un-minimize
  or no-op). Either skip, or un-minimize first if the layout should reclaim it.
- **Zero windows.** A freshly launched app often has **no** windows for a short window of time
  (`kAXWindowsAttribute` returns an empty array, or `AXUIElementCopyAttributeValue` returns
  `.cannotComplete`/`.apiDisabled`). Handle by retrying briefly, or by placing on the app's
  `didActivateApplicationNotification` / on a `kAXWindowCreated` AX notification rather than
  immediately at `didLaunch`.
- **Multiple windows.** Decide a policy: place only the **main/frontmost** window
  (`kAXMainWindowAttribute` / `kAXFocusedWindowAttribute` on the app element), or place the first
  standard window, or apply the same rect to all standard windows. For this feature — one region per
  app per Desktop — placing the **frontmost standard window** is the sane default; stacking N windows
  into one region is a later refinement.

Both Rectangle and AeroSpace do this role/subrole + main-window filtering before placing
([Rectangle `AccessibilityElement.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift);
AeroSpace's window model in
[`Window.swift`](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/tree/MacWindow.swift)).

---

## 5. Which Desktop / when to apply

**The hard constraint (from `macos-app-stack.md`, restated as it drives the design):** the
Accessibility API operates only on windows in the **currently-active Space**. There is no AX way to
address or place a window that lives on an inactive Desktop, and no AX way to move a window to
another Desktop. So the per-Desktop layout is a **desired state that can only be *enacted* while its
Desktop is the active Space.**

This dovetails with the app's existing model: the **Assignment** already guarantees (via the
`com.apple.spaces` binding) that Comet's windows *open* on Desktop 3. The **layout** then just needs
a moment when Desktop 3 is active to place those windows into their region. Good trigger points:

- **App launch** —
  [`NSWorkspace.didLaunchApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didlaunchapplicationnotification).
  The `userInfo` carries the `NSRunningApplication`. Because the binding makes the app open on its
  assigned Desktop, if that Desktop is (or becomes) active the new window can be tiled. Expect a
  short delay before windows exist (Section 4) — observe `kAXWindowCreated` or retry.
- **App activation** —
  [`NSWorkspace.didActivateApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification).
  Fires when the app comes to the front, at which point its windows are on the active Space; a
  natural, low-surprise moment to (re-)assert the layout.
- **Active-Space change** — there is no clean *public* notification for "the active Space changed"
  beyond `NSWorkspace.activeSpaceDidChangeNotification`
  ([Apple](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)),
  which fires when the user switches Desktops. On that event you can re-tile whatever managed apps
  are now visible. (It does not tell you *which* Space by number — you infer it from what's
  frontmost / what windows are now enumerable.)
- **Global hotkey / "Re-tile now" menu action** — the most predictable trigger for a personal tool:
  the user is on the Desktop they want tiled and asks for it explicitly. This side-steps all the
  timing/active-Space ambiguity and is the recommended MVP entry point, matching how Rectangle
  (shortcut-driven) and AeroSpace (command-driven, idempotent enforcement) work.

**Recommended approach:** treat the stored layout as *idempotent desired state* (the same philosophy
as the existing Apply → bindings flow, and as AeroSpace's "owner of the state … enforces positions
in an idempotent style"). Provide an explicit **"Re-tile this Desktop"** action for the MVP, and
*optionally* auto-apply on `didActivate`/`didLaunch` for managed apps whose assigned Desktop is
currently active. Never try to place windows for an inactive Desktop — it cannot work.

---

## 6. Permissions & the windows that won't move

### Accessibility permission

All of Section 1 requires the app to be a trusted Accessibility client. Prompt with
[`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
passing
[`kAXTrustedCheckOptionPrompt`](https://developer.apple.com/documentation/applicationservices/kaxtrustedcheckoptionprompt)
`= true`, which shows the system prompt and opens
System Settings → Privacy & Security → Accessibility:

```swift
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
```

([`AXIsProcessTrusted()`](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted)
is the no-prompt variant for silent re-checks.) The user must toggle the app on **manually**; the
grant typically takes effect without relaunch on modern macOS but historically required a restart —
re-check with `AXIsProcessTrusted()` before each apply and surface a clear "grant Accessibility
access" state in the UI. This is the *same* permission this app already needs; no new entitlement.
Unsandboxed personal build → no App Store review concerns (per `macos-app-stack.md`).

### Windows that refuse geometry

Some windows can't be resized or moved as requested:

- **Fixed-size windows** (e.g. some preference/utility windows) — the app ignores or clamps
  `kAXSizeAttribute`; position may still work.
- **Native full-screen windows** — a window in macOS full-screen is on its **own** full-screen
  Space; AX geometry setting is effectively inert. Detect via
  [`kAXFullscreenAttribute`](https://developer.apple.com/documentation/applicationservices/kaxfullscreenattribute)
  (`"AXFullScreen"`) and skip.
- **Sheets / dialogs / panels** — filtered out already by the subrole check (Section 4).

`AXUIElementSetAttributeValue` returns an
[`AXError`](https://developer.apple.com/documentation/applicationservices/axerror) — `.success`,
`.cannotComplete`, `.attributeUnsupported`, `.illegalArgument`, etc. But a `.success` return does
**not** guarantee the app honored the value (it may clamp silently). The robust pattern — which
**mirrors this codebase's existing read-back verification** in `MacOSSpacesAdapter.apply(...)`
(it re-reads `app-bindings` and throws `verificationFailed` if the store doesn't match) — is:

> after `setFrame`, **read `kAXPosition`/`kAXSize` back** and compare to the target within a small
> tolerance; if it didn't take, mark that window/app as "couldn't tile" and report it rather than
> pretending success.

Rectangle applies changes then leaves it; a personal tool that already values verification should
read back and report, keeping UX honest about which apps resisted.

---

## 7. Data-model suggestion (aligned with the existing `Assignment` concept)

The current source of truth is `ManagedApplication` (bundle id + display name + `desktopNumber`),
persisted in `DeskLayouterConfiguration`, with `BoardState` tracking pending-vs-applied
([`Configuration.swift`](../../Sources/DeskLayouterCore/Configuration.swift),
[`BoardState.swift`](../../Sources/DeskLayouterCore/BoardState.swift)). A layout is a *second facet*
of the same per-(app, Desktop) rule, so it belongs on `ManagedApplication` as an **optional**
field — absent = "assigned but not tiled" (today's behavior), preserving backward compatibility.

```swift
/// A rectangular region of a Desktop's usable screen, expressed as a fraction
/// grid plus the cell span the app occupies. Pure value type, no AppKit.
public struct DesktopLayout: Codable, Equatable, Sendable {
    public var horizontalDivisions: Int   // 2 = halves, 3 = thirds, 4 = fourths
    public var verticalDivisions: Int      // 1 = full, 2 = halves, … 4 = fourths
    public var columnStart: Int            // 0-based, inclusive
    public var columnEnd: Int              // 0-based, inclusive (== start for a single cell)
    public var rowStart: Int               // 0-based from the TOP
    public var rowEnd: Int
    // Optional, deferrable to a later iteration:
    // public var innerGap: CGFloat
    // public var outerMargin: CGFloat
}

public struct ManagedApplication: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public var desktopNumber: Int
    public var layout: DesktopLayout?      // nil = assigned only, not tiled
}
```

Notes to keep it consistent with the existing architecture:

- **Optional + tolerant decoding.** Follow the existing pattern (`decodeIfPresent` in
  `DeskLayouterConfiguration.init(from:)` / `BoardState`): a config written before layouts existed
  decodes with `layout = nil`. No migration needed.
- **One layout per (app, Desktop).** `upsert(_:)` already keeps one `ManagedApplication` per bundle
  id / one Desktop per app; the layout rides along on that same record — no new keying.
- **Validation belongs in Core, not the adapter.** Keep `columnStart ≤ columnEnd < horizontalDivisions`
  (and the row equivalents) enforced in the pure `DeskLayouterCore` model, mirroring how the
  planner/model own correctness and the adapter owns only macOS specifics (ADR-0001).
- **Pending/applied.** If the board should show "layout changed, not yet re-tiled," extend the
  `appliedBaseline` diffing in `BoardState` to include the layout (or a hash of it) alongside
  `desktopNumber`. For an MVP where tiling is triggered explicitly ("Re-tile now"), you may not need
  pending-state for layouts at all — the action just enacts current desired state.
- **Vocabulary.** Per `CONTEXT.md`, prefer "Desktop" and "usable area of the Desktop's screen" in
  UI/comments; reserve "Space"/"Screen"/"Monitor" for internal/API discussion. "Layout" is a new
  term to add to the language doc (the tiled arrangement of an app within its Desktop), distinct
  from **Assignment** (which Desktop it opens on) and **Apply** (writing bindings). Consider whether
  re-tiling should be folded into the existing **Apply** verb or be its own verb (e.g. "Arrange") —
  Apply currently means "write to the Spaces store + restart Dock," which is a different mechanism
  than AX window placement, so a distinct verb is cleaner.

---

## Sources

Apple Developer documentation (primary):
- [`AXUIElementCreateApplication`](https://developer.apple.com/documentation/applicationservices/1462075-axuielementcreateapplication)
- [`AXUIElementCopyAttributeValue`](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)
- [`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
- [`AXValueCreate`](https://developer.apple.com/documentation/applicationservices/axvaluecreate) · [`AXValueType`](https://developer.apple.com/documentation/applicationservices/axvaluetype) · [`AXError`](https://developer.apple.com/documentation/applicationservices/axerror)
- [`kAXWindowsAttribute`](https://developer.apple.com/documentation/applicationservices/kaxwindowsattribute) · [`kAXPositionAttribute`](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute) · [`kAXSizeAttribute`](https://developer.apple.com/documentation/applicationservices/kaxsizeattribute)
- [`kAXRoleAttribute`](https://developer.apple.com/documentation/applicationservices/kaxroleattribute) · [`kAXSubroleAttribute`](https://developer.apple.com/documentation/applicationservices/kaxsubroleattribute) · [`AXRoleConstants.h`](https://developer.apple.com/documentation/applicationservices/axroleconstants_h) · [`kAXMinimizedAttribute`](https://developer.apple.com/documentation/applicationservices/kaxminimizedattribute) · [`kAXFullscreenAttribute`](https://developer.apple.com/documentation/applicationservices/kaxfullscreenattribute)
- [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) · [`kAXTrustedCheckOptionPrompt`](https://developer.apple.com/documentation/applicationservices/kaxtrustedcheckoptionprompt) · [`AXIsProcessTrusted()`](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted)
- [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe) · [`NSScreen.frame`](https://developer.apple.com/documentation/appkit/nsscreen/frame) · [`NSScreen.backingScaleFactor`](https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor)
- [`NSRunningApplication`](https://developer.apple.com/documentation/appkit/nsrunningapplication)
- [`NSWorkspace.didLaunchApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didlaunchapplicationnotification) · [`didActivateApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification) · [`activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)

Open-source window managers (primary source for concrete technique):
- Rectangle — [`AccessibilityElement.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift) (create app element, get windows, `setFrame` size→position→size, EnhancedUserInterface), [`Utilities/AXExtension.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Utilities/AXExtension.swift) (AXValueCreate/AXValueGetValue helpers), [`Utilities/CGExtension.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Utilities/CGExtension.swift) (`screenFlipped` y-flip), [`ScreenDetection.swift`](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/ScreenDetection.swift) (`adjustedVisibleFrame`, gaps)
- AeroSpace — [`MacWindow.swift`](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/tree/MacWindow.swift) (`setAxFrame`), [`Rect.swift`](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/model/Rect.swift) / [`Monitor.swift`](https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/model/Monitor.swift) (`monitorFrameNormalized` flip against main monitor), [README](https://github.com/nikitabobko/AeroSpace) (public-AX-only, idempotent enforcement)
- Amethyst — [ianyh/Amethyst](https://github.com/ianyh/Amethyst) (tiling within native Spaces via AX; geometry delegated to the Silica framework)
- [Swindler issue #62](https://github.com/tmandry/Swindler/issues/62) — multi-display AX-vs-NSScreen y-coordinate mismatch symptom

Internal (repo) references:
- [`docs/research/macos-app-stack.md`](./macos-app-stack.md) — AX is current-Space-only; Spaces assignment is settled
- [`Sources/DeskLayouterCore/Configuration.swift`](../../Sources/DeskLayouterCore/Configuration.swift), [`BoardState.swift`](../../Sources/DeskLayouterCore/BoardState.swift) — `ManagedApplication` / `DeskLayouterConfiguration` model & tolerant decoding
- [`Sources/DeskLayouter/SpacesAdapter.swift`](../../Sources/DeskLayouter/SpacesAdapter.swift) — existing read-back verification pattern to mirror for AX placement
- [`Sources/DeskLayouter/AppDelegate.swift`](../../Sources/DeskLayouter/AppDelegate.swift) — menu-bar agent, display-reconfiguration observation
