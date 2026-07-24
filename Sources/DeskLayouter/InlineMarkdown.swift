import Foundation

/// Renders a changelog highlight's inline Markdown (bold, italic, code, links) into
/// an `AttributedString` for display (issue #116).
///
/// The changelog is authored in Markdown — `CHANGELOG.md` bullets carry `**bold**`
/// emphasis — but the highlights reach the view as plain `String` values. SwiftUI's
/// `Text` only auto-parses Markdown for *string literals* (via `LocalizedStringKey`),
/// never for a `String` variable, so `Text(highlight)` shows the raw `**` markers.
/// This helper does the parsing explicitly.
///
/// Parsing is inline-only: highlights are single phrases, not documents, so block
/// constructs (headings, lists, paragraphs) must not be interpreted, and whitespace
/// is preserved. If parsing ever fails, the raw source is returned verbatim so a
/// malformed bullet degrades to plain text rather than vanishing.
///
/// Kept in `DeskLayouterMacOS` (Foundation-only, no SwiftUI) so it is testable at its
/// seam without a running app.
public func inlineMarkdownAttributedString(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
}
