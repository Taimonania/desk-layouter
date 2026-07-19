import Foundation

/// One application card shown in a Desktop column of the board: its bundle
/// identifier, display name, and the Desktop it is currently assigned to in the
/// working (pending) configuration.
///
/// This is a pure projection value with no AppKit dependency; the real
/// application icon is resolved separately in the macOS layer.
public struct BoardCard: Equatable, Sendable, Identifiable {
    public let bundleIdentifier: String
    public let displayName: String
    public let desktopNumber: Int

    public init(bundleIdentifier: String, displayName: String, desktopNumber: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.desktopNumber = desktopNumber
    }

    /// Stable identity for drag sources and list diffing: a managed application
    /// is assigned to exactly one Desktop, so its bundle identifier is unique
    /// across the whole board.
    public var id: String { bundleIdentifier }
}

/// One Desktop destination column on the board: its 1-based positional number
/// (Desktop 1, 2, 3, …) and the application cards assigned to it in the working
/// configuration.
public struct DesktopColumn: Equatable, Sendable, Identifiable {
    public let number: Int
    public let cards: [BoardCard]

    public init(number: Int, cards: [BoardCard]) {
        self.number = number
        self.cards = cards
    }

    public var id: Int { number }

    /// The number of Assignments in this Desktop, shown in the column header.
    public var assignmentCount: Int { cards.count }
}

/// The board's pending-state model: the working (editable) configuration paired
/// with a snapshot of the Assignments as they stood after the last successful
/// Apply.
///
/// This is the board's pure, unit-tested seam. It holds no Desktop count of its
/// own — the number of Desktops is a property of the live system, passed in when
/// projecting columns — and it never touches the filesystem, AppKit, or the
/// macOS Spaces store. Every board interaction (adding an application, moving a
/// card by drag or keyboard, removing a card) funnels through one of its
/// transitions, and the difference between the working configuration and the
/// applied baseline is what tells the UI whether changes are pending and how
/// many.
///
/// Editing the working configuration never touches macOS: only ``markApplied()``
/// advances the baseline, and it is called after the adapter has actually
/// written the new bindings.
public struct BoardState: Codable, Equatable, Sendable {
    /// The working source of truth — the Assignments the user is editing. This is
    /// the same model the planner and adapter consume on Apply.
    public private(set) var configuration: DeskLayouterConfiguration

    /// The Desktop each managed application was assigned to as of the last
    /// successful Apply (`bundleIdentifier → Desktop number`). The board diffs the
    /// working configuration against this baseline to know what is pending; it is
    /// persisted so the pending-versus-applied distinction survives quitting and
    /// relaunching Desk Layouter.
    public private(set) var appliedBaseline: [String: Int]

    /// Creates a board state. When no explicit baseline is supplied the working
    /// configuration is treated as already applied (clean), which is the correct
    /// default both for a brand-new empty configuration and for migrating a
    /// previously saved configuration that predates pending-state tracking.
    public init(
        configuration: DeskLayouterConfiguration = DeskLayouterConfiguration(),
        appliedBaseline: [String: Int]? = nil
    ) {
        self.configuration = configuration
        self.appliedBaseline = appliedBaseline ?? BoardState.baseline(from: configuration)
    }

    private enum CodingKeys: String, CodingKey {
        case configuration
        case appliedBaseline
    }

