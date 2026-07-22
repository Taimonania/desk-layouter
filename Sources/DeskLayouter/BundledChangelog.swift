import Foundation

/// Reads the `CHANGELOG.md` bundled into the app's `Contents/Resources` (issue
/// #73). This is the thin impure edge; the parse + version-diff logic lives in the
/// tested `Changelog`/`WhatsNew` seams. `build-app.sh` copies `CHANGELOG.md` into
/// Resources, so the packaged app finds it; the unbundled `swift run` build has no
/// such resource and reads `nil` — a graceful fallback that (together with the dev
/// build having no version) keeps What's-New silent when unbundled.
enum BundledChangelog {
    /// The bundled changelog text, or `nil` when it is not present (the unbundled
    /// `swift run` build). Defaults to `Bundle.main` — the packaged app.
    static func text(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
