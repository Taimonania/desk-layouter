# Assigning applications to Desktops on macOS 26

Research date: 2026-07-19
Tested host: macOS 26.5.2 (build 25F84), macOS 26.5 SDK

## Conclusion

macOS 26 has a supported, persistent **user workflow** for assigning an application to a Desktop: make the destination Desktop current, then use the application's Dock menu and choose **Options → Assign To → This Desktop**. Apple says the application will then open in that Desktop. The menu can also choose All Desktops, the current Desktop on a particular display, or None. Apple does not document a programmatic API that accepts a Desktop number, UUID, or managed Space ID for an arbitrary application. [Apple, *Work in multiple spaces on Mac*](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/26/mac/26)

On this exact 26.5.2 host, the native Dock workflow passed an end-to-end control: a disposable application was assigned on managed Space ID 3, the user switched to managed Space ID 1, and a quit/relaunch created its window only on managed Space ID 3. Directly writing the same lowercase bundle-ID → Desktop-UUID record to `com.apple.spaces` still failed physical placement.

A second controlled experiment identified the missing operation. After writing `app-bindings`, calling the private SkyLight function `CGSSessionSetCurrentSessionWorkspaceApplicationBindings(SLSMainConnectionID(), bindings)` made the same probe pass, including across a Dock restart. The tested model is therefore:

```text
com.apple.spaces app-bindings     private session setter
        persistence data      +    live WindowServer state
                    \                 /
                     future app launch
                    opens on target Desktop
```

This supports a concrete conclusion for macOS 26.5.2: **a plist write and read-back are not an effective control plane by themselves**. The private live session-binding update is also required, or the supported Dock UI must be used so Dock performs its internal update. The experiment proves future launches within the current login session; logout/reboot rehydration has not yet been tested.

No continuously running window-moving agent is required after either successful Apply path. However, there is no fully public, non-UI API path: automating the Dock requires Accessibility and brittle UI navigation, while calling the live session setter uses an undocumented private ABI.

These findings prompted the amendment of [ADR-0001](../adr/0001-declarative-desktop-assignment.md). The declarative design now persists `app-bindings` and performs the private current-session update while retaining the ticket's Dock restart.

## Session-boundary rehydration (logout/login and reboot)

Tested build for this section: macOS 26.5.2 (build 25F84), recorded from `sw_vers` on 2026-07-19.

Issue #3 established quit/relaunch placement within the current login session. It did **not** establish whether macOS reconstructs the live WindowServer current-session binding table from the persisted `com.apple.spaces` `app-bindings` after a login-session boundary (logout/login or reboot) when Desk Layouter is not running. That question is what determines whether "configure once, macOS enforces at login" holds, or whether a re-Apply is required after each boundary.

Because a process cannot span the boundary, the check is a two-phase harness, `Scripts/verify-session-boundary.sh`, with all state staged in a reboot-surviving directory under `~/Library/Application Support/DeskLayouter/session-boundary-test/` (never `/tmp` or `$TMPDIR`, which a reboot clears):

- `arm` — snapshot `com.apple.spaces` (including a pre-seeded unmanaged binding to prove preservation), build a disposable probe app into the persistent dir, record the macOS build, and Apply an Assignment for the probe to a non-active built-in-display Desktop through the production adapter. Prints human instructions; never logs out or reboots.
- `verify` — after the human logs out/reboots and switches to a different Desktop, launch the fully-quit probe without Desk Layouter running and assert its new window actually belongs to the assigned Desktop (managed space ID re-resolved from the stable Desktop UUID). Read-back of the persisted binding is necessary but not treated as sufficient.
- `restore` — transactional, idempotent cleanup of app-bindings, live session bindings, active Desktop, probe, and state dir; also runs at the end of `verify`.

Procedure to record a result:

```sh
Scripts/verify-session-boundary.sh arm
# log out and back in (or reboot), then from a DIFFERENT Desktop:
Scripts/verify-session-boundary.sh verify
```

Observed results:

| Boundary | macOS build | Result | Notes |
| --- | --- | --- | --- |
| In-session `arm → restore` round-trip | 26.5.2 (25F84) | Verified | `app-bindings` returned exactly to its prior state; unmanaged binding preserved through Apply; state dir cleaned. Mechanics of the harness are sound. |
| Logout / login rehydration | 26.5.2 (25F84) | **Pending human-gated verification** | Run `arm` → logout → `verify`. Fill in the observed managed-space placement here once observed. |
| Reboot / login rehydration | 26.5.2 (25F84) | **Pending human-gated verification** | Run `arm` → reboot → `verify`. Fill in the observed managed-space placement here once observed. |

