import Foundation

/// A small `UserDefaults`-backed store for app-level preferences that are not part
/// of the board/preset domain model (which is JSON-file-backed under Application
/// Support). Issue #71 introduces the first such preference — whether Sparkle
/// downloads and installs updates automatically, or asks first.
///
/// The `UserDefaults` instance is injected so the store can be tested at its seam
/// with an isolated suite instead of the shared standard defaults.
public final class AppStateStore {
    private enum Key {
        static let automaticallyInstallUpdates = "automaticallyInstallUpdates"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let lastSeenVersion = "lastSeenVersion"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether updates are downloaded and installed automatically (`true`) or the
    /// user is asked first (`false`). Defaults to **Ask** (`false`): an absent key
    /// reads as `false`, so a fresh install never installs updates unattended.
    ///
    /// This drives Sparkle's `automaticallyDownloadsUpdates`. Automatic update
    /// *checking* is independent and stays always-on regardless of this value.
    public var automaticallyInstallUpdates: Bool {
        get { defaults.bool(forKey: Key.automaticallyInstallUpdates) }
        set { defaults.set(newValue, forKey: Key.automaticallyInstallUpdates) }
    }

    /// Whether the user has seen the Welcome guided tour (issue #72). Defaults to
    /// `false` — an absent key reads as `false`, so a fresh install shows the
    /// Welcome tour automatically on first launch. It is set to `true` when the
    /// tour is dismissed (Skip or Done) so the tour never reappears on its own; the
    /// Help (`?`) button re-opens it on demand regardless of this flag.
    public var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: Key.hasSeenWelcome) }
        set { defaults.set(newValue, forKey: Key.hasSeenWelcome) }
    }

    /// The app version whose What's-New surface the user has already seen (issue
    /// #73), or `nil` when none has been stored — a fresh install. The What's-New
    /// surface shows only when the running version is newer than this, and this is
    /// updated to the running version once the surface is dismissed, so it shows
    /// once per upgrade. `nil` (fresh install) suppresses What's-New entirely so
    /// the Welcome tour owns first-run.
    public var lastSeenVersion: String? {
        get { defaults.string(forKey: Key.lastSeenVersion) }
        set { defaults.set(newValue, forKey: Key.lastSeenVersion) }
    }
}
