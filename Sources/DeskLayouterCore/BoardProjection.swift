import Foundation

/// A grouped section of cards whose Assignments target a Desktop that does not
/// currently exist — a Desktop number beyond the live Desktop count (issue #52).
///
/// The board surfaces one section per distinct unavailable Desktop number, under
/// a clearly labeled header such as "Unavailable Desktop 3", so these Assignments
/// stay visible and recoverable rather than being silently dropped, hidden, or
/// clamped. Each card keeps its application identity and optional Layout and can
/// be moved to an available Desktop through the same move controls as any card.
public struct UnavailableDesktopSection: Equatable, Sendable, Identifiable {
    /// The 1-based Desktop number the Assignments target, which no longer exists.
    public let desktopNumber: Int

    /// The cards assigned to this unavailable Desktop, in managed order.
    public let cards: [BoardCard]

    public init(desktopNumber: Int, cards: [BoardCard]) {
        self.desktopNumber = desktopNumber
        self.cards = cards
    }

    public var id: Int { desktopNumber }

    /// The number of Assignments stranded on this unavailable Desktop.
    public var assignmentCount: Int { cards.count }

    /// The section header shown to the user, e.g. "Unavailable Desktop 3".
    public var title: String { "Unavailable Desktop \(desktopNumber)" }
}

/// The availability-aware projection of a board against the live system: the
/// Assignments that land on Desktops that currently exist, and — kept separate
/// but equally visible — the Assignments stranded on Desktops that do not
/// (issue #52).
///
/// This is a pure value computed at projection time from the working
/// configuration, the live Desktop count, and the live installed-app set; no
/// availability is ever stored in a Preset. Recomputing it after a Desktop
/// returns or an app is reinstalled surfaces those entries as available again
/// without recreating any Preset entry.
public struct BoardProjection: Equatable, Sendable {
    /// One column per Desktop that currently exists (Desktop 1, 2, …), in
    /// positional order. Cards here may still carry an unavailable *application*
    /// (`BoardCard.isApplicationAvailable == false`); that is flagged on the card
    /// and never blocks Apply.
    public let availableColumns: [DesktopColumn]

    /// Sections for Assignments whose Desktop no longer exists, one per distinct
    /// unavailable Desktop number, ascending. Empty when every Assignment targets
    /// a Desktop that exists.
    public let unavailableDesktops: [UnavailableDesktopSection]

    public init(
        availableColumns: [DesktopColumn],
        unavailableDesktops: [UnavailableDesktopSection]
    ) {
        self.availableColumns = availableColumns
        self.unavailableDesktops = unavailableDesktops
    }

    /// True when at least one Assignment targets a Desktop that does not exist, so
    /// the UI must surface the unavailable sections and Apply must be disabled
    /// until they are moved to an available Desktop. Missing *applications* never
    /// set this — only missing Desktops do.
    public var hasUnavailableDesktopAssignments: Bool { !unavailableDesktops.isEmpty }

    /// The unavailable Desktop numbers present, ascending, for explanatory
    /// feedback that names exactly what the user must fix.
    public var unavailableDesktopNumbers: [Int] { unavailableDesktops.map(\.desktopNumber) }
}

public extension BoardState {
    /// Projects the working configuration into the available Desktop columns plus
    /// the sections for Assignments stranded on Desktops that no longer exist,
    /// annotating each card with whether its application is currently installed
    /// (issue #52).
    ///
    /// Unlike ``columns(desktopCount:)``, which omits out-of-range cards entirely,
    /// this preserves and surfaces every Assignment: cards whose Desktop number is
    /// outside `1...desktopCount` are grouped into ``BoardProjection/unavailableDesktops``
    /// instead of vanishing, and cards whose application is absent from
    /// `installedBundleIdentifiers` are kept with `isApplicationAvailable == false`.
    /// Projecting never mutates the configuration, so refreshing against a changed
    /// system can only change what is *shown*, never what is *stored*.
    ///
    /// With no Desktops (`desktopCount <= 0`, e.g. a display could not be resolved)
    /// the board has no columns and no unavailable sections — the same no-columns
    /// state ``columns(desktopCount:)`` produces; that is a display-resolution
    /// concern handled elsewhere, and the Assignments remain intact in the stored
    /// configuration regardless.
    func projection(
        desktopCount: Int,
        installedBundleIdentifiers: Set<String>
    ) -> BoardProjection {
        guard desktopCount > 0 else {
            return BoardProjection(availableColumns: [], unavailableDesktops: [])
        }

        func card(for application: ManagedApplication) -> BoardCard {
            BoardCard(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.displayName,
                desktopNumber: application.desktopNumber,
                display: application.display,
                layout: application.layout,
                isApplicationAvailable: installedBundleIdentifiers.contains(application.bundleIdentifier)
            )
        }

        let availableRange = 1...desktopCount
        var cardsByAvailableDesktop: [Int: [BoardCard]] = [:]
        var cardsByUnavailableDesktop: [Int: [BoardCard]] = [:]
        for application in configuration.managedApplications {
            if availableRange.contains(application.desktopNumber) {
                cardsByAvailableDesktop[application.desktopNumber, default: []].append(card(for: application))
            } else {
                cardsByUnavailableDesktop[application.desktopNumber, default: []].append(card(for: application))
            }
        }

        let availableColumns = availableRange.map { number in
            DesktopColumn(number: number, cards: cardsByAvailableDesktop[number] ?? [])
        }
        let unavailableDesktops = cardsByUnavailableDesktop.keys.sorted().map { number in
            UnavailableDesktopSection(desktopNumber: number, cards: cardsByUnavailableDesktop[number] ?? [])
        }
        return BoardProjection(
            availableColumns: availableColumns,
            unavailableDesktops: unavailableDesktops
        )
    }
}