No product limitation is asserted for the logout/reboot cases yet, because the outcome has not been observed. If `verify` shows the probe does **not** rehydrate onto its assigned Desktop after a boundary, the resulting limitation (e.g. "re-Apply is required after each login") must be recorded here and in ADR-0001 at that time. Do not infer the outcome from persistent read-back alone.

## Evidence standard and limits

The findings below distinguish four kinds of evidence:

- **Documented:** current Apple support, developer, or deployment documentation.
- **First-party artifact:** read-only inspection of Apple's installed macOS 26.5.2 binaries, scripting definitions, man pages, or SDK. This shows that a symbol or vocabulary exists, not that Apple supports third-party use.
- **Local experiment:** controlled behavior on the tested 26.5.2 machine, with original bindings restored after each probe.
- **Secondary evidence:** third-party source code or reverse engineering, kept separate from Apple contracts.

Negative documentation findings are scoped rather than absolute: the current public API surfaces and schemas examined contain no such operation. They cannot prove that no undiscovered private mechanism exists. The private mechanism confirmed by experiment is, by definition, outside those public contracts.

## Practical comparison matrix

| Mechanism | Support status | Expected persistence path | Target numbered Desktop? | Running agent / UI / private API | Compatibility and security risks | Evidence from our tests |
| --- | --- | --- | --- | --- | --- | --- |
| Dock **Assign To → This Desktop** | Apple-documented user workflow | Dock's internal binding state; observed `com.apple.spaces` record plus live session update | Indirectly: first make that Desktop current; menu does not accept a number | User UI once; no ongoing agent | Desktop order and multiple displays complicate navigation; existing app windows affect launch behavior | **Supported:** native UI control passed on 26.5.2 |
| Accessibility automation of Dock UI | AX APIs are public; the Dock hierarchy is not a stable automation contract | Same internal path as the native Dock action | Indirectly, by navigating to Desktop N and choosing This Desktop | One-shot running automation with Accessibility permission | Localization, Dock layout, timing, AX hierarchy, multiple displays | Not yet implemented as product path; native UI success makes it plausible |
| `defaults write com.apple.spaces app-bindings …` + Dock restart | Undocumented preference key and semantics | Preference record only on 26.5.2 | Encodes a Desktop UUID, but behavior is not applied | No agent; no private API | Schema and bundle-ID normalization can change; stored state can be mistaken for applied state | **Refuted alone:** every write read back, every placement stayed red |
| `app-bindings` + private session setter | Undocumented/private, empirically effective | Plist for persistence plus WindowServer session table for live behavior | Yes, after resolving number → UUID | One-shot private SkyLight call; no ongoing agent observed | Private signature, symbol name, entitlements, semantics, and login behavior may change; unsuitable for a public-API-only product | **Supported locally:** red control became green on 26.5.2 |
| AppKit `NSWindow.collectionBehavior` | Public API | The owning application's runtime/window restoration behavior | No; only one Space, all Spaces, or move to active Space | Target app must implement it for its own windows | Cannot control another app or select a Desktop identifier | Does not address the tested assignment |
| `NSWorkspace` / LaunchServices | Public API | Launch Services database and launch configuration | No Space destination exists in documented launch options | No UI or private API, but cannot express the requirement | Low API risk; capability absent | Exact-bundle pre-registration staying red is consistent with the API boundary |
| Direct AppleScript command | Public language, but no assignment vocabulary | None | No | No viable direct command | Dock is not directly scriptable for this operation | Current System Events SDEF has no Mission Control assignment object |
| Shortcuts | Public automation product | Shortcut definition only | No documented native action | Can wrap AppleScript, shell, or AX automation | Inherits the wrapped mechanism's risks | No independent path to explain or repair the red tests |
| Dock MDM payload | Public schema | Managed `com.apple.dock` settings | No assignment field | MDM only | Capability absent | Does not address the tested assignment |
| MDM Managed Preferences carrying `app-bindings` | Generic carrier is public; binding semantics remain private | Forced/set-once preferences | Can carry the UUID data only | MDM; no live session update documented | Management precedence plus same undocumented semantics | Direct-write failures refute the idea that preference transport alone is enough |
| Private `SLSProcessAssignToSpace` / window-moving calls | Private SkyLight ABI | Likely current process/window state; persistence is not documented | Space ID, not a stable public Desktop number | Running process/agent and private API; some techniques may need Dock injection or privileged conditions | Highest OS-version, signing, SIP, and behavior risk | Symbols exist; not needed to explain the now-confirmed session-binding path |

