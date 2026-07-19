# Declarative Desktop Assignment through persistent and session bindings

Status: Accepted (amended after verification on macOS 26.5.2)

## Context

macOS exposes no public API for assigning an arbitrary application to a numbered Desktop. Apple's supported workflow is the Dock's **Options → Assign To → This Desktop** menu. Public AppKit and LaunchServices APIs cannot express the same operation for another application.

The original decision treated `com.apple.spaces` `app-bindings` plus a Dock restart as the complete mechanism. Controlled tests on macOS 26.5.2 disproved that assumption: the expected bundle-ID → Desktop-UUID entry wrote and read back successfully, but a freshly launched application still opened on the current Desktop. The native Dock workflow remained effective.

Inspection and red-to-green experiments established two distinct representations:

- `com.apple.spaces` `app-bindings` persists Assignments; and
- WindowServer's current-session application bindings enforce new launches during the current login session.

Dock updates both. An external preferences write updates only the persisted representation. See [Assigning applications to Desktops on macOS 26](../research/macos-26-desktop-assignment.md).

## Decision

Apply remains declarative: Desk Layouter does not watch launches or move live windows. The isolated macOS adapter performs the following work:

0. **Preflight the private session-binding ABI before mutating anything.** The adapter dynamically resolves `SLSMainConnectionID`/`CGSMainConnectionID` and `SLSSessionSetCurrentSessionWorkspaceApplicationBindings` (with the `CGS` symbol as a fallback) *before* it reads, writes, or restarts anything. If either symbol is unavailable, Apply throws `sessionBindingAPIUnavailable` immediately, leaving the persistent store — both managed and unmanaged entries — untouched and the Dock un-restarted. This ordering is what makes the failure atomic: the persistent store and the live session are never left in a half-updated state (issue #8).
1. Normalize managed bundle identifiers to lowercase, matching the native Dock representation, and merge their Desktop UUIDs into `com.apple.spaces` `app-bindings` without removing unmanaged entries.
2. Restart Dock as required by issue #3. The restart is retained until a later controlled change proves it can be removed safely.
3. Read the store back and verify every intended normalized binding.
4. Pass the complete persisted binding dictionary to WindowServer's current session through the dynamically resolved private `SLSSessionSetCurrentSessionWorkspaceApplicationBindings` function, with the legacy `CGS` symbol as a fallback.

Physical placement is verified separately at the real-system seam: launch a fully quit disposable application from another Desktop and assert that its new window belongs only to the assigned Desktop. Storage read-back alone is not proof that Apply works.

If the private framework or symbols are unavailable, Apply fails closed with a clear adapter error *before* any persistent write, so an unsupported macOS release cannot leave a partial managed update or disturb unmanaged bindings. This mechanism requires no SIP changes and no continuously running agent. The guarantee is covered by an injectable-seam unit test (`DeskLayouterAdapterFailureTests`) that resolves the adapter with a fake session updater reporting the symbols as unavailable and asserts that Apply throws `sessionBindingAPIUnavailable` and issues no `defaults` write and no `killall Dock` (issue #8, AC 4).

### Session-boundary verification

Issue #3 proved quit/relaunch placement *within* the current login session. Whether macOS reconstructs the live WindowServer session table from the persisted `app-bindings` after a logout/login or a reboot — with Desk Layouter not running — is verified by a separate two-phase harness, `Scripts/verify-session-boundary.sh`, because that boundary cannot be spanned in a single process:

- `arm` snapshots `com.apple.spaces` (including a pre-seeded unmanaged binding to prove preservation), builds a disposable probe app into a reboot-surviving directory under `~/Library/Application Support/DeskLayouter/`, records the macOS build, and Applies an Assignment for the probe to a non-active built-in-display Desktop through the production adapter.
- The human then logs out/reboots, switches to a different Desktop, and runs `verify`, which launches the fully-quit probe without Desk Layouter running and asserts the probe's new window actually belongs to its assigned Desktop (re-resolving the Desktop's managed space ID from its stable UUID, since IDs can be re-minted across the boundary). Read-back of the persisted binding is treated as necessary but not sufficient.
- `restore` (also run at the end of `verify`, and safe standalone) returns the original app-bindings, live session bindings, and active Desktop, removes the probe, and deletes the state directory. It is transactional and idempotent.

The `arm → restore` round-trip was validated in-session on the tested build (app-bindings returned exactly to its prior state; state directory cleaned). **Logout/login rehydration was then observed to PASS on 26.5.2 (25F84), 2026-07-19**: after `arm` → logout/login (Desk Layouter not running) → `verify`, the fully-quit probe opened on its assigned Desktop from a different Desktop, the managed Assignment survived in the persistent store, and the pre-seeded unmanaged binding was preserved. macOS reconstructs the live current-session binding table from persisted `app-bindings` at login. The **reboot** boundary was **not physically exercised** — on the maintainer's decision it is accepted by inference from the logout result (a reboot restores the session table from the same persisted store); this remains an inference rather than an observation. See the research note for the results table and residual gap.

## Consequences

- The walking skeleton works on the tested macOS 26.5.2 host: the plist-only control is red, while adding the session update is green, including across the retained Dock restart.
- The private setter is an undocumented ABI. Its symbol, signature, dictionary semantics, caller restrictions, or behavior may change with any macOS release. Dynamic resolution contains the failure, but cannot make the contract stable.
- The solution is appropriate only for this personal, unsandboxed, self-installed utility. It is not a public-API or App Store-compatible mechanism.
- There is no equivalent public non-UI API. Automating the supported Dock workflow would avoid the private function but require Accessibility permission and introduce UI hierarchy, localization, navigation, and timing fragility.
- Removal and multi-Assignment behavior are verified by the real-system harness (issue #7). Multi-display behavior remains out of scope for the MVP. Logout/login rehydration is confirmed on 26.5.2 (25F84) via `Scripts/verify-session-boundary.sh`; the private-symbol-unavailable failure is now covered atomically (preflight before any write). Persisted bindings are shown to support session reconstruction across a logout/login boundary; the reboot boundary is accepted by inference from that result (issue #8) rather than physically observed, and would be re-checked with the same harness if reboot behavior is ever in doubt.
- The active window-moving approach remains deferred to the later per-Desktop layout feature.
