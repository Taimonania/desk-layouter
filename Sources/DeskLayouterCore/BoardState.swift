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

    /// Where this app's window sits on its Desktop, or `nil` when it has no
    /// Layout. The board uses this both to distinguish apps that have a Layout
    /// visually and to seed the Layout editor with the app's current Layout.
    public let layout: Layout?

    /// Whether this card's application is present in the live installed-app
    /// catalog. `false` marks a managed application that is not currently
    /// installed (issue #52): its Assignment stays visible and stored with its
    /// display name, is clearly flagged unavailable in the UI, and remains
    /// declarative data that takes effect again if the app is reinstalled — it is
    /// never removed on refresh, Apply, or relaunch, and never by itself disables
    /// Apply. Defaults to `true` so callers that do not track installation status
    /// (the plain ``BoardState/columns(desktopCount:)`` projection) are unaffected.
    public let isApplicationAvailable: Bool

    public init(
        bundleIdentifier: String,
        displayName: String,
        desktopNumber: Int,
        layout: Layout? = nil,
        isApplicationAvailable: Bool = true
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.desktopNumber = desktopNumber
        self.layout = layout
        self.isApplicationAvailable = isApplicationAvailable
    }

    /// Whether this app has a Layout — the flag the board reads to show apps that
    /// have a Layout differently from those that do not.
    public var hasLayout: Bool { layout != nil }

    /// The name to show the user — the raw ``displayName`` with any trailing
    /// `.app` removed (issue #39). ``displayName`` stays raw; only presentation
    /// uses this.
    public var presentedName: String { ApplicationDisplayName.presented(displayName) }

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

    /// The semantic physical-Display destination and concrete Desktop UUID each
    /// managed application had after the last successful Apply. The board diffs
    /// the working configuration against this baseline to know what is pending;
    /// it is persisted so semantic and effective pending state both survive quit.
    public private(set) var appliedAssignments: [String: AppliedAssignment]

    /// Compatibility projection used by existing board callers and by legacy
    /// migration tests. New persistence stores ``appliedAssignments`` under the
    /// historical `appliedBaseline` key so the document evolves in place.
    public var appliedBaseline: [String: Int] {
        appliedAssignments.mapValues(\.desktopNumber)
    }

    /// The identity of the ``Preset`` this working copy was loaded from (or saved
    /// as). The optional representation exists only for backward-compatible
    /// decoding of state written before Presets; launch reconciliation seeds and
    /// associates a real Preset before the editor uses the board. It is persisted
    /// so the association survives quitting and relaunching, and editing the
    /// working copy never clears it — the Preset itself only changes when the user
    /// explicitly updates it.
    public private(set) var selectedPresetID: UUID?

    /// Creates a board state. When no explicit baseline is supplied the working
    /// configuration is treated as already applied (clean), which is the correct
    /// default both for a brand-new empty configuration and for migrating a
    /// previously saved configuration that predates pending-state tracking.
    public init(
        configuration: DeskLayouterConfiguration = DeskLayouterConfiguration(),
        appliedBaseline: [String: Int]? = nil,
        selectedPresetID: UUID? = nil
    ) {
        self.configuration = configuration
        if let appliedBaseline {
            appliedAssignments = appliedBaseline.mapValues {
                AppliedAssignment(display: nil, desktopNumber: $0, concreteDesktopUUID: nil)
            }
        } else {
            appliedAssignments = BoardState.baseline(from: configuration)
        }
        self.selectedPresetID = selectedPresetID
    }

    public init(
        configuration: DeskLayouterConfiguration,
        appliedAssignments: [String: AppliedAssignment],
        selectedPresetID: UUID? = nil
    ) {
        self.configuration = configuration
        self.appliedAssignments = appliedAssignments
        self.selectedPresetID = selectedPresetID
    }

    private enum CodingKeys: String, CodingKey {
        case configuration
        case appliedBaseline
        case selectedPresetID
    }

    // Tolerant decoding: a persisted state written before pending-state tracking
    // (or hand-authored without a baseline) loads as clean rather than falsely
    // dirty. One written before Presets existed temporarily decodes without a
    // selection; launch reconciliation repairs it from the preserved working board.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let configuration = try container.decode(
            DeskLayouterConfiguration.self,
            forKey: .configuration
        )
        self.configuration = configuration
        if let current = try? container.decode(
            [String: AppliedAssignment].self,
            forKey: .appliedBaseline
        ) {
            appliedAssignments = current
        } else if let legacy = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .appliedBaseline
        ) {
            appliedAssignments = legacy.mapValues {
                AppliedAssignment(display: nil, desktopNumber: $0, concreteDesktopUUID: nil)
            }
        } else {
            appliedAssignments = BoardState.baseline(from: configuration)
        }
        selectedPresetID = try container.decodeIfPresent(UUID.self, forKey: .selectedPresetID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(appliedAssignments, forKey: .appliedBaseline)
        try container.encodeIfPresent(selectedPresetID, forKey: .selectedPresetID)
    }

    // MARK: - Column projection

    /// Projects the working configuration into one column per Desktop, in
    /// positional order (Desktop 1, 2, 3, …), for the given number of Desktops on
    /// the active display.
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
                    desktopNumber: application.desktopNumber,
                    layout: application.layout
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
        pendingChanges(on: nil)
    }

    /// Pending Assignments against an optional live snapshot. Semantic changes
    /// compare physical Display + Desktop number; when a snapshot is supplied,
    /// concrete Desktop UUID drift is also pending even if the semantic
    /// destination is unchanged.
    public func pendingChanges(on snapshot: DesktopSnapshot?) -> [String] {
        let working = BoardState.baseline(from: configuration)
        var changed: Set<String> = []
        for (bundleIdentifier, destination) in working {
            guard let applied = appliedAssignments[bundleIdentifier] else {
                changed.insert(bundleIdentifier)
                continue
            }
            guard BoardState.sameSemanticDestination(destination, applied) else {
                changed.insert(bundleIdentifier)
                continue
            }
            if let snapshot,
               let display = destination.display,
               let snapshotDisplay = snapshot.display,
               display.identifiesSameDisplay(as: snapshotDisplay),
               snapshot.concreteDesktopUUID(at: destination.desktopNumber)
                    != applied.concreteDesktopUUID {
                changed.insert(bundleIdentifier)
            }
        }
        for bundleIdentifier in appliedAssignments.keys where working[bundleIdentifier] == nil {
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

    /// Whether at least one Assignment cannot be resolved on the supplied
    /// physical Display. Issue #21 still exposes one logical Display at a time,
    /// so Apply must fail closed when a saved Assignment targets another Display:
    /// otherwise the planner would omit it and the delete-aware adapter could
    /// remove its existing macOS binding. The Assignment remains stored for the
    /// later multi-Display board and recovery slices.
    public func hasUnavailableDisplayAssignments(on snapshot: DesktopSnapshot?) -> Bool {
        guard let activeDisplay = snapshot?.display else {
            return !configuration.managedApplications.isEmpty
        }
        return configuration.managedApplications.contains { application in
            guard let assignedDisplay = application.display else { return true }
            return !assignedDisplay.identifiesSameDisplay(as: activeDisplay)
        }
    }

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
                legacyDisplay: application.display,
                desktopNumber: desktopNumber,
                layout: application.layout
            )
        )
    }

    /// Sets (or with `nil`, clears) a managed application's Layout, preserving its
    /// Desktop Assignment and display name. Setting a Layout arranges *where* on a
    /// Desktop the window sits; it does not change *which* Desktop, so it never
    /// affects the pending-Assignment count — Layout is enacted by Arrange, not
    /// Apply. Passing an unmanaged bundle identifier is a harmless no-op.
    public mutating func setLayout(_ layout: Layout?, forBundleIdentifier bundleIdentifier: String) {
        guard let application = configuration.managedApplication(for: bundleIdentifier) else {
            return
        }
        configuration.upsert(
            ManagedApplication(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.displayName,
                legacyDisplay: application.display,
                desktopNumber: application.desktopNumber,
                layout: layout
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

    /// Loads a Preset's board as the working copy, associating the working copy
    /// with that Preset.
    ///
    /// Loading changes *only* the working board — it never Applies to macOS or
    /// Arranges windows. Crucially it preserves the true last-applied baseline
    /// rather than resetting it, so pending-change counts and Apply state reflect
    /// differences from what macOS last received, not differences from whatever
    /// board was loaded before. Any application macOS last received that the
    /// loaded board no longer manages is seeded as a pending removal, so the next
    /// Apply deletes its owned key exactly as a manual removal would — only the
    /// snapshot's managed applications are taken from the input; any incoming
    /// pending state is ignored.
    public mutating func load(
        configuration newConfiguration: DeskLayouterConfiguration,
        selectedPresetID: UUID
    ) {
        let managed = Set(newConfiguration.managedApplications.map(\.bundleIdentifier))
        let removals = appliedAssignments.keys.filter { !managed.contains($0) }.sorted()
        configuration = DeskLayouterConfiguration(
            managedApplications: newConfiguration.managedApplications,
            pendingRemovals: removals
        )
        self.selectedPresetID = selectedPresetID
    }

    /// Associates the current working copy with a saved Preset without touching
    /// the working configuration or applied baseline. Used after saving the
    /// current board and during launch reconciliation.
    public mutating func associateSelectedPreset(_ id: UUID) {
        selectedPresetID = id
    }

    /// Advances the applied baseline to match the working configuration after a
    /// successful Apply, so the board becomes clean, and clears the pending
    /// removals the adapter has now deleted. Call this only once the adapter has
    /// actually written the new bindings.
    public mutating func markApplied(effectiveDesktopUUIDs: [String: String] = [:]) {
        configuration.clearPendingRemovals()
        appliedAssignments = Dictionary(
            configuration.managedApplications.map { application in
                (
                    application.bundleIdentifier,
                    AppliedAssignment(
                        display: application.display,
                        desktopNumber: application.desktopNumber,
                        concreteDesktopUUID: effectiveDesktopUUIDs[application.bundleIdentifier]
                    )
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private static func baseline(
        from configuration: DeskLayouterConfiguration
    ) -> [String: AppliedAssignment] {
        Dictionary(
            configuration.managedApplications.map {
                (
                    $0.bundleIdentifier,
                    AppliedAssignment(
                        display: $0.display,
                        desktopNumber: $0.desktopNumber,
                        concreteDesktopUUID: nil
                    )
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private static func sameSemanticDestination(
        _ working: AppliedAssignment,
        _ applied: AppliedAssignment
    ) -> Bool {
        guard working.desktopNumber == applied.desktopNumber else { return false }
        switch (working.display, applied.display) {
        case (nil, nil):
            return true
        case let (workingDisplay?, appliedDisplay?):
            return workingDisplay.identifiesSameDisplay(as: appliedDisplay)
        default:
            return false
        }
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