## Supported Apple behavior

Apple's current macOS 26 guide says that with two or more Desktops, an application can be assigned so it always opens in a particular Desktop. The documented choices are All Desktops, This Desktop, Desktop on Display `[number]`, and None. “This Desktop” means the Desktop that is current when the menu action occurs; it is not an arbitrary Desktop-number picker. Apple also notes that the application may need to be opened first so its icon appears in the Dock. [Apple, *Work in multiple spaces on Mac*](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/26/mac/26)

“Desktop N” is positional rather than a documented stable identifier. macOS can automatically rearrange Desktops based on most recent use, and separate displays may each have separate Spaces. A tool that promises a durable numeric target should disable or account for automatic rearrangement and define its display-selection policy. [Apple, *Change Desktop & Dock settings on Mac*](https://support.apple.com/guide/mac-help/change-desktop-dock-settings-mchlp1119/26/mac/26)

Apple further documents that an existing window can influence where a new document opens: if TextEdit has windows in Desktop 2, creating a document from Desktop 3 can open it in Desktop 2. Assignment validation should therefore use a fully quit application and a newly created window, as the local probes do. [Apple, *Work in multiple spaces on Mac*](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/26/mac/26)

## Public APIs do not expose arbitrary Desktop assignment

### AppKit

AppKit's public Space-related controls belong to `NSWindow` and therefore apply to windows owned by the calling application. `NSWindow.CollectionBehavior` can make a window appear in one Space, join all Spaces, or move to the active Space when activated. None of its values accepts a Space number, UUID, or ID, and it does not control another application. [Apple, `NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)

The related public observations are also intentionally narrow. `NSWindow.isOnActiveSpace` is Boolean, `NSScreen.screensHaveSeparateSpaces` reports one Mission Control preference, and `NSWorkspace.activeSpaceDidChangeNotification` only reports that a change occurred; Apple documents no old/new Space identifier in its `userInfo`. [Apple, `NSWindow`](https://developer.apple.com/documentation/appkit/nswindow), [`NSScreen.screensHaveSeparateSpaces`](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces), [`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)

Core Graphics formerly exposed `kCGWindowWorkspace` as window metadata, but Apple now marks it deprecated and “No longer supported.” Even historically, it was an observation key rather than a supported assignment operation. [Apple, `kCGWindowWorkspace`](https://developer.apple.com/documentation/coregraphics/kcgwindowworkspace)

### LaunchServices and `NSWorkspace`

LaunchServices publicly covers launching/activating applications, opening documents and URLs, resolving handlers, and registering application capabilities. Its launch flags cover such behavior as foreground activation, a new instance, hiding, printing, and recent items, but not a Desktop destination. [Apple, Launch Services](https://developer.apple.com/documentation/coreservices/launch_services), [`LSLaunchURLSpec`](https://developer.apple.com/documentation/coreservices/lslaunchurlspec), [`LSLaunchFlags`](https://developer.apple.com/documentation/coreservices/lslaunchflags)

The current `NSWorkspace.OpenConfiguration` likewise controls activation, recent items, new instances, hiding, user interaction, Apple events, arguments, environment, and architecture; it exposes no Desktop destination. [Apple, `NSWorkspace.OpenConfiguration`](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration)

Consequently, the exact-bundle pre-registration experiment removed a plausible identity/lookup error but could not unlock a Desktop-assignment behavior that LaunchServices does not document. Its red result is consistent with this boundary.

### AppleScript and Accessibility

The installed macOS 26.5.2 System Events scripting definition is a first-party artifact. Its “Desktop Suite” controls desktop pictures, its Dock suite controls basic preferences, and its Processes suite exposes generic UI elements plus window position and size. It contains no Mission Control Desktop object or assignment command. Dock itself has no scripting definition. Reproduce this inspection with:

```sh
grep -nEi 'space|desktop|mission|dock|window' \
  '/System/Library/CoreServices/System Events.app/Contents/Resources/SystemEvents.sdef'
plutil -p /System/Library/CoreServices/Dock.app/Contents/Info.plist
```

Apple does support generic GUI scripting through System Events and Accessibility. It can query UI hierarchies and click buttons or menu items, but the user must grant Accessibility control per application. [Apple, *Automating the User Interface*](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AutomatetheUserInterface.html)

The public AX primitives are sufficient in principle to find Dock items, show their contextual menus, and pick menu items. [Apple, Accessibility roles](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/roles), [`kAXShowMenuAction`](https://developer.apple.com/documentation/applicationservices/kaxshowmenuaction), [`kAXShownMenuUIElementAttribute`](https://developer.apple.com/documentation/applicationservices/kaxshownmenuuielementattribute), [`kAXPickAction`](https://developer.apple.com/documentation/applicationservices/kaxpickaction), [`AXUIElementPerformAction`](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)

This makes a one-shot UI automation fallback credible: navigate to the intended Desktop, locate or temporarily launch the application so it has a Dock item, invoke Options → Assign To → This Desktop, then restore focus. It is still an imperative, localized, timing-sensitive reproduction of a UI workflow—not a declarative AppleScript or Accessibility API for assigning a Desktop.

### Shortcuts

Apple documents `Open App`, and explains that Shortcuts actions come from the action library and installed applications. No Apple Shortcuts documentation found in this review exposes a Mission Control assignment or “open on Desktop N” action. [Apple, *About share actions in Shortcuts on Mac*](https://support.apple.com/guide/shortcuts-mac/about-share-actions-apdaf74d75a5/mac), [*Navigate the action list in Shortcuts on Mac*](https://support.apple.com/guide/shortcuts-mac/navigate-the-action-list-apdc33e4f4da/mac)

Shortcuts can run a wrapper around a shell command, AppleScript, or other automation, but that does not improve the support status of the wrapped mechanism. It offers orchestration, not an independent Desktop-assignment primitive.

### MDM

Apple's documented Dock payload schema is exhaustive: it includes Dock size, magnification, orientation, minimize behavior, app/file items, immutability, and related preferences. It has no Mission Control Desktop-assignment field. [Apple Developer, `Dock`](https://developer.apple.com/documentation/devicemanagement/dock), [Apple Platform Deployment, *Dock device management payload settings*](https://support.apple.com/guide/deployment/dock-device-management-payload-settings-depef1fdf19/web)

The generic Managed Preferences payload can transport preference dictionaries by domain, but Apple does not document `com.apple.spaces` `app-bindings` semantics. [Apple Developer, `ManagedPreferences`](https://developer.apple.com/documentation/devicemanagement/managedpreferences) An MDM profile could therefore carry the same bytes, but there is no documented MDM operation that performs the live session update. The direct-write experiments show why transport and behavioral application must not be conflated.

## The undocumented preference path on 26.5.2

No Apple developer, support, deployment, or local scripting documentation examined in this review documents:

- `com.apple.spaces` as a third-party control API;
- the `app-bindings` key;
- bundle-ID case or normalization rules;
- Desktop-UUID value semantics;
- a reload notification or `killall Dock` procedure; or
- a guarantee that stored bindings are consumed at Dock launch.

The local Apple `defaults(1)` man page documents only reading and writing the preferences system. It warns that modifying the preferences of a running application may not be seen and may be overwritten. It does not promise that a syntactically valid private key triggers the corresponding application behavior.

The often-cited community recipe recommends a bundle-ID → UUID write followed by `killall Dock`, but its specific-Desktop section itself says it was not tested. It is useful history, not a platform contract. [Secondary: `0xdevalias` gist](https://gist.github.com/0xdevalias/8bc497546d5f036cbaeae5d0e389aa35)

The native control and setter experiment sharpen the interpretation considerably. The plist is not merely obsolete: Dock UI still writes the same lowercase bundle-ID → UUID shape. It is instead **insufficient live input**. On this build, the effective assignment has at least two representations: persisted preferences and a WindowServer session binding table.

## Private SkyLight evidence

Read-only inspection of Apple's installed artifacts on the tested host found SkyLight version 1.600.0, built for macOS 26.5, and these relevant exports in the 26.5 SDK stub:

```text
_SLSProcessAssignToSpace
_SLSProcessAssignToAllSpaces
_SLSMoveWindowsToManagedSpace
_SLSSessionSetApplicationBindingsForWorkspaces
_SLSSessionSetCurrentSessionWorkspaceApplicationBindings
_SLSPersistenceSaveSpaceConfiguration
```

Dock imports the corresponding legacy-prefixed `_CGSSessionSetCurrentSessionWorkspaceApplicationBindings` symbol. Its binary also contains `_appToSpaceTable`, `com.apple.spaces`, and `show-space-bindings` strings. Reproduce these first-party artifact checks with:

```sh
xcrun --show-sdk-version
grep -oE '(_(CGS|SLS)[A-Za-z0-9_]*(ApplicationBindings|AssignToSpace|AssignToAllSpaces|MoveWindowsToManagedSpace|PersistenceSaveSpaceConfiguration)[A-Za-z0-9_]*)' \
  "$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight.tbd" | sort -u
nm -u /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | \
  grep -E '(CGS|SLS).*ApplicationBindings'
strings -a /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | \
  grep -E '^(_appToSpaceTable|com.apple.spaces|show-space-bindings)$'
```

The exported symbol names and Dock import are architectural evidence, not API documentation. They do not define ownership, lifetime, thread requirements, authorization, return semantics, or forward compatibility. Apple requires App Store submissions to use public APIs, so this path is inappropriate for an App Store product. [Apple, App Review Guidelines §2.5.1](https://developer.apple.com/app-store/review/guidelines/)

For this self-installed personal utility, the risk is operational rather than review-based: every macOS update can rename the symbol, change its signature or dictionary schema, reject the caller, or change when session state must be refreshed. The adapter should dynamically resolve the symbol, fail closed, preserve the previous full dictionary, and verify physical placement—not merely read-back—after Apply.

Third-party source corroborates that these are reverse-engineered private functions. Current yabai headers declare `SLSProcessAssignToSpace`, `SLSProcessAssignToAllSpaces`, and `SLSMoveWindowsToManagedSpace`; its documentation explicitly frames advanced WindowServer control and optional Dock injection as private, SIP-sensitive territory. This is secondary implementation evidence, not proof of Apple's contract. [Secondary: yabai private declarations](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h#L61-L64), [yabai README](https://github.com/asmvik/yabai)

## Interpretation of the local experiments

The project evidence is tracked in [issue #3](https://github.com/Taimonania/desk-layouter/issues/3). The disposable probe verifies a new layer-zero window's managed Space through private read-only SkyLight inspection, then restores the original preferences and session bindings.

| Experiment | Result | What it establishes | What it does not establish |
| --- | --- | --- | --- |
| Bundle ID → Desktop UUID write and read-back | Stored value matched | Serialization and CFPreferences write succeeded | WindowServer accepted the Assignment |
| `killall Dock` | Red placement | Restart alone does not import/apply the externally written binding on 26.5.2 | Whether Dock restart is needed after the private setter |
| 2-second and 15-second delays | Both red | An ordinary propagation delay is not the missing step | Every possible asynchronous internal condition |
| Exact-bundle pre-registration | Red | Missing LaunchServices registration is not the sole cause | All possible identity rules |
| Lowercase bundle ID matching native Dock | Red | Straightforward case mismatch is not the cause | Other private identity normalization |
| Native Dock UI, same lowercase UUID format | Green on managed Space ID 3 after relaunch from managed Space ID 1 | macOS's documented feature works on this host; the stored format alone does not explain behavior | Exact internal Dock call order |
| External write plus private current-session binding setter | Green; observed `[3]` instead of red `[1]`, including Dock restart | The live session setter is the missing behavioral update in this controlled 26.5.2 case | ABI stability, logout/reboot persistence, multi-display behavior, or universal app compatibility |

The last experiment turns the binary evidence into behavioral evidence. The most economical model is that `app-bindings` persists desired assignments while WindowServer's current-session table enforces launches. Native Dock UI updates both; an external preference write updates only the former. Static inspection alone could only suggest this model, but the controlled red-to-green setter experiment now supports it directly.

## Recommended decision

For a public-API-only product, use one-shot Accessibility automation of Apple's Dock workflow and accept its UI fragility. It should not need a continuously running window mover after Apply because native Dock assignment itself persisted across the tested quit/relaunch.

For this personal, unsandboxed utility, the smallest continuation of the existing declarative architecture is a two-part private adapter:

1. write the complete normalized `app-bindings` dictionary for persistence; and
2. dynamically call the current-session binding setter with that complete dictionary, then physically verify a future launch.

Before expanding that path beyond the walking skeleton, isolate whether Dock restart is still necessary, test removal as well as addition, test multiple Assignments in one dictionary, and test logout/login and reboot rehydration. Keep the native Dock UI as the behavioral control on each supported macOS release.

Do not present plist read-back as Apply success. On macOS 26.5.2 it proves only persistence data. The acceptance criterion that matters is the one already in issue #3: after quitting and relaunching, the application's new window belongs only to the intended Desktop.
