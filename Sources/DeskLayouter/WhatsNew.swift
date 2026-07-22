import DeskLayouterCore

/// The What's-New surface's presentation state and the launch-time decision that
/// produces it (issue #73). On the first launch after the app version increases,
/// the editor shows a full-window surface: a "You now run vX.Y.Z" headline plus
/// the highlights of every version the user skipped, grouped by version. This
/// value type owns only the *logic* — which versions to show and whether to show
/// at all — so the version-diff and grouping are tested at their seam without a
/// running app or SwiftUI. The executable wraps it in `AppRootModel` to drive the
/// surface and persist `lastSeenVersion` on dismissal.
///
/// (Called a "screen" in the issue, but modeled as an in-window surface like
/// Settings; CONTEXT.md reserves "Screen" as an avoided synonym for
/// Display/Desktop, so the code says "surface"/"What's-New".)
public struct WhatsNew: Equatable, Sendable {
    /// Whether the What's-New surface is currently shown.
    public private(set) var isPresented: Bool

    /// The raw version the user is now running (no `v` prefix), e.g. `0.1.2`. The
    /// view renders the headline as "You now run v\(version)". This is also the
    /// value persisted as `lastSeenVersion` once the surface is dismissed.
    public let version: String

    /// The changelog entries to show, newest first — every version in the range
    /// `(lastSeen, current]`, so a user who skipped several releases sees each
    /// skipped version's highlights grouped under its own heading. Empty only when
    /// the changelog has no matching entries (a version bump with no changelog
    /// section), in which case the headline still shows.
    public let sections: [ChangelogEntry]

    public init(isPresented: Bool, version: String, sections: [ChangelogEntry]) {
        self.isPresented = isPresented
        self.version = version
        self.sections = sections
    }

    /// Dismisses the surface (the "Done" control). The executable persists
    /// `lastSeenVersion = version` in response so it shows once per upgrade.
    public mutating func dismiss() {
        isPresented = false
    }
}

/// The launch-time decision for the What's-New surface, computed by
/// `WhatsNew.onLaunch`. Kept explicit (rather than an optional) so the executable
/// handles all three outcomes deliberately — in particular the fresh-install case,
/// which persists a baseline *without* showing anything.
public enum WhatsNewLaunch: Equatable, Sendable {
    /// Show nothing and persist nothing: a dev/unbundled build (no version), or a
    /// launch on an equal or lower version (nothing new to announce, and never a
    /// downgrade prompt).
    case none

    /// A fresh install (no stored `lastSeenVersion`): record `version` as the
    /// baseline so a *later* upgrade triggers What's-New, but show nothing now —
    /// the Welcome tour owns first-run, and What's-New must never pre-empt it.
    case recordBaseline(version: String)

    /// Present the What's-New surface; the executable persists `lastSeenVersion`
    /// (the surface's `version`) once it is dismissed.
    case present(WhatsNew)
}

extension WhatsNew {
    /// Decides what the What's-New surface should do at launch, given the running
    /// build's raw version (`nil` on a dev/unbundled build), the persisted
    /// `lastSeenVersion` (`nil` on a fresh install), and the parsed changelog
    /// entries (newest first).
    ///
    /// The gate:
    /// - no current version (dev build) -> `.none`;
    /// - no stored version (fresh install) -> `.recordBaseline` (Welcome takes
    ///   precedence, so nothing shows, but the baseline is recorded so the next
    ///   upgrade announces itself);
    /// - current not newer than last seen (equal or downgrade) -> `.none`;
    /// - otherwise -> `.present`, with the sections limited to the versions in
    ///   `(lastSeen, current]` so only genuinely-new highlights appear, grouped by
    ///   version.
    public static func onLaunch(
        currentVersion: String?,
        lastSeenVersion: String?,
        entries: [ChangelogEntry]
    ) -> WhatsNewLaunch {
        guard let currentVersion else { return .none }
        guard let lastSeenVersion else { return .recordBaseline(version: currentVersion) }
        guard Changelog.isVersion(currentVersion, newerThan: lastSeenVersion) else { return .none }

        let sections = entries.filter { entry in
            Changelog.isVersion(entry.version, newerThan: lastSeenVersion)
                && !Changelog.isVersion(entry.version, newerThan: currentVersion)
        }
        return .present(WhatsNew(isPresented: true, version: currentVersion, sections: sections))
    }
}
