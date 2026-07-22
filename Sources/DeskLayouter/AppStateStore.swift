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
}
