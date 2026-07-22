// Renders the outcome of an Arrange pass as the user-facing feedback shown
// beneath the board (issue #34, ADR-0003).
//
// This is the pure, Foundation-free heart of the reporting: given only value
// inputs — the display names that were arranged, skipped, or resisted, the
// numbered active Desktop, and the Desktops still armed for their first visit —
// it composes the message and decides whether the pass reads as a success or an
// error. Keeping it here (rather than in the macOS `EditorModel`) means every
// wording branch is unit-testable without a live window server: singular vs.
// plural names, the numbered Desktop, skipped applications, resistant windows,
// and a later armed-Desktop pass.
//
// It emits plain sentences only — no localization-inflection markup or other
// formatting syntax ever reaches the rendered string (issue #34, AC 8).
public enum ArrangeReportPresenter {
    /// Whether the pass should read as a success or an error. A window that
    /// refused to move or resize is the only error; a skipped application with
    /// no available window never turns the whole pass into one (AC 4).
    public enum Tone: Equatable, Sendable {
        case success
        case failure
    }

    /// The rendered feedback: the message text plus how it should read.
    public struct Announcement: Equatable, Sendable {
        public let message: String
        public let tone: Tone

        public init(message: String, tone: Tone) {
            self.message = message
            self.tone = tone
        }
    }

    /// Builds the announcement for one Arrange pass on `activeDesktop`.
    ///
    /// - Parameters:
    ///   - activeDesktop: the numbered Desktop the pass ran on, or `nil` when it
    ///     could not be identified (then named as "the active Desktop").
    ///   - arranged: display names of applications whose window was moved into
    ///     place and verified there.
    ///   - skipped: display names of managed-with-Layout applications that had no
    ///     available window on the active Desktop.
    ///   - resisted: display names of applications whose window refused to move
    ///     or resize.
    ///   - pendingDesktops: the numbered Desktops still armed, each to be
    ///     arranged the first time it becomes active.
    public static func announce(
        activeDesktop: Int?,
        arranged: [String],
        skipped: [String],
        resisted: [String],
        pendingDesktops: [Int]
    ) -> Announcement {
        // Apply the shared user-facing naming rule (issue #39) before sorting and
        // listing, so no ".app" suffix ever reaches an Arrange sentence regardless
        // of the raw names the caller threads in.
        let arranged = sortedNames(arranged.map(ApplicationDisplayName.presented))
        let skipped = sortedNames(skipped.map(ApplicationDisplayName.presented))
        let resisted = sortedNames(resisted.map(ApplicationDisplayName.presented))
        let pending = pendingDesktops.sorted()
        let desktop = desktopPhrase(activeDesktop)

        var sentences: [String] = []

        if !arranged.isEmpty {
            sentences.append("Arranged \(list(arranged)) on \(desktop).")
        } else if resisted.isEmpty {
            // Nothing moved and nothing resisted: every candidate lacked an
            // available window (or there were none at all). The lead sentence
            // covers this, so skipped apps are not enumerated again (AC 5).
            sentences.append("No available windows to arrange on \(desktop).")
        }

        // Name skipped applications only alongside a pass that did move or
        // resist something; when nothing had a window the lead sentence above
        // already says so (AC 4 vs. AC 5).
        if (!arranged.isEmpty || !resisted.isEmpty) && !skipped.isEmpty {
            sentences.append("Skipped \(list(skipped)) with no available window.")
        }

        if !resisted.isEmpty {
            // Name the Desktop only when no "Arranged …" lead already did, to
            // avoid repeating it within a single message.
            if arranged.isEmpty {
                sentences.append("\(list(resisted)) refused to move or resize on \(desktop).")
            } else {
                sentences.append("\(list(resisted)) refused to move or resize.")
            }
        }

        if !pending.isEmpty {
            let numbers = pending.map(String.init)
            if numbers.count == 1 {
                sentences.append("Desktop \(numbers[0]) will be arranged when you visit it.")
            } else {
                sentences.append("Desktops \(list(numbers)) will be arranged when you visit them.")
            }
        }

        return Announcement(
            message: sentences.joined(separator: " "),
            tone: resisted.isEmpty ? .success : .failure
        )
    }

    /// Reports Layouts deliberately skipped because their saved physical
    /// Displays are unavailable. Names are de-duplicated and sorted so one
    /// Display with several Layouts is reported once.
    public static func unavailableDisplaysMessage(_ displayNames: [String]) -> String {
        let names = sortedNames(Array(Set(displayNames)))
        guard !names.isEmpty else { return "" }
        return "Skipped Layouts on unavailable Displays: \(list(names))."
    }

    /// Display-addressed variant used by multi-Display Arrange. Every result is
    /// explicitly attributed to both the physical Display and Desktop.
    public static func announce(
        displayName: String,
        desktopNumber: Int,
        arranged: [String],
        skipped: [String],
        resisted: [String]
    ) -> Announcement {
        let base = announce(
            activeDesktop: desktopNumber,
            arranged: arranged,
            skipped: skipped,
            resisted: resisted,
            pendingDesktops: []
        )
        return Announcement(
            message: "\(displayName), Desktop \(desktopNumber): \(base.message)",
            tone: base.tone
        )
    }

    private static func desktopPhrase(_ number: Int?) -> String {
        if let number { return "Desktop \(number)" }
        return "the active Desktop"
    }

    /// A deterministic, case-insensitive ordering so the same set of names always
    /// renders in the same order regardless of the engine's iteration order.
    private static func sortedNames(_ names: [String]) -> [String] {
        names.sorted { lhs, rhs in
            let l = lhs.lowercased()
            let r = rhs.lowercased()
            return l == r ? lhs < rhs : l < r
        }
    }

    /// A deterministic natural-language serial list: "A", "A and B", or
    /// "A, B, and C" (Oxford comma) for three or more.
    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return ""
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head), and \(items[items.count - 1])"
        }
    }
}
