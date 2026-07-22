import Foundation

/// One release's entry in the bundled `CHANGELOG.md` — a version, its release
/// date, and the user-facing highlight bullets shown on the What's-New surface
/// (issue #73). Pure value type so the parse + version-diff logic is tested at its
/// seam without a running app.
public struct ChangelogEntry: Equatable, Sendable {
    /// The release version, e.g. `0.1.2` (no `v` prefix — that is a display
    /// concern owned by `AppVersion`).
    public let version: String
    /// The release date exactly as written in the header, e.g. `2026-07-22`.
    /// Free-form text; the parser does not interpret it.
    public let date: String
    /// The highlight bullets under the header, in document order, each with its
    /// leading `- ` marker stripped.
    public let highlights: [String]

    public init(version: String, date: String, highlights: [String]) {
        self.version = version
        self.date = date
        self.highlights = highlights
    }
}

/// Parses the bundled `CHANGELOG.md` and compares versions. `CHANGELOG.md` is the
/// single source of truth for release notes (issue #73): each release is a
/// `## <version> — <date>` section with `- ` highlight bullets, newest first. The
/// app bundles the file and shows the newest highlights after an upgrade; the
/// release pipeline derives each GitHub release's notes from the matching section.
public enum Changelog {
    /// The separator between the version and the date in a section header
    /// (`## <version> — <date>`) — a space-padded em dash.
    private static let headerSeparator = " — "

    /// Parses changelog markdown into per-version entries, preserving document
    /// order (the file is authored newest-first, so entry order is newest-first).
    ///
    /// Recognizes only level-2 (`## `) headers as version sections; the top-level
    /// `# Changelog` title and any intro prose are ignored. A header may omit the
    /// `— <date>` separator, in which case the whole remainder is the version and
    /// the date is empty. Highlight lines start with `- ` (after optional leading
    /// whitespace); every other line inside a section is ignored, so blank lines
    /// and wrapped prose never become spurious highlights.
    public static func parse(_ markdown: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var currentVersion: String?
        var currentDate = ""
        var currentHighlights: [String] = []

        func flush() {
            if let version = currentVersion {
                entries.append(
                    ChangelogEntry(version: version, date: currentDate, highlights: currentHighlights)
                )
            }
            currentVersion = nil
            currentDate = ""
            currentHighlights = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("## ") {
                flush()
                let header = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if let range = header.range(of: headerSeparator) {
                    currentVersion = String(header[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    currentDate = String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    currentVersion = header
                    currentDate = ""
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if currentVersion != nil, trimmed.hasPrefix("- ") {
                currentHighlights.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return entries
    }

    /// Whether `lhs` is a strictly newer version than `rhs`, compared by numeric
    /// dot-separated components (so `0.1.10` is newer than `0.1.9`). Missing
    /// trailing components count as zero (`1.2` == `1.2.0`); any non-numeric
    /// component contributes its leading digits, or zero if it has none. This is
    /// the gate the What's-New surface uses: it shows only when the current version
    /// is newer than the last one seen.
    public static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = components(lhs)
        let right = components(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Splits a version string into numeric components, each the leading digits of
    /// a dot-separated part (`"0.1.2"` -> `[0, 1, 2]`).
    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".", omittingEmptySubsequences: false).map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
}
