import DeskLayouterCore
import Foundation

@main
struct VersionTestRunner {
    static func main() {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok: \(name)")
            } else {
                let detailText = detail()
                let suffix = detailText.isEmpty ? "" : " — \(detailText)"
                failures.append("\(name)\(suffix)")
                print("  FAIL: \(name)\(suffix)")
            }
        }

        // A packaged build carries CFBundleShortVersionString; it renders with a
        // leading `v` so the editor shows e.g. `v0.1.1`.
        do {
            check(
                "packaged version renders with a v prefix",
                AppVersion.displayString(fromShortVersion: "0.1.1") == "v0.1.1",
                AppVersion.displayString(fromShortVersion: "0.1.1")
            )
        }

        // The unbundled `swift run` build has no Info.plist, so the raw lookup is
        // nil. The helper must fall back to `dev` rather than crash or show blank.
        do {
            check(
                "nil version falls back to dev",
                AppVersion.displayString(fromShortVersion: nil) == "dev",
                AppVersion.displayString(fromShortVersion: nil)
            )
            check("developmentFallback is dev", AppVersion.developmentFallback == "dev")
        }

        // A present-but-blank value (whitespace only) is treated the same as
        // missing — the control never renders an empty or whitespace label.
        do {
            check(
                "empty version falls back to dev",
                AppVersion.displayString(fromShortVersion: "") == "dev",
                AppVersion.displayString(fromShortVersion: "")
            )
            check(
                "whitespace version falls back to dev",
                AppVersion.displayString(fromShortVersion: "  ") == "dev",
                AppVersion.displayString(fromShortVersion: "  ")
            )
        }

        // Surrounding whitespace on a real version is trimmed before the prefix,
        // so a stray newline in the plist never leaks into the label.
        do {
            check(
                "surrounding whitespace is trimmed",
                AppVersion.displayString(fromShortVersion: " 1.2.3 ") == "v1.2.3",
                AppVersion.displayString(fromShortVersion: " 1.2.3 ")
            )
        }

        // The impure edge, exercised against the test's own bundle, which has no
        // CFBundleShortVersionString — the same shape as the unbundled `swift run`
        // build — so `current` must fall back to `dev` rather than crash.
        do {
            check(
                "current falls back to dev for a bundle without the key",
                AppVersion.current(bundle: Bundle(for: BundleAnchor.self)) == "dev",
                AppVersion.current(bundle: Bundle(for: BundleAnchor.self))
            )
        }

        // The raw semantic version (issue #73) never substitutes the `dev`
        // fallback — `nil` is the signal there is no real version to compare.
        do {
            check(
                "semanticVersion returns the trimmed raw version",
                AppVersion.semanticVersion(fromShortVersion: " 0.1.2 ") == "0.1.2",
                AppVersion.semanticVersion(fromShortVersion: " 0.1.2 ") ?? "nil"
            )
            check(
                "semanticVersion is nil for a missing version (no dev fallback)",
                AppVersion.semanticVersion(fromShortVersion: nil) == nil
            )
            check(
                "semanticVersion is nil for a blank version",
                AppVersion.semanticVersion(fromShortVersion: "  ") == nil
            )
            check(
                "currentSemanticVersion is nil for a bundle without the key",
                AppVersion.currentSemanticVersion(bundle: Bundle(for: BundleAnchor.self)) == nil
            )
        }

        if failures.isEmpty {
            print("App version tests passed")
        } else {
            fatalError("App version tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}

/// Anchors `Bundle(for:)` on the test executable's bundle, which — like the
/// unbundled `swift run` app — carries no CFBundleShortVersionString.
private final class BundleAnchor {}
