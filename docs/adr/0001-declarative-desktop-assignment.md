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

1. Normalize managed bundle identifiers to lowercase, matching the native Dock representation, and merge their Desktop UUIDs into `com.apple.spaces` `app-bindings` without removing unmanaged entries.
2. Restart Dock as required by issue #3. The restart is retained until a later controlled change proves it can be removed safely.
3. Read the store back and verify every intended normalized binding.
4. Pass the complete persisted binding dictionary to WindowServer's current session through the dynamically resolved private `SLSSessionSetCurrentSessionWorkspaceApplicationBindings` function, with the legacy `CGS` symbol as a fallback.

Physical placement is verified separately at the real-system seam: launch a fully quit disposable application from another Desktop and assert that its new window belongs only to the assigned Desktop. Storage read-back alone is not proof that Apply works.

If the private framework or symbols are unavailable, Apply fails closed with a clear adapter error. This mechanism requires no SIP changes and no continuously running agent.

## Consequences

- The walking skeleton works on the tested macOS 26.5.2 host: the plist-only control is red, while adding the session update is green, including across the retained Dock restart.
- The private setter is an undocumented ABI. Its symbol, signature, dictionary semantics, caller restrictions, or behavior may change with any macOS release. Dynamic resolution contains the failure, but cannot make the contract stable.
- The solution is appropriate only for this personal, unsandboxed, self-installed utility. It is not a public-API or App Store-compatible mechanism.
- There is no equivalent public non-UI API. Automating the supported Dock workflow would avoid the private function but require Accessibility permission and introduce UI hierarchy, localization, navigation, and timing fragility.
- Logout, reboot, removal, multi-Assignment, and multi-display behavior require separate verification. Persisted bindings are expected to support later session reconstruction, but the macOS 26.5.2 experiments prove only quit/relaunch behavior in the current login session.
- The active window-moving approach remains deferred to the later per-Desktop layout feature.
