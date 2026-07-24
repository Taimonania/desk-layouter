import DeskLayouterMacOS
import Foundation

/// Covers `inlineMarkdownAttributedString`, which renders a changelog highlight's
/// inline Markdown for the What's-New surface (issue #116). The bug it guards
/// against: `**bold**` reaching the view as a plain `String` and rendering with
/// literal asterisks instead of bold text.
@main
struct InlineMarkdownTestRunner {
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

        // Whether any run of the attributed string carries strong (bold) emphasis.
        func hasBoldRun(_ attributed: AttributedString) -> Bool {
            attributed.runs.contains { run in
                run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
            }
        }

        // `**...**` is interpreted as bold, and the asterisks are gone from the text.
        do {
            let rendered = inlineMarkdownAttributedString("**Enable more rows** and columns")
            check("bold markers produce a bold run", hasBoldRun(rendered))
            check(
                "bold markers are stripped from the visible text",
                String(rendered.characters) == "Enable more rows and columns",
                "got: \(String(rendered.characters))"
            )
        }

        // Plain text with no markup stays plain — same characters, no bold run.
        do {
            let rendered = inlineMarkdownAttributedString("A clearer first-run Welcome tour")
            check(
                "plain text is preserved verbatim",
                String(rendered.characters) == "A clearer first-run Welcome tour",
                "got: \(String(rendered.characters))"
            )
            check("plain text has no bold run", !hasBoldRun(rendered))
        }

        // An unterminated marker is not valid emphasis: it degrades to plain text
        // (the asterisks are shown literally) rather than vanishing or crashing.
        do {
            let rendered = inlineMarkdownAttributedString("Half **open emphasis")
            check("unterminated emphasis has no bold run", !hasBoldRun(rendered))
            check(
                "unterminated emphasis keeps its literal asterisks",
                String(rendered.characters).contains("**"),
                "got: \(String(rendered.characters))"
            )
        }

        if failures.isEmpty {
            print("All InlineMarkdown tests passed.")
        } else {
            print("\n\(failures.count) InlineMarkdown test(s) failed:")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
    }
}
