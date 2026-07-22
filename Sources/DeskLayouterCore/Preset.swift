import Foundation

/// A named, persistent snapshot of the complete editable board: every managed
/// application together with its Assignment and optional Layout (CONTEXT.md).
///
/// A Preset stores *only* the managed applications, their Assignments, and their
/// Layouts — never the applied baseline, pending state, Arrange progress,
/// feedback, or installed/running status. Those belong to the live working
/// board (`BoardState`), not to a saved snapshot. Loading a Preset produces a
/// working copy without enacting it: it changes only Desk Layouter's working
/// board and never Applies to macOS or Arranges windows.
///
/// Identity is a stable ``id`` rather than the name, so the selected-Preset
/// association survives a later rename (issue #51) and so two Presets that only
/// differ by capitalization can never collide on identity.
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String

    /// The managed applications captured in this snapshot, each carrying its
    /// Assignment (which Desktop) and optional Layout (where on it).
    public internal(set) var managedApplications: [ManagedApplication]

    public init(
        id: UUID = UUID(),
        name: String,
        managedApplications: [ManagedApplication] = []
    ) {
        self.id = id
        self.name = name
        self.managedApplications = managedApplications.uniquedByBundleIdentifier()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case managedApplications
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        managedApplications = try container.decodeIfPresent(
            [ManagedApplication].self,
            forKey: .managedApplications
        )?.uniquedByBundleIdentifier() ?? []
    }

    /// The working configuration a load produces from this Preset: the snapshot's
    /// managed applications with no pending removals. The caller pairs this with
    /// the live applied baseline so pending state reflects what macOS last
    /// received, not the snapshot.
    public var configuration: DeskLayouterConfiguration {
        DeskLayouterConfiguration(managedApplications: managedApplications)
    }

    /// Whether the given working board still matches this Preset's captured board
    /// (every managed application, its Assignment, and its Layout), independent of
    /// ordering. Used to protect a modified working copy when switching Presets.
    public func matches(_ configuration: DeskLayouterConfiguration) -> Bool {
        self.configuration.hasSameManagedBoard(as: configuration)
    }
}

/// Why a proposed Preset name was rejected. Surfaced as inline feedback so an
/// invalid name never silently replaces another Preset.
public enum PresetNameError: Error, Equatable, Sendable {
    /// The name was empty (or only whitespace).
    case empty
    /// A Preset with this name already exists, ignoring capitalization. Carries
    /// the existing Preset's name as stored so feedback can quote it exactly.
    case duplicate(existingName: String)
}

/// Why a requested Preset deletion was rejected.
public enum PresetDeletionError: Error, Equatable, Sendable {
    /// The library's final Preset cannot be removed: every loaded board must stay
    /// associated with one real, named Preset.
    case lastPreset
}