    // Tolerant decoding: a persisted state written before pending-state tracking
    // (or hand-authored without a baseline) loads as clean rather than falsely
    // dirty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let configuration = try container.decode(
            DeskLayouterConfiguration.self,
            forKey: .configuration
        )
        self.configuration = configuration
        appliedBaseline = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .appliedBaseline
        ) ?? BoardState.baseline(from: configuration)
    }

    // MARK: - Column projection

    /// Projects the working configuration into one column per Desktop, in
    /// positional order (Desktop 1, 2, 3, …), for the given number of Desktops on
    /// the built-in display.
    ///
    /// The count comes from the live Desktop snapshot, so the board renders as
    /// many columns as the machine actually has — whether that is one, three, or
    /// more. With no Desktops the board has no columns rather than trapping. A
    /// card whose Desktop number falls outside the current range (its Desktop was
    /// removed after the Assignment was saved) is left out of every column; the
    /// adapter deletes such stale keys on the next Apply, matching the planner's
    /// skip-out-of-range behavior.
    public func columns(desktopCount: Int) -> [DesktopColumn] {
        guard desktopCount > 0 else { return [] }
        var cardsByDesktop: [Int: [BoardCard]] = [:]
        for application in configuration.managedApplications {
            cardsByDesktop[application.desktopNumber, default: []].append(
                BoardCard(
                    bundleIdentifier: application.bundleIdentifier,
                    displayName: application.displayName,
                    desktopNumber: application.desktopNumber
                )
            )
        }
        return (1...desktopCount).map { number in
            DesktopColumn(number: number, cards: cardsByDesktop[number] ?? [])
        }
    }

    // MARK: - Pending-state derivation

    /// The bundle identifiers whose effective Assignment differs between the
    /// working configuration and the applied baseline — the additions (present in
    /// the working set but not the baseline), the moves (assigned to a different
    /// Desktop), and the removals (present in the baseline but no longer managed).
    public var pendingChanges: [String] {
        let working = BoardState.baseline(from: configuration)
        var changed: Set<String> = []
        for (bundleIdentifier, desktopNumber) in working
        where appliedBaseline[bundleIdentifier] != desktopNumber {
            changed.insert(bundleIdentifier)
        }
        for bundleIdentifier in appliedBaseline.keys where working[bundleIdentifier] == nil {
            changed.insert(bundleIdentifier)
        }
        return changed.sorted()
    }

    /// The number of unapplied changes, shown next to Apply when the board is
    /// dirty.
    public var pendingChangeCount: Int { pendingChanges.count }

    /// True when the working configuration differs from what was last applied, so
    /// Apply has work to do. When false the board is clean and Apply is disabled.
    public var isDirty: Bool { !pendingChanges.isEmpty }

    // MARK: - Transitions

    /// Adds an application to the board, or updates its Assignment if it is
    /// already managed. This is the Add App flow's transition.
    public mutating func assign(_ application: ManagedApplication) {
        configuration.upsert(application)
    }

    /// Moves a managed application's card to another Desktop, preserving its
    /// display name. Both drag-and-drop and the keyboard arrow controls funnel
    /// through here. Moving an unmanaged bundle identifier, or moving to the
    /// Desktop the card already occupies, is a harmless no-op.
    public mutating func move(bundleIdentifier: String, toDesktop desktopNumber: Int) {
        guard let application = configuration.managedApplication(for: bundleIdentifier),
              application.desktopNumber != desktopNumber
        else {
            return
        }
        configuration.upsert(
            ManagedApplication(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.displayName,
                desktopNumber: desktopNumber
            )
        )
    }

    /// Removes an application's Assignment from the board. Only the named app is
    /// affected; every other card, and every unmanaged macOS binding, is left
    /// alone. The removal is remembered so the next Apply deletes only its owned
    /// key.
    public mutating func remove(bundleIdentifier: String) {
        configuration.remove(bundleIdentifier: bundleIdentifier)
    }

    /// Advances the applied baseline to match the working configuration after a
    /// successful Apply, so the board becomes clean, and clears the pending
    /// removals the adapter has now deleted. Call this only once the adapter has
    /// actually written the new bindings.
    public mutating func markApplied() {
        configuration.clearPendingRemovals()
        appliedBaseline = BoardState.baseline(from: configuration)
    }

    private static func baseline(from configuration: DeskLayouterConfiguration) -> [String: Int] {
        Dictionary(
            configuration.managedApplications.map { ($0.bundleIdentifier, $0.desktopNumber) },
            uniquingKeysWith: { _, latest in latest }
        )
    }
}

/// Pure JSON serialization for the board state — the encode/decode seam, with no
/// filesystem access. File I/O lives behind `BoardStateStore` in the macOS
/// adapter layer, mirroring `ConfigurationSerialization`/`ConfigurationStore`.
public enum BoardStateSerialization {
    public static func encode(_ boardState: BoardState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(boardState)
    }

    public static func decode(from data: Data) throws -> BoardState {
        try JSONDecoder().decode(BoardState.self, from: data)
    }
}
