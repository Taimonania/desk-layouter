import Foundation

/// Runtime geometry used only to order and address active Displays. Geometry is
/// never persisted as identity.
public struct DisplayBounds: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One logical active Display destination. An extended Display has one member;
/// a mirror set has every physical member but one shared Desktop list.
public struct DisplayDesktopSectionSnapshot: Equatable, Sendable {
    public let primaryDisplay: DisplayIdentity
    public let memberDisplays: [DisplayIdentity]
    public let isMain: Bool
    public let isBuiltIn: Bool
    public let bounds: DisplayBounds
    public let orderedDesktopUUIDs: [String]

    public init(
        primaryDisplay: DisplayIdentity,
        memberDisplays: [DisplayIdentity],
        isMain: Bool,
        isBuiltIn: Bool = false,
        bounds: DisplayBounds,
        orderedDesktopUUIDs: [String]
    ) {
        self.primaryDisplay = primaryDisplay
        self.memberDisplays = memberDisplays
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.bounds = bounds
        self.orderedDesktopUUIDs = orderedDesktopUUIDs
    }

    public var isMirrored: Bool { memberDisplays.count > 1 }

    /// New Assignments created while mirrored intentionally target the mirror
    /// primary; existing member identities remain untouched in persistence.
    public var newAssignmentDisplay: DisplayIdentity { primaryDisplay }

    public var displayName: String {
        let names = memberDisplays.map(\.lastKnownName)
        return isMirrored
            ? names.joined(separator: " + ") + " — Mirrored"
            : primaryDisplay.lastKnownName
    }

    public func contains(_ identity: DisplayIdentity) -> Bool {
        memberDisplays.contains { $0.identifiesSameDisplay(as: identity) }
    }

    public func concreteDesktopUUID(at desktopNumber: Int) -> String? {
        let index = desktopNumber - 1
        guard orderedDesktopUUIDs.indices.contains(index) else { return nil }
        return orderedDesktopUUIDs[index]
    }
}

/// A complete, immutable read of the active Display topology and the ordered
/// Desktops hosted by each logical Display. Equality is the Apply race token.
public struct DisplayTopologySnapshot: Equatable, Sendable {
    public let displaysHaveSeparateSpaces: Bool
    public let automaticallyRearrangesSpaces: Bool
    public let sections: [DisplayDesktopSectionSnapshot]

    public init(
        displaysHaveSeparateSpaces: Bool,
        automaticallyRearrangesSpaces: Bool,
        sections: [DisplayDesktopSectionSnapshot]
    ) {
        self.displaysHaveSeparateSpaces = displaysHaveSeparateSpaces
        self.automaticallyRearrangesSpaces = automaticallyRearrangesSpaces
        self.sections = sections.sorted { lhs, rhs in
            if lhs.bounds.y != rhs.bounds.y { return lhs.bounds.y < rhs.bounds.y }
            if lhs.bounds.x != rhs.bounds.x { return lhs.bounds.x < rhs.bounds.x }
            return lhs.primaryDisplay.colorSyncUUID < rhs.primaryDisplay.colorSyncUUID
        }
    }

    public func section(containing display: DisplayIdentity) -> DisplayDesktopSectionSnapshot? {
        sections.first { $0.contains(display) }
    }

    public func concreteDesktopUUID(
        display: DisplayIdentity,
        desktopNumber: Int
    ) -> String? {
        section(containing: display)?.concreteDesktopUUID(at: desktopNumber)
    }

    /// Names duplicate extended Displays unambiguously without turning their
    /// transient Display number or geometry into identity.
    public func displayName(for section: DisplayDesktopSectionSnapshot) -> String {
        guard !section.isMirrored else { return section.displayName }
        let duplicates = sections.filter {
            !$0.isMirrored
                && $0.primaryDisplay.lastKnownName.localizedCaseInsensitiveCompare(
                    section.primaryDisplay.lastKnownName
                ) == .orderedSame
        }
        guard duplicates.count > 1 else { return section.displayName }
        let suffix = String(section.primaryDisplay.colorSyncUUID.prefix(8))
        return "\(section.displayName) (\(suffix))"
    }
}

/// A physical Display plus a positional Desktop number.
public struct DesktopAddress: Equatable, Hashable, Sendable {
    public let display: DisplayIdentity
    public let desktopNumber: Int

    public init(display: DisplayIdentity, desktopNumber: Int) {
        self.display = display
        self.desktopNumber = desktopNumber
    }
}

/// The mutation intent handed to the macOS adapter. Resolvable Assignments are
/// updates, only explicit removals are deletions, and unresolved Assignments are
/// preserved exactly as macOS last knew them.
public struct AssignmentApplyPlan: Equatable, Sendable {
    public let updates: [String: String]
    public let deletions: Set<String>
    public let preservations: Set<String>

    public init(
        updates: [String: String],
        deletions: Set<String>,
        preservations: Set<String>
    ) {
        self.updates = updates
        self.deletions = deletions
        self.preservations = preservations
    }
}
