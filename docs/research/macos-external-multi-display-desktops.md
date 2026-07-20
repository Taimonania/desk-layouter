# External and multiple-display Desktop Assignments on macOS

Date: 2026-07-20  
Test host: macOS 26.5.2 (25F84), Apple-silicon MacBook Pro, lid closed, one external DELL S3423DWC

## Recommendation

Ship external-only support as a deliberately small first step: target the **one active logical display**, regardless of whether it is built in or external. When there is one extended display with the laptop lid closed, that display is the macOS main display and its live Spaces monitor is represented by the private store key `"Main"`. Keep the existing `desktopNumber` configuration unchanged. If more than one non-mirrored display is active, fail with an explicit “multiple displays are not supported yet” message instead of silently choosing one.

For later multiple-display support, model an Assignment as **application → (display identity, Desktop number)**. Persist the display's ColorSync UUID plus presentation/recovery metadata, never a `CGDirectDisplayID` or the private string `"Main"`. At every refresh or Apply, resolve the current physical display to the current private monitor key: `"Main"` when that display is currently main, otherwise its ColorSync UUID string. Treat mirrored displays as one logical display. Per-display destinations should require **Displays have separate Spaces**; without it, Desk Layouter can offer only one shared Desktop set and cannot promise a particular screen.

This design keeps private plist vocabulary inside the macOS adapter and prevents a main-display change, display rearrangement, or lid transition from silently changing the user's persisted intent.

## Why the app fails with the lid closed

The failure is deterministic in the current adapter:

1. `currentDesktopSnapshot()` first calls `builtInDisplayIdentifier()`.
2. That method enumerates active displays and requires one for which `CGDisplayIsBuiltin` is true.
3. With the lid closed, the internal panel is not an active drawable display, so the only active display is external and the method throws `builtInDisplayNotFound` before reading any Desktop.

