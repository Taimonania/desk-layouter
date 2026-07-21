import Foundation

/// The user's collection of saved ``Preset``s — the pure, unit-tested seam for
/// creating, updating, ordering, and looking up Presets.
///
/// This value holds no filesystem access; persistence lives behind
/// `PresetLibraryStore` in the macOS adapter layer, mirroring
/// `BoardStateStore`/`ConfigurationStore`. It enforces the two naming rules —
/// non-empty and unique ignoring capitalization — before a Preset ever enters
/// the collection, so an invalid name can never replace an existing Preset.
public struct PresetLibrary: Codable, Equatable, Sendable {
    /// The stored Presets, in insertion order. Presentation order is
    /// ``orderedPresets``; callers should never rely on this raw order.
    public private(set) var presets: [Preset]

    public init(presets: [Preset] = []) {
        self.presets = presets
    }

    private enum CodingKeys: String, CodingKey {
        case presets
    }

    // Tolerant decoding: a library document without a `presets` key (or written
    // by a future/hand-authored file) loads as empty rather than failing, so a
    // damaged or partial file never destroys the ability to start fresh.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presets = try container.decodeIfPresent([Preset].self, forKey: .presets) ?? []
    }

    /// The Presets in the order to show the user: alphabetical by name using a
    /// user-friendly, locale-aware comparison (the same Finder-style ordering
    /// that sorts "Desk 2" before "Desk 10" and respects the current locale).
    public var orderedPresets: [Preset] {
        presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Preset with the given identity, if it is still in the library.
    public func preset(for id: Preset.ID) -> Preset? {
        presets.first { $0.id == id }
    }

    /// Whether the working board has been modified relative to the Preset it is
    /// associated with. Returns `false` when no resolvable Preset is selected
    /// (a nil or dangling selection is "Custom Setup" — there is no stored Preset
    /// to differ from). This is the dirty-relative-to-Preset detection that
    /// switching protection keys off; it is distinct from ``BoardState/isDirty``,
    /// which tracks pending Assignments awaiting Apply.
    public func isModified(
        _ configuration: DeskLayouterConfiguration,
        from selectedPresetID: Preset.ID?
    ) -> Bool {
        guard let selectedPresetID, let preset = preset(for: selectedPresetID) else {
            return false
        }
        return !preset.matches(configuration)
    }

    /// Whether a name is already taken, ignoring capitalization and surrounding
    /// whitespace. Returns the existing Preset whose name collides, if any.
    private func existingPreset(named name: String) -> Preset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.first { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Adds a new Preset capturing the given managed applications under the given
    /// name, returning the created Preset.
    ///
    /// The name is trimmed of surrounding whitespace, then validated: an empty
    /// name throws ``PresetNameError/empty`` and a name that collides with an
    /// existing Preset ignoring capitalization throws
    /// ``PresetNameError/duplicate(existingName:)``. On either error the library
    /// is left unchanged, so a rejected name never replaces another Preset.
    /// Capturing an empty application list is allowed — an empty board is a valid
    /// Preset.
    @discardableResult
    public mutating func add(
        name: String,
        managedApplications: [ManagedApplication],
        id: UUID = UUID()
    ) throws -> Preset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetNameError.empty }
        if let existing = existingPreset(named: trimmed) {
            throw PresetNameError.duplicate(existingName: existing.name)
        }
        let preset = Preset(id: id, name: trimmed, managedApplications: managedApplications)
        presets.append(preset)
        return preset
    }

    /// Replaces the managed applications of the Preset with the given identity,
    /// leaving its name untouched. This is the explicit-update action: the stored
    /// Preset changes only when the user asks for it. Updating a Preset that is no
    /// longer in the library is a harmless no-op.
    public mutating func update(id: Preset.ID, managedApplications: [ManagedApplication]) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].managedApplications = managedApplications
    }
}

/// The name to show for the current Preset selection in the editor header.
///
/// A working copy that is not associated with any saved Preset — a fresh
/// install migrating its existing board (issue #49), or a board that has never
/// been saved — reads as "Custom Setup". No Preset is created for it; the label
/// is purely presentational.
public enum PresetSelection {
    /// The label shown when the working copy is not tied to a saved Preset.
    public static let customSetupName = "Custom Setup"

    /// The selection label for the given selected-Preset identity within a
    /// library: the Preset's name when it resolves, or ``customSetupName`` when
    /// the selection is absent or dangling.
    public static func displayName(for id: Preset.ID?, in library: PresetLibrary) -> String {
        guard let id, let preset = library.preset(for: id) else { return customSetupName }
        return preset.name
    }
}

/// Pure JSON serialization for the Preset library — the encode/decode seam, with
/// no filesystem access. File I/O lives behind `PresetLibraryStore` in the macOS
/// adapter layer, mirroring `ConfigurationSerialization`/`BoardStateSerialization`.
public enum PresetLibrarySerialization {
    public static func encode(_ library: PresetLibrary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(library)
    }

    public static func decode(from data: Data) throws -> PresetLibrary {
        try JSONDecoder().decode(PresetLibrary.self, from: data)
    }
}
