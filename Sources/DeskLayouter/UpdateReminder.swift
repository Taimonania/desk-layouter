import Foundation

/// The in-app update reminder's presentation state and every decision behind it
/// (issue #127, epic #126). When a *background* update check finds a new version,
/// the app — a menu-bar (accessory) app whose Sparkle window would otherwise open
/// unseen behind everything else — shows a quiet toast in the editor window naming
/// the version, plus a small badge on the menu-bar icon. This value type owns only
/// the *logic*: recording a found update, the guard that ignores updates Sparkle is
/// presenting itself (so a user-initiated "Check for Updates…" never produces a
/// toast), toast visibility per surface, badge visibility, the display string and
/// its fallback, and dismissal.
///
/// It is a pure value type on the testable target's source list, alongside the
/// comparable `WhatsNew` and `WelcomeTour` seams, so the invisible-window behaviour
/// this feature fixes cannot silently return through a refactor. The Sparkle
/// user-driver delegate is a translation shim with no decisions of its own: it
/// forwards the appcast item's display version and Sparkle's `handleShowingUpdate`
/// flag into `recordFoundUpdate`, and forwards user attention and session end into
/// `dismiss`. `AppRootModel` wraps this in an `ObservableObject` to drive the toast
/// overlay, exactly as it already does for the tour and What's-New.
///
/// (The menu-bar badge that also reads the pending state is issue #128, and the
/// four-hour check cadence and launch-time check are issue #129; this ticket, #127,
/// is the toast and the gentle-reminder plumbing it needs.)
public struct UpdateReminder: Equatable, Sendable {
    /// A pending update a background check found and handed to the app to present.
    public struct PendingUpdate: Equatable, Sendable {
        /// The version name from Sparkle's appcast item (its display version), or
        /// `nil`/empty when the appcast supplied none. The display string falls back
        /// to generic wording rather than naming an empty version.
        let versionName: String?

        public init(versionName: String?) {
            self.versionName = versionName
        }
    }

    /// The update currently pending the user's attention, or `nil` when none is —
    /// nothing found yet, or the reminder was dismissed. Every surface (toast and
    /// badge) is a function of this one value.
    public private(set) var pending: PendingUpdate?

    public init(pending: PendingUpdate? = nil) {
        self.pending = pending
    }

    /// Records the outcome of Sparkle beginning to show an update, forwarded
    /// verbatim by the user-driver delegate shim.
    ///
    /// The guard is the whole point of the seam: a user-initiated check
    /// (`handledBySparkle == true`) means Sparkle's own dialog is being presented in
    /// focus, so the toast must never appear — recording is a no-op. Only the
    /// gentle-reminder path (a background check, `handledBySparkle == false`) records
    /// a pending update. A later found update after a dismissal records again, so the
    /// reminder resurfaces on the next check.
    ///
    /// - Parameters:
    ///   - handledBySparkle: whether Sparkle's standard user driver is presenting the
    ///     update itself (a user-initiated "Check for Updates…").
    ///   - versionName: the appcast item's display version, or `nil`/empty when it
    ///     carries none.
    public mutating func recordFoundUpdate(handledBySparkle: Bool, versionName: String?) {
        guard !handledBySparkle else { return }
        pending = PendingUpdate(versionName: versionName)
    }

    /// Whether the toast should be shown over `surface`. Visible on the board and
    /// the Settings surface; hidden on What's-New, so a user who has just upgraded
    /// and is reading the release notes is not told to upgrade again.
    public func isToastVisible(on surface: AppSurface) -> Bool {
        guard pending != nil else { return false }
        switch surface {
        case .board, .settings:
            return true
        case .whatsNew:
            return false
        }
    }

    /// The toast's headline, naming the version when the appcast supplied one and
    /// falling back to generic wording otherwise — never an empty string. `nil` when
    /// nothing is pending.
    public var toastMessage: String? {
        guard let pending else { return nil }
        return Self.message(forVersionName: pending.versionName)
    }

    /// The toast headline for a given appcast version name. An absent, empty, or
    /// whitespace-only name falls back to generic wording rather than rendering
    /// "Version  is available".
    static func message(forVersionName versionName: String?) -> String {
        let trimmed = versionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "A new version is available"
        }
        return "Version \(trimmed) is available"
    }

    /// Dismisses the reminder — clears the toast. Shared by the Later button, the
    /// user giving the update its attention (opening Sparkle's dialog), and the
    /// update session ending. A subsequent background check that finds an update
    /// records it again, so dismissing once does not mean the user stops being
    /// reminded on future checks.
    public mutating func dismiss() {
        pending = nil
    }
}
