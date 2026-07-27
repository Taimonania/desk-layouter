import Sparkle

/// The Sparkle `SPUStandardUserDriverDelegate` shim for the in-app update reminder
/// (issue #127). It is a translation layer with no decisions of its own: it
/// declares that the app supports gentle scheduled reminders (which both silences
/// Sparkle's launch-time warning about a background app lacking them and signals
/// that the app takes responsibility for presenting scheduled updates), always
/// tells Sparkle *not* to present the scheduled-update window itself, and forwards
/// the appcast item's display version and Sparkle's `handleShowingUpdate` flag —
/// plus user attention and session end — into the pure `UpdateReminder` seam via
/// the injected closures. Every actual decision lives in that seam.
///
/// The delegate methods are `nonisolated` to satisfy Sparkle's protocol, but
/// Sparkle's standard user driver delivers them on the main thread, so each hops to
/// the main actor with `assumeIsolated` before touching the main-actor closures.
///
/// Not on the testable target's source list and deliberately not unit tested: it
/// holds no logic to test, and it depends on Sparkle types the testable target
/// cannot import.
final class UpdateReminderUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// Forwards `(handledBySparkle, versionName)` from
    /// `standardUserDriverWillHandleShowingUpdate` into the seam's `recordFoundUpdate`.
    private let onFoundUpdate: @MainActor (Bool, String?) -> Void

    /// Forwards a dismissal from both user attention and session end into the seam.
    private let onDismiss: @MainActor () -> Void

    init(
        onFoundUpdate: @escaping @MainActor (Bool, String?) -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.onFoundUpdate = onFoundUpdate
        self.onDismiss = onDismiss
    }

    /// Declares that the app presents scheduled updates itself. Silences Sparkle's
    /// error-level launch warning about a background app without gentle reminders,
    /// and enables the delegate callbacks below.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Always returns `false`, including when Sparkle proposes immediate focus:
    /// Sparkle's own scheduled-update window never appears for a background check.
    /// Returning the `immediateFocus` argument (Sparkle's canonical example) would
    /// hand launch-time discoveries back to a modal dialog on most launches; the
    /// toast is the one consistent presentation, and the user still reaches the full
    /// dialog in one click. See the parent spec (#126) for the rejected alternative.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// Forwards the appcast item's display version and Sparkle's `handleShowingUpdate`
    /// flag to the seam. When Sparkle is handling the update itself (a user-initiated
    /// "Check for Updates…"), the seam records nothing, so an explicit check never
    /// produces a toast; a background check records a pending update.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let versionName = update.displayVersionString
        forwardFoundUpdate(handleShowingUpdate, versionName)
    }

    /// The user gave the update its attention (opened Sparkle's dialog). Dismiss the
    /// toast so the user is not looking at two prompts for the same thing.
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        forwardDismiss()
    }

    /// The update session ended. Dismiss the toast so no stale reminder lingers.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        forwardDismiss()
    }

    // Sparkle delivers the delegate callbacks on the main thread, so these hop onto
    // the main actor with `assumeIsolated`. The closure is copied to a local first so
    // the main-actor closure captures the closure value, not `self` (task-isolated
    // in a `nonisolated` method).

    private nonisolated func forwardFoundUpdate(_ handledBySparkle: Bool, _ versionName: String?) {
        let forward = onFoundUpdate
        MainActor.assumeIsolated {
            forward(handledBySparkle, versionName)
        }
    }

    private nonisolated func forwardDismiss() {
        let dismiss = onDismiss
        MainActor.assumeIsolated {
            dismiss()
        }
    }
}