/// One stacked, collapsible Display section in the multi-Display board.
public struct DisplayBoardSection: Equatable, Sendable, Identifiable {
    public let display: DisplayIdentity
    public let memberDisplays: [DisplayIdentity]
    public let displayName: String
    public let isMain: Bool
    public let availableColumns: [DesktopColumn]
    public let unavailableDesktops: [UnavailableDesktopSection]

    public var id: String { display.colorSyncUUID.lowercased() }
    public var isMirrored: Bool { memberDisplays.count > 1 }
}

public struct DisplayBoardProjection: Equatable, Sendable {
    public let sections: [DisplayBoardSection]
    public let unavailableDisplays: [UnavailableDisplaySection]

    public init(
        sections: [DisplayBoardSection],
        unavailableDisplays: [UnavailableDisplaySection] = []
    ) {
        self.sections = sections
        self.unavailableDisplays = unavailableDisplays
    }

    public var hasUnavailableDesktopAssignments: Bool {
        sections.contains { !$0.unavailableDesktops.isEmpty }
    }
}

/// One saved physical Display that cannot be resolved uniquely in the live
/// topology. Its cards remain fully editable, and an optional recovery candidate
/// is only a suggestion that requires explicit confirmation.
public struct UnavailableDisplaySection: Equatable, Sendable, Identifiable {
    public let display: DisplayIdentity
    public let cards: [BoardCard]
    public let recoveryCandidate: DisplayIdentity?

    public var id: String { display.colorSyncUUID.lowercased() }
    public var displayName: String { display.lastKnownName }
    public var assignmentCount: Int { cards.count }

    public init(
        display: DisplayIdentity,
        cards: [BoardCard],
        recoveryCandidate: DisplayIdentity?
    ) {
        self.display = display
        self.cards = cards
        self.recoveryCandidate = recoveryCandidate
    }
}

public extension BoardState {
    /// Projects every active logical Display independently. Mirror-member
    /// identities resolve into the same logical section; identical Desktop
    /// numbers on different Displays never share cards.
    func projection(
        on topology: DisplayTopologySnapshot,
        installedBundleIdentifiers: Set<String>
    ) -> DisplayBoardProjection {
        func card(_ application: ManagedApplication) -> BoardCard {
            BoardCard(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.displayName,
                desktopNumber: application.desktopNumber,
                display: application.display,
                layout: application.layout,
                isApplicationAvailable: installedBundleIdentifiers.contains(application.bundleIdentifier)
            )
        }

        let sections = topology.sections.map { snapshot -> DisplayBoardSection in

            let applications = configuration.managedApplications.filter { application in
                guard let display = application.display else { return false }
                return topology.section(containing: display) == snapshot
            }
            let validRange = 1...max(snapshot.orderedDesktopUUIDs.count, 1)
            var available: [Int: [BoardCard]] = [:]
            var unavailable: [Int: [BoardCard]] = [:]
            for application in applications {
                if !snapshot.orderedDesktopUUIDs.isEmpty, validRange.contains(application.desktopNumber) {
                    available[application.desktopNumber, default: []].append(card(application))
                } else {
                    unavailable[application.desktopNumber, default: []].append(card(application))
                }
            }
            let columns = snapshot.orderedDesktopUUIDs.indices.map { index in
                DesktopColumn(number: index + 1, cards: available[index + 1] ?? [])
            }
            let unavailableSections = unavailable.keys.sorted().map { number in
                UnavailableDesktopSection(desktopNumber: number, cards: unavailable[number] ?? [])
            }
            return DisplayBoardSection(
                display: snapshot.primaryDisplay,
                memberDisplays: snapshot.memberDisplays,
                displayName: topology.displayName(for: snapshot),
                isMain: snapshot.isMain,
                availableColumns: columns,
                unavailableDesktops: unavailableSections
            )
        }

        var unavailableOrder: [String] = []
        var unavailableByID: [String: (DisplayIdentity, [BoardCard])] = [:]
        for application in configuration.managedApplications {
            guard let display = application.display,
                  topology.section(containing: display) == nil
            else { continue }
            let id = display.colorSyncUUID.lowercased()
            if unavailableByID[id] == nil {
                unavailableOrder.append(id)
                unavailableByID[id] = (display, [])
            }
            unavailableByID[id]?.1.append(card(application))
        }
        let unavailableDisplays = unavailableOrder.compactMap { id -> UnavailableDisplaySection? in
            guard let (display, cards) = unavailableByID[id] else { return nil }
            return UnavailableDisplaySection(
                display: display,
                cards: cards,
                recoveryCandidate: topology.recoveryCandidate(for: display)
            )
        }
        return DisplayBoardProjection(
            sections: sections,
            unavailableDisplays: unavailableDisplays
        )
    }
}
