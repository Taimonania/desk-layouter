# Building a native macOS "app-to-Desktop" utility (2026)

Research on tech stack, and on what is actually possible for programmatically assigning
apps to Spaces/Desktops and placing windows on macOS, for a personal (non–App Store)
menu-bar utility.

---

## Recommendation / TL;DR

- **Stack:** Swift + **AppKit** for the app shell (menu-bar `LSUIElement` agent), with SwiftUI
  only for any settings window. Native, tiny, first-class access to `NSWorkspace`,
  Accessibility, and private frameworks. Skip Electron/Tauri — they add a runtime and give
  you *no* extra ability to control Spaces (they'd still shell out to the same native APIs).
- **The core hard fact:** macOS has **no public API to assign a window/app to a Space or move
  windows between Spaces.** Every solution uses one of three tricks. Ranked by pragmatism for
  your MVP:
  1. **`com.apple.spaces` "app-bindings" plist** (the same store behind Dock's *Options → Assign
     To → Desktop N*). Set it programmatically, `killall Dock`, and the app opens on the target
     Space on next launch. **No SIP disable, no private API calls.** This is the single most
     pragmatic path for "assign app X to Desktop N on launch." Its limitations are real but
     acceptable for a personal tool.
  2. **Private SkyLight / `CGSSpaces` APIs** (what yabai uses) — can move already-open windows
     between Spaces on demand, but **requires partially disabling SIP** and breaks across macOS
     updates. Avoid for the MVP.
  3. **Accessibility API (`AXUIElement`)** — can move/resize windows *within the current Space*
     and read window geometry. **Cannot move windows between Spaces at all.** This is your tool
     for the *follow-on* window-arrangement feature, not for the Spaces feature.
- **Biggest technical risk:** the Spaces-assignment mechanism is entirely built on undocumented
  behavior. The plist approach is fragile in edge cases (multi-display, apps that ignore it,
  timing after `killall Dock`) and the private-API approach is fragile across OS versions and
  needs SIP off. There is no supported, stable API here — plan for breakage on major macOS
  releases.
- **Pragmatic MVP path (avoids disabling SIP):** a `LSUIElement` menu-bar agent, launched at
  login via `SMAppService`, that (a) writes desired app→Space bindings into
  `com.apple.spaces` and refreshes the Dock, and (b) optionally uses Accessibility to arrange
  windows on the current Space. Only reach for private SkyLight APIs (and SIP-off) if you truly
  need to relocate *already-running* windows live.

---

## 1. Tech stack options

For a solo dev building a small, focused, background/menu-bar utility that must poke at
low-level window/Space machinery, the stack choice is really about how close to the metal you
can get.

| Option | Verdict for this use case |
| --- | --- |
| **Swift + AppKit** | **Recommended.** Direct, idiomatic access to `NSWorkspace` (app-launch notifications), `NSStatusItem` (menu bar), the Accessibility API, and — crucially — the ability to link/`dlopen` private frameworks (SkyLight) if ever needed. Menu-bar/background agents are an AppKit idiom. Smallest binary, no runtime. |
| **Swift + SwiftUI** | Good for the *settings window*, but SwiftUI has no first-class menu-bar/agent lifecycle story that matches AppKit's control, and you'll drop to AppKit for status items and event handling anyway. Best used **inside** an AppKit app (`NSHostingView`) for the preferences UI. |
| **Electron** | Not recommended. ~100MB+ runtime for a utility that is 99% native API calls. Any Spaces/window control still requires shelling out to native binaries or a native addon — Electron buys you nothing here and costs memory + startup + notarization headaches. |
| **Tauri** | Lighter than Electron (uses system WebView, Rust core), but same fundamental problem: the hard part is native macOS window-server access, which you'd write in Rust FFI/`objc` bindings anyway. No advantage over just writing Swift, and a smaller ecosystem for macOS-specific window APIs. |

**Distribution note (matters a lot):** because this is a **personal tool with no App Store
distribution**, you are *not* constrained by App Store sandboxing/entitlement review. You can:
- link/`dlopen` private frameworks (SkyLight) — impossible for App Store apps;
- ship unsandboxed with the Accessibility entitlement flow;
- self-sign / ad-hoc sign for your own machine (notarization only matters for distributing to
  others). This freedom is exactly why AppKit + native is the right call — you can use the
  "dirty" mechanisms the sandboxed world forbids.

Sources: [SMAppService launch-at-login guide (Nil Coalescing)](https://nilcoalescing.com/blog/LaunchAtLoginSetting/),
[Apple: `NSWorkspace.didLaunchApplicationNotification`](https://developer.apple.com/documentation/AppKit/NSWorkspace/didLaunchApplicationNotification).

---

## 2. The hard question: controlling Spaces / Desktops

**Baseline fact:** Apple exposes **no public API** for creating Spaces, moving windows between
Spaces, or assigning an app to a Space. The Space/window-server machinery lives in the private
**SkyLight** framework (historically the `CoreGraphics`/`CGS*` "CGSSpaces" surface), and the
window server's sole privileged client is **`Dock.app`**. Everything below is a workaround.

### 2a. Private `CGSSpaces` / SkyLight APIs

- These are the private functions (`CGSAddWindowsToSpaces`, `CGSMoveWindowsToManagedSpace`,
  `SLSMoveWindowsToManagedSpace`, etc.) that can move windows between Spaces and create/destroy
  Spaces. They are **undocumented, unstable, and reverse-engineered.**
- The window server only honors these fully from the process that owns its connection —
  **`Dock.app`.** That's why yabai *injects code into Dock* rather than calling the APIs from
  its own process. See the community reverse-engineering discussion:
  [HN: reverse engineering macOS Spaces](https://news.ycombinator.com/item?id=23241073).
- **Risk:** symbol availability and behavior change between macOS releases; because it's
  in-process injection into a system process, it's exactly what SIP is designed to prevent (see
  2e). **Not recommended for a maintainable personal tool** unless live relocation of running
  windows is a hard requirement.

### 2b. The Dock "Assign To → Desktop / This Desktop / All Desktops" setting — set programmatically ✅

This is the **most promising supported-ish path** and needs **no private APIs and no SIP
changes.** The GUI setting (right-click a Dock icon → *Options → Assign To*) is stored in
`~/Library/Preferences/com.apple.spaces.plist` under an **`app-bindings`** dictionary that maps
a bundle ID to either `"AllSpaces"` or a **Space UUID**.

```bash
# Read current bindings
defaults read com.apple.spaces app-bindings

# Assign an app to ALL desktops
/usr/libexec/PlistBuddy -c "Add :app-bindings:BUNDLE_ID string AllSpaces" \
  ~/Library/Preferences/com.apple.spaces.plist

# Assign an app to a SPECIFIC desktop (by Space UUID)
/usr/libexec/PlistBuddy -c "Add :app-bindings:BUNDLE_ID string SPACE_UUID" \
  ~/Library/Preferences/com.apple.spaces.plist

# Unbind
/usr/libexec/PlistBuddy -c "Delete :app-bindings:BUNDLE_ID" \
  ~/Library/Preferences/com.apple.spaces.plist

# Apply
killall Dock
```

Space UUIDs live in the same plist under
`SpacesDisplayConfiguration → Management Data → Monitors → […] → Spaces[].uuid` (filter out
entries with a `TileLayoutManager`, which are fullscreen/split-view spaces, not normal
desktops). Extractable via `plutil -convert json -o - … | jq …`.

**Caveats (from the community gist):**
- After editing you must `killall Dock`, and the target app generally needs to be **quit and
  relaunched** for the new binding to take effect (it governs where the app's windows *open*).
- Some apps ignore the assignment entirely.
- Multi-display setups don't always respect the intended display.
- A running tiling WM (yabai) can fight the setting and prevent persistence.
- It is undocumented behavior — treat plist schema as version-fragile.

For an MVP whose job is literally "put app X on Desktop N when it launches," this mechanism *is*
the feature — you're programmatically driving the exact setting the OS already provides.

Source: [gist: assign an application to a desktop via `com.apple.spaces`](https://gist.github.com/0xdevalias/8bc497546d5f036cbaeae5d0e389aa35),
[Apple Community: Assign Apps to Specific Desktop Space](https://discussions.apple.com/thread/254442833).

### 2c. Accessibility API (`AXUIElement`) — window manipulation, and its Spaces limit

- `AXUIElement` lets you enumerate windows of an app and **get/set `AXPosition` and `AXSize`**,
  raise/minimize/close them, etc. This is the standard, supported (permission-gated) way to
  move and resize windows — the mechanism behind Rectangle, Amethyst, and AeroSpace.
- **Hard limit:** the Accessibility API operates on windows **in the current Space only** and
  has **no concept of moving a window to another Space.** You cannot switch/assign Spaces
  through `AXUIElement`. This is why every accessibility-only tool either works within native
  Spaces (Amethyst) or emulates its own workspaces (AeroSpace).
- **Conclusion:** Accessibility is the right tool for your **follow-on window arrange/resize
  per-desktop** feature, and useless for the Spaces-assignment feature.

### 2d. How existing tools solve it (and tradeoffs)

| Tool | Approach | SIP? | Tradeoff |
| --- | --- | --- | --- |
| **yabai** | Injects a **scripting addition into `Dock.app`** to call private SkyLight APIs; can move/create/destroy Spaces, move windows between Spaces, sticky windows, etc. | **Yes — partial SIP disable required** for those features (basic tiling on the current space works without it). | Most powerful; breaks on macOS updates; scripting addition must be re-installed/re-signed; SIP off = weaker system security. |
| **AeroSpace** | **Emulates its own virtual workspaces** — "switching workspaces" just hides non-active windows and moves them far off-screen. Uses **only public Accessibility API** (plus one private call, `_AXUIElementGetWindow`, just to get a window ID). Deliberately ignores native Spaces. | **No.** | No SIP, no daemon, survives updates; but its workspaces are *not* real macOS Spaces (Mission Control/native Spaces don't see them). |
| **Amethyst** | Auto-tiling that works **within native macOS Spaces** via Accessibility; reflows windows on the current space. | **No.** | Simple, safe; limited scripting; inherits native-Spaces quirks (recommends disabling "automatically rearrange Spaces"). |
| **Rectangle** | Pure Accessibility: intercepts shortcuts/drags and sets window position/size on the **current display/Space.** | **No.** | Just window snapping — no Space control at all. |

Sources: [yabai wiki: Disabling SIP](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection),
[AeroSpace README](https://github.com/nikitabobko/AeroSpace),
[Amethyst](https://github.com/ianyh/amethyst),
[Rectangle (via macOS WM directory)](https://macoswm.com/wm/rectangle).

### 2e. SIP — who needs it disabled, who doesn't

- **Must partially disable SIP:** yabai's Space/window-server features. On Apple Silicon
  (macOS 13+) that's roughly `csrutil enable --without fs --without debug --without nvram`
  (Filesystem Protections, Debugging Restrictions, NVRAM); Intel uses a different `csrutil`
  incantation. This is needed because SIP blocks code injection into `Dock.app`. Note SIP is
  **re-enabled during Apple Store repairs**, and disabling it weakens system security broadly.
- **No SIP change needed:** the `com.apple.spaces` plist approach (2b), Accessibility-based
  window management (2c), AeroSpace's emulated workspaces, Amethyst, Rectangle.

**Takeaway:** you can build the desired "assign app to Desktop N on launch" feature **without
touching SIP** by using the plist mechanism. SIP-off is only on the table if you insist on
live-relocating already-open windows across native Spaces.

Source: [yabai wiki: Disabling SIP](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection).

---

## 3. Detecting app launch / system startup (the trigger)

- **App launch:** subscribe to `NSWorkspace.shared.notificationCenter` for
  **`didLaunchApplicationNotification`** (and `didActivateApplicationNotification`); the
  `userInfo` carries the `NSRunningApplication` (bundle ID, PID). Use this to fire the
  assignment/arrange logic when a watched app starts.
  [Apple docs](https://developer.apple.com/documentation/AppKit/NSWorkspace/didLaunchApplicationNotification).
- **Launch at login / system startup:** use **`SMAppService`** (ServiceManagement,
  macOS 13+) — `SMAppService.mainApp.register()` — the modern replacement for the deprecated
  `SMLoginItemSetEnabled`. Ideal for menu-bar utilities.
  [Nil Coalescing guide](https://nilcoalescing.com/blog/LaunchAtLoginSetting/),
  [sindresorhus/LaunchAtLogin issue #76](https://github.com/sindresorhus/LaunchAtLogin-Legacy/issues/76).
- **Run as a background agent:** set **`LSUIElement = YES`** in `Info.plist` so the app has no
  Dock icon and lives only in the menu bar. Note macOS may show a "background activity" alert on
  auto-start; user consent for login items is required by design.

---

## 4. Permissions / entitlements the user must grant manually

- **Accessibility permission** (System Settings → Privacy & Security → **Accessibility**):
  required to read/set window position/size via `AXUIElement`. Prompt with
  `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])`. The user must toggle
  your app on manually; changes may require restarting the app.
- **Login item consent:** enabling `SMAppService` registers a login item the user can see/revoke
  in System Settings → General → Login Items.
- **The plist approach (2b)** writes to the user's own `~/Library/Preferences` and runs
  `killall Dock` — **no special entitlement**, though under sandboxing you couldn't touch it
  (another reason to ship **unsandboxed**, which is fine for a personal tool).
- **Private SkyLight / injection (only if you go that route):** requires **partial SIP disable**
  (a manual Recovery-mode `csrutil` step by the user) and appropriate signing — far heavier.
- Because there's **no App Store distribution**, you avoid sandbox entitlement review entirely;
  you only need to grant Accessibility + login-item consent on your own machine.

---

## 5. Recommended MVP architecture

**Goal:** assign apps to designated Desktops when the machine starts or when the app launches;
later, arrange window positions/sizes per desktop.

```
┌──────────────────────────────────────────────────────────────┐
│  Menu-bar agent  (Swift + AppKit, LSUIElement = YES)          │
│  • Launched at login via SMAppService                         │
│  • Config: [ bundleID → target Desktop ]  (JSON in App Support)│
│                                                               │
│  Space assignment (NO SIP, NO private API):                   │
│  • On config change / at login: write app-bindings into       │
│    com.apple.spaces.plist (bundleID → Space UUID),            │
│    then `killall Dock`.                                        │
│  • Resolve Space UUIDs by parsing the same plist.             │
│                                                               │
│  Launch trigger:                                              │
│  • NSWorkspace didLaunchApplicationNotification → ensure       │
│    binding is set; (optionally) nudge/relaunch if needed.     │
│                                                               │
│  Window arrange (follow-on, Accessibility API):               │
│  • AXUIElement get/set AXPosition & AXSize for the app's       │
│    windows on the CURRENT Space.                              │
└──────────────────────────────────────────────────────────────┘
```

**Why this shape:**
- Avoids SIP entirely — the plist mechanism *is* the OS's own "Assign To Desktop" feature,
  driven programmatically.
- Uses only supported public frameworks for triggers (`NSWorkspace`, `SMAppService`) and window
  geometry (`AXUIElement`).
- Keeps the fragile part (undocumented plist schema + Dock refresh) isolated behind one module
  you can fix quickly if a macOS update changes it.

**Single biggest technical risk:** there is **no supported API for Space assignment** — the
entire feature rests on the undocumented `com.apple.spaces` plist format and Dock's honoring of
it (and its known quirks: quit/relaunch needed, some apps ignore it, multi-display
inconsistency, breakage on major macOS releases). Mitigate by: (1) confining plist handling to
one well-tested module, (2) detecting failure (verify the window's Space after launch) and
falling back gracefully, (3) explicitly *not* depending on private SkyLight/SIP-off unless a
future feature (live relocation of already-open windows) forces it — at which point evaluate the
yabai-style scripting-addition approach with eyes open about the security/maintenance cost.

**If live relocation of running windows becomes a hard requirement:** the only known way is the
private SkyLight route (yabai-style Dock injection) with partial SIP disabled — accept that
tradeoff deliberately, or emulate workspaces AeroSpace-style (hide/offscreen windows) to stay
SIP-free at the cost of not using *real* native Spaces.

---

## Sources

- Apple — [`NSWorkspace.didLaunchApplicationNotification`](https://developer.apple.com/documentation/AppKit/NSWorkspace/didLaunchApplicationNotification)
- Apple — [`NSWorkspace.didActivateApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- Nil Coalescing — [Add launch-at-login with SMAppService](https://nilcoalescing.com/blog/LaunchAtLoginSetting/)
- [sindresorhus/LaunchAtLogin — use SMAppService for macOS 13 (#76)](https://github.com/sindresorhus/LaunchAtLogin-Legacy/issues/76)
- Gist (0xdevalias) — [Assign an app to a desktop via `com.apple.spaces`](https://gist.github.com/0xdevalias/8bc497546d5f036cbaeae5d0e389aa35)
- Apple Community — [Assign Apps to Specific Desktop Space](https://discussions.apple.com/thread/254442833)
- Hacker News — [Reverse engineering the macOS Spaces implementation](https://news.ycombinator.com/item?id=23241073)
- yabai wiki — [Disabling System Integrity Protection](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection)
- [AeroSpace README (nikitabobko/AeroSpace)](https://github.com/nikitabobko/AeroSpace)
- [Amethyst (ianyh/amethyst)](https://github.com/ianyh/amethyst)
- macOS WM directory — [Rectangle](https://macoswm.com/wm/rectangle), [yabai](https://macoswm.com/wm/yabai), [AeroSpace](https://macoswm.com/wm/aerospace)
