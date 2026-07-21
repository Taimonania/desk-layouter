/// The single user-facing application-naming rule for all of Desk Layouter
/// (issue #39).
///
/// Application names reach the app from macOS in a few shapes — a bundle's file
/// name (`Spotify.app`), a localized name, or a name persisted in an older
/// Assignment — and users think in terms of the application ("Spotify"), never
/// its bundle file name. This is the one place that decides how a name is shown,
/// so every card, search result, Layout editor line, and Apply/Arrange feedback
/// sentence presents names identically.
///
/// It is a *display-only* transform: the raw `displayName` and the
/// `bundleIdentifier` are left untouched wherever they are needed for lookup,
/// persistence, or matching. Callers keep the raw value and ask for the
/// presented form only when rendering.
///
/// Foundation-free by design (stdlib string operations only) so the equally
/// Foundation-free ``ArrangeReportPresenter`` can share the rule.
public enum ApplicationDisplayName {
    /// The name to show the user for `rawName`: the raw name with a single
    /// trailing `.app` removed, compared case-insensitively.
    ///
    /// Only a genuinely trailing `.app` is removed — `Notes.app.app` drops one
    /// `.app` to become `Notes.app`, and a `.app` appearing anywhere else
    /// (`Foo.appliance`, `Cool.app Suite`) is left exactly as it was.
    public static func presented(_ rawName: String) -> String {
        let suffix = ".app"
        guard rawName.count >= suffix.count,
              rawName.suffix(suffix.count).lowercased() == suffix
        else {
            return rawName
        }
        return String(rawName.dropLast(suffix.count))
    }
}
