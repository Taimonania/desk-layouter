import DeskLayouterCore

@main
struct ChangelogTestRunner {
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

        // MARK: - Parsing

        let sample = """
        # Changelog

        Intro prose that must never be parsed as a highlight.

        ## 0.1.2 — 2026-08-01

        - First highlight for the new version.
        - Second highlight.

        ## 0.1.1 — 2026-07-22

        - Auto-update via Sparkle.
        - Presets: create, load, update.

        ## 0.1.0 — 2026-07-21

        - First public release.
        """

        do {
            let entries = Changelog.parse(sample)
            check("parses one entry per version section", entries.count == 3, "got \(entries.count)")
            check(
                "entries are in document order (newest first)",
                entries.map(\.version) == ["0.1.2", "0.1.1", "0.1.0"],
                "\(entries.map(\.version))"
            )
            check(
                "parses the version and date from the header",
                entries.first?.version == "0.1.2" && entries.first?.date == "2026-08-01",
                "\(String(describing: entries.first))"
            )
            check(
                "collects the highlight bullets with the marker stripped",
                entries.first?.highlights == ["First highlight for the new version.", "Second highlight."],
                "\(entries.first?.highlights ?? [])"
            )
            check(
                "intro prose and the title are not treated as highlights",
                entries.allSatisfy { !$0.highlights.contains(where: { $0.contains("Intro prose") }) }
            )
            check(
                "the 0.1.1 section keeps both of its highlights",
                entries[1].highlights.count == 2,
                "\(entries[1].highlights)"
            )
        }

        do {
            // A header without the "— <date>" separator: whole remainder is version.
            let entries = Changelog.parse("## 1.0.0\n\n- Only a version, no date.")
            check(
                "a header without a date parses the version and an empty date",
                entries.first?.version == "1.0.0" && entries.first?.date == "",
                "\(String(describing: entries.first))"
            )
        }

        do {
            check("empty input parses to no entries", Changelog.parse("").isEmpty)
            check(
                "input with no version sections parses to no entries",
                Changelog.parse("# Changelog\n\nJust prose.").isEmpty
            )
        }

        // MARK: - Version comparison

        do {
            check("a higher patch is newer", Changelog.isVersion("0.1.2", newerThan: "0.1.1"))
            check("a lower patch is not newer", !Changelog.isVersion("0.1.1", newerThan: "0.1.2"))
            check("an equal version is not newer than itself", !Changelog.isVersion("0.1.1", newerThan: "0.1.1"))
            check("numeric (not lexical) comparison: 0.1.10 > 0.1.9", Changelog.isVersion("0.1.10", newerThan: "0.1.9"))
            check("a higher minor is newer", Changelog.isVersion("0.2.0", newerThan: "0.1.9"))
            check("a higher major is newer", Changelog.isVersion("1.0.0", newerThan: "0.9.9"))
            check("missing trailing components count as zero (1.2 == 1.2.0)", !Changelog.isVersion("1.2", newerThan: "1.2.0"))
            check("1.2.1 is newer than 1.2", Changelog.isVersion("1.2.1", newerThan: "1.2"))
        }

        if failures.isEmpty {
            print("Changelog tests passed")
        } else {
            fatalError("Changelog tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