See [`SpacesAdapter.swift`](../../Sources/DeskLayouter/SpacesAdapter.swift#L58-L110). Apple defines `CGGetActiveDisplayList` as the list of displays active for drawing and `CGDisplayIsBuiltin` as identifying an internal display. Apple also notes that a closed-lid Mac laptop uses its external display when connected to power with an external keyboard and mouse. [Apple: `CGGetActiveDisplayList`](https://developer.apple.com/documentation/coregraphics/cggetactivedisplaylist%28_%3A_%3A_%3A%29), [Apple: closed-lid external-display requirements](https://support.apple.com/en-ie/102501)

The board and error strings repeat the same built-in-only assumption in [`EditorModel.swift`](../../Sources/DeskLayouter/EditorModel.swift#L107-L120) and [`EditorView.swift`](../../Sources/DeskLayouter/EditorView.swift#L91-L100). The real-system harness also asks its helper for `--built-in-display-identifier`, so it currently skips/fails in this topology rather than proving external-only placement; see [`verify-desktop-placement.sh`](../../Scripts/verify-desktop-placement.sh#L169-L195).

## Facts from public Apple interfaces

- `CGDirectDisplayID` identifies an attached display for the current display system. It is suitable for querying live state, not as the persisted product identity. `CGGetActiveDisplayList` returns drawable displays with the main display first. In hardware mirroring only the primary is active; in software mirroring all mirrored displays can be active. [Apple: `CGGetActiveDisplayList`](https://developer.apple.com/documentation/coregraphics/cggetactivedisplaylist%28_%3A_%3A_%3A%29)
- `CGMainDisplayID()` identifies the display at global origin `(0,0)`; without mirroring it is normally the display with the menu bar. Users can relocate the menu bar and choose which display is main in Displays settings, so “main” is a role, not a physical identity. [Apple: `CGMainDisplayID`](https://developer.apple.com/documentation/coregraphics/cgmaindisplayid%28%29), [Apple: Displays settings](https://support.apple.com/en-gb/guide/mac-help/mh40768/mac)
- `CGDisplayCreateUUIDFromDisplayID` and its reverse conversion are public ColorSync APIs. They provide the strongest direct bridge available here between a live display ID and a UUID-shaped identifier. Apple does **not** document a persistence guarantee for this UUID across docks, adapters, OS reinstalls, or monitor firmware changes, so it should be treated as the primary match key with a recoverable “display unavailable” path, not as an infallible hardware serial. [Apple: `CGDisplayCreateUUIDFromDisplayID`](https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid%28_%3A%29), [Apple: `CGDisplayGetDisplayIDFromUUID`](https://developer.apple.com/documentation/colorsync/cgdisplaygetdisplayidfromuuid%28_%3A%29)
- `NSScreen.localizedName` is appropriate presentation text. `NSScreen.screensHaveSeparateSpaces` directly reflects the Mission Control **Displays have separate Spaces** setting. It is display configuration, not an identity. [Apple: `NSScreen`](https://developer.apple.com/documentation/appkit/nsscreen), [Apple: `screensHaveSeparateSpaces`](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces)
- Apple says **Displays have separate Spaces** gives each display its own Spaces. With it off, the Dock is only on the main display; with it on, the Dock is available on all displays. Apple's supported Dock assignment UI can target “Desktop on Display [number]” when multiple displays are available. [Apple: Desktop & Dock settings](https://support.apple.com/guide/mac-help/mchlp1119/mac), [Apple: Work in multiple spaces](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/26/mac/26)
- Users may extend, mirror, rearrange, and change the main display. Mirroring shows the same desktop content on each display, so mirrored panels are not independent Assignment destinations. Core Graphics exposes mirror membership and the primary display. [Apple: extend or mirror displays](https://support.apple.com/en-au/guide/mac-help/-mchlb5f905a1/mac), [Apple: `CGDisplayIsInMirrorSet`](https://developer.apple.com/documentation/coregraphics/cgdisplayisinmirrorset%28_%3A%29), [Apple: hardware mirroring](https://developer.apple.com/documentation/coregraphics/cgdisplayisinhwmirrorset%28_%3A%29)
- Display topology can change at runtime. `CGDisplayRegisterReconfigurationCallback` reports connection, removal, main-display, mirroring, mode, and arrangement changes; after the post-change callback, Core Graphics state is current. [Apple: display reconfiguration callback](https://developer.apple.com/documentation/coregraphics/cgdisplayreconfigurationcallback), [Apple: registration](https://developer.apple.com/documentation/coregraphics/cgdisplayregisterreconfigurationcallback%28_%3A_%3A%29)
- Desktop numbers remain positional. macOS can automatically rearrange Spaces based on recent use. Desk Layouter should continue resolving the ordinal against a fresh snapshot at Apply time and should warn users that enabling automatic rearrangement changes what “Desktop 2” means. [Apple: Desktop & Dock settings](https://support.apple.com/guide/mac-help/mchlp1119/mac)

The installed macOS 26 SDK headers were cross-checked as a first-party local source: `CGDirectDisplay.h` documents active versus online display enumeration, main-first ordering, bounds, and hardware-mirror behavior; `CGDisplayConfiguration.h` documents active/main/built-in/mirror queries and reconfiguration callbacks; `NSScreen.h` documents `screensHaveSeparateSpaces`, `localizedName`, and the macOS 26 direct display ID property; and `ColorSyncDevice.h` declares the display-ID/UUID conversion pair. The online Apple documentation linked above agrees with those headers.

## Read-only observations from this Mac

These are observations, not public contracts. They were collected without changing display or Spaces state.

The live display inventory was:

```text
CGDirectDisplayID: 3
main: true
built-in: false
active: true
mirrored: false
ColorSync UUID: B173FA83-AFFB-4C9B-B03A-F57BA529EFF1
NSScreen.localizedName: DELL S3423DWC
bounds: (0, 0, 3440, 1440)
NSScreen.screensHaveSeparateSpaces: true
```

The exported `com.apple.spaces` store had one live monitor with a `Spaces` array:

```text
Display Identifier = Main
Desktop UUIDs = ["", "0B4DE213-…", "4A558970-…"]
```

It also had a historical/collapsed monitor entry whose `Display Identifier` was the external monitor's ColorSync UUID (`B173FA83-…`), but that entry had only `Collapsed Space`, not `Spaces`. Therefore matching the current main display by its UUID would select the wrong record. Matching it by the logical alias `"Main"` selects the live Spaces.

The existing Desk Layouter board has ten clean Assignments to Desktops 1–3, and the current `app-bindings` values match the three UUID values in the live `Main` monitor (Desktop 1 uses the empty string representation). This strongly suggests that merely replacing the built-in-only selection with the one-active/main selection will preserve the user's current layout; no configuration migration is needed for the external-only increment.

The host currently reports `mru-spaces = 0`, consistent with automatic Space rearrangement being disabled, and `screensHaveSeparateSpaces = true`.

Reproduction commands (read-only):

```sh
system_profiler SPDisplaysDataType -json
defaults export com.apple.spaces - \
  | plutil -convert json -o - -- - \
  | jq '.SpacesDisplayConfiguration["Management Data"].Monitors'
defaults read com.apple.dock mru-spaces
```

## Inferences about the private Spaces schema

Nothing under `SpacesDisplayConfiguration`, including `Management Data`, `Monitors`, `Display Identifier`, `Spaces`, `Collapsed Space`, `TileLayoutManager`, or the special `"Main"` value, is a documented Apple API. The following rules are therefore adapter hypotheses that require real-system tests on every supported macOS version:

1. A live main display's monitor is keyed by `"Display Identifier" = "Main"`.
2. A live non-main display with separate Spaces is keyed by the string returned from `CGDisplayCreateUUIDFromDisplayID`.
3. Entries with only `Collapsed Space` are retained history/inactive-display state and must not be treated as current Desktop lists.
4. A monitor is eligible only when it has a `Spaces` array. Desktop order is the array order; entries carrying `TileLayoutManager` are excluded as non-Desktop Spaces, matching the existing adapter.
5. Changing which physical display is main probably changes which live record uses the `"Main"` alias. Whether macOS moves, rewrites, or remints any Space UUIDs during every possible main-display, lid, or hot-plug transition is not established.

The current implementation already contains rules 1, 2, and 4 for the built-in display, which is evidence that this mapping was previously observed, but it is not documentation; see [`SpacesAdapter.swift`](../../Sources/DeskLayouter/SpacesAdapter.swift#L58-L110).

### Meaning and risk summary

| Value | What it is | Persist it? | Main risk |
|---|---|---:|---|
| `CGDirectDisplayID` | Public live handle for an attached display | No | Runtime/topology-scoped; removed IDs become invalid |
| `CGMainDisplayID()` | Public lookup of the current main-display role | No | Role changes when the user changes arrangement/main display |
| ColorSync display UUID | Public conversion from a live display ID | Yes, cautiously | Apple documents conversion, not long-term stability |
| `NSScreen.localizedName` | Public display label | Only as metadata | Not guaranteed unique or stable |
| vendor/model/serial | Public I/O Kit-derived monitor metadata | As recovery metadata | Serial may be zero; identical monitors can be ambiguous ([Apple: serial-number semantics](https://developer.apple.com/documentation/coregraphics/cgdisplayserialnumber%28_%3A%29)) |
| private `Display Identifier = "Main"` | Observed live-store alias for the main display | No | Logical alias, not physical identity; undocumented schema |
| private `Display Identifier = UUID` | Observed private-store key for non-main or collapsed physical display | No, outside adapter | Can refer to collapsed history; undocumented schema |
| display bounds/origin | Public current arrangement | No | User can rearrange displays without changing their identity |

## Minimal external-only implementation

The first increment can stay intentionally single-display and retain the current domain/configuration.

1. Introduce an injectable display-inventory seam that enumerates active displays, their main/built-in/mirror state, ColorSync UUID, name, and bounds.
2. Collapse a mirror set to one logical display. If exactly one logical display remains, select the live private monitor with `Display Identifier == "Main"` and a `Spaces` array. If no display exists, enumeration fails, or more than one extended logical display exists, return a specific non-mutating error.
3. Rename built-in-specific adapter errors, comments, editor strings, and empty states to “active display”; show the display's localized name in the board header if useful.
4. Keep `ManagedApplication.desktopNumber`, `DesktopSnapshot`, `AssignmentPlanner`, BoardState JSON, and pending baselines unchanged. Existing Assignments continue to mean Desktop N on the one active display.
5. Change both real-system harnesses and the probe from “built-in display” to “single active/main display”. Run the placement harness on the current closed-lid external topology before claiming support.
6. Listen for display reconfiguration while the editor is open, debounce, and refresh the topology/store. Disable Apply while topology is changing. For the smallest safe version, a post-change refresh can also occur whenever the editor is shown and immediately before Apply.

This scope supports all three useful single-logical-display forms: built-in only, external only with the lid closed, and mirrored displays. It deliberately rejects two extended displays until the destination has a display dimension.

## Robust multiple-display model

### Domain and persistence

Keep the user language “Display” for physical screens and “Desktop” for Spaces. Suggested values:

```text
DisplayIdentity
  colorSyncUUID: String
  lastKnownName: String
  vendorID/modelID/serialNumber: optional recovery metadata

DesktopAddress
  display: DisplayIdentity
  desktopNumber: Int               # still 1-based and positional

Assignment
  bundleIdentifier: String
  destination: DesktopAddress
```

Runtime-only adapter values should be separate:

```text
ActiveDisplay
  cgDirectDisplayID                # ephemeral
  identity, localizedName
  isMain, isBuiltIn, bounds
  mirrorPrimaryID/mirror members
  privateMonitorIdentifier         # derived: "Main" or UUID

DisplayDesktopSnapshot
  topologyFingerprint
  displays: [ResolvedDisplay: [ordered Desktop UUIDs]]
  separateSpaces: Bool
```

`app-bindings` remains bundle ID → one Space UUID, so one application can have only one effective destination across all displays. Moving a card between displays replaces its previous destination; this is consistent with Apple's Dock assignment being a single choice, not a per-display set.

Do not let private `"Main"` leak into JSON. Resolve a persisted physical UUID on every snapshot:

- matching active display is main → require the live `"Main"` monitor with `Spaces`;
- matching active display is non-main → require its UUID monitor with `Spaces`;
- no unique match → mark the display unavailable and do not guess from name alone.

For recovery, a nonzero `(vendor, model, serial)` match can be offered to the user for confirmation. Do not silently auto-match zero/missing serials or duplicate monitors.

### Apply and unavailable destinations

Topology changes introduce an important ownership distinction absent from the current reconciler:

- **Explicitly removed Assignment:** delete its managed `app-bindings` key.
- **Connected display, deleted/out-of-range Desktop:** retain the existing “skip safely” policy only if that remains a deliberate product choice; surface the stale card rather than hiding it.
- **Disconnected/unresolved display:** preserve the Assignment in Desk Layouter and preserve its existing macOS binding; do not reinterpret Desktop N on another display and do not delete the binding merely because the destination is temporarily offline.

The current adapter deletes any owned key omitted from `managedBindings`, so multi-display Apply needs an explicit plan/result such as `updates`, `deletions`, and `preservations`. See [`AssignmentPlanner`](../../Sources/DeskLayouterCore/DeskLayouterCore.swift#L26-L57) and the ownership merge in [`SpacesAdapter.swift`](../../Sources/DeskLayouter/SpacesAdapter.swift#L123-L145).

Capture a topology fingerprint with the snapshot and revalidate it immediately before the first persistent mutation. If active displays, main role, mirroring, separate-Spaces mode, monitor keys, or Desktop UUID order changed, abort without writing and ask the user to review/retry. This extends ADR-0001's existing fail-closed principle to display races.

### UI

- With one logical display, keep today's board and show a small display label.
- With multiple extended displays and separate Spaces on, show one board section/tab per physical display, ordered visually from `CGDisplayBounds` (top-to-bottom, then left-to-right), with **Main** as a badge rather than identity. Each section contains that display's Desktop columns.
- Allow dragging a card between Desktops and across display sections; keyboard movement needs an explicit “Move to…” menu because left/right display geometry is not a reliable accessibility order.
- Show disconnected saved displays as an “Unavailable displays” section with disabled cards and a Reassign action.
- If separate Spaces is off, show one shared Desktop board and explain that an Assignment can select a Desktop but not a particular display. Do not render misleading per-display columns.
- If displays are mirrored, show one logical board labelled with the mirror group (for example, “DELL + Built-in Display — Mirrored”).
- On hot-plug/lid/main-display changes, refresh after the post-change notification and show a transient “Displays changed; review before Apply” state. Preserve pending edits.

### Migration

The external-only increment requires no JSON migration. The later multi-display schema does.

Recommended tolerant decoder: missing `display` means a legacy Assignment. Resolve legacy values only when the topology is unambiguous:

- one logical display → attach all legacy Assignments to that display identity;
- multiple displays with an active built-in display → default to built-in to preserve the old product promise, but show a one-time review screen;
- multiple displays without an active built-in display → default to current main only with explicit user confirmation.

Do not mark migrated values applied or overwrite the board file until the user confirms the destination. The applied baseline must change from `[bundleID: desktopNumber]` to `[bundleID: DesktopAddress]`, or a display move will not register as pending.

An alternative product choice is a semantic **Follow Main Display** destination. It makes docking/lid transitions effortless, but it intentionally moves Assignments when the user changes the main display. That should be an explicit selectable mode, not the hidden meaning of a persisted `"Main"` string.

## Verification matrix

### Pure/unit and adapter-fixture tests

| Area | Cases |
|---|---|
| Active inventory | one built-in main; one external main; zero displays/error; two extended displays; main not first in an injected list |
| Mirror normalization | hardware mirror (only primary active); software mirror (multiple active IDs); mixed extended + mirrored group |
| Private-store resolver | main → live `Main`; non-main → UUID; UUID collision with collapsed entry; missing `Spaces`; duplicate eligible monitor; filtered `TileLayoutManager`; empty Desktop UUID remains valid |
| Planner | same ordinal on two displays resolves to different Space UUIDs; cross-display move; unavailable display; stale ordinal; one app still yields one binding |
| Reconciliation | update, explicit removal, disconnected-display preservation, unmanaged preservation, private-ABI preflight remains first |
| Topology race | main/display/Spaces order changes between snapshot and mutation → no write, no Dock restart |
| Persistence | old JSON with no display; new address round-trip; baseline detects display-only move; unresolved migration is not saved/applied |
| UI state | one display; multi-display sections; shared Spaces; mirror group; disconnected display; hot-plug preserves pending changes |

### Real-system matrix

1. Built-in display only (regression).
2. External display only, lid closed — the current requested topology.
3. Built-in + external extended, separate Spaces on; test each display as main.
4. Apply to Desktop 2 on each physical display, fully quit probe apps, launch from other Desktops, and inspect actual window Space membership.
5. Move an Assignment across displays, remove one Assignment, and prove unmanaged bindings remain untouched.
6. Connect, disconnect, and reconnect the external display; close/open the lid; change the main display; Apply must either resolve the same physical destination or fail without mutation.
7. Add/delete/reorder Desktops independently on each display; test with automatic rearrangement both off and on.
8. Mirror/unmirror; hardware and software mirroring if the hardware permits.
9. Turn separate Spaces off/on (including any login boundary macOS requires) and verify the UI/product guarantees change accordingly.
10. Logout/login with an external-target binding to confirm session reconstruction for that topology, as was already done for built-in-only Assignments in ADR-0001.

Every real-system test must remain transactional: snapshot `com.apple.spaces`, current active Space(s), display topology, and unmanaged bindings; restore all changed binding state and terminate disposable probes even on failure. Avoid automating display-mode/settings changes until a separate reversible harness exists.

## Decisions still needed before multi-display implementation

1. Should an Assignment normally follow a **physical display** (recommended) or the **Main display role**? Should “Follow Main Display” be offered explicitly?
2. When a saved display is disconnected, should Apply preserve its last macOS binding (recommended) or remove it?
3. For legacy Assignments first opened with two displays, is built-in + review the acceptable default, or should migration always block for a choice?
4. When **Displays have separate Spaces** is off, should Desk Layouter support the shared Desktop set or require the setting to be enabled?
5. Is changing the Mission Control “Automatically rearrange Spaces” option out of scope, a warning, or a hard prerequisite? A warning is the least invasive choice.

## Bottom line

The current external-only problem is not a limitation of `app-bindings`; it is the adapter's explicit search for an **active built-in** display. On this machine, the closed-lid external display already owns the live `Main` Spaces and all current bindings point into that Desktop list. A narrowly scoped one-logical-display change should therefore be small, migration-free, and directly testable now. Multiple displays are a separate domain expansion because a Desktop number is no longer a complete destination.
