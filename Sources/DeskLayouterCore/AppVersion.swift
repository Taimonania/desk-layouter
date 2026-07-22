import Foundation

/// The app version shown in the editor (issue #70).
///
/// The packaged `.app` carries a `CFBundleShortVersionString` in its Info.plist,
/// but the unbundled `swift run` build has no Info.plist at all — so the raw
/// lookup can come back `nil` or blank. `displayString(fromShortVersion:)` is the
/// pure seam that turns that optional into the string the UI renders; `current`
/// is the thin impure edge that reads it from a bundle.
public enum AppVersion {
    /// Shown when there is no bundled version string — the unbundled `swift run`
    /// case — so the control never renders blank or crashes.
    public static let developmentFallback = "dev"

    /// Maps the raw `CFBundleShortVersionString` value to the editor's version
    /// label. A packaged build renders `v<version>` (e.g. `v0.1.1`); a missing or
    /// blank value renders the `dev` fallback.
    public static func displayString(fromShortVersion shortVersion: String?) -> String {
        let trimmed = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return developmentFallback }
        return "v\(trimmed)"
    }

    /// The version label for the running build, read from `bundle`'s Info
    /// dictionary. Defaults to `Bundle.main` (the packaged app); the unbundled
    /// build has no such key and falls back to `dev`.
    public static func current(bundle: Bundle = .main) -> String {
        displayString(
            fromShortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }
}
