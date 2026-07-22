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
    /// associated with. Returns `false` for a legacy absent or dangling identity;
    /// launch reconciliation repairs that persisted state before the editor uses
    /// it. This is the dirty-relative-to-Preset detection that
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
    /// whitespace. Returns the existing Preset whose name collides, if any. The
    /// Preset identified by `excluding` is ignored, so renaming a Preset to a new
    /// capitalization of its own name never collides with itself.
    private func existingPreset(named name: String, excluding id: Preset.ID? = nil) -> Preset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.first {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// The single naming gate shared by creation (``add(name:managedApplications:id:)``)
    /// and rename (``rename(id:to:)``): trims surrounding whitespace, rejects an
    /// empty name with ``PresetNameError/empty`` and a case-insensitive collision
    /// with ``PresetNameError/duplicate(existingName:)``, and returns the trimmed
    /// name to store. `excluding` omits one Preset from the uniqueness check so a
    /// Preset can be renamed to a different capitalization of its own name.
    private func validatedName(_ name: String, excluding id: Preset.ID? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetNameError.empty }
        if let existing = existingPreset(named: trimmed, excluding: id) {
            throw PresetNameError.duplicate(existingName: existing.name)
        }
        return trimmed
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
        let trimmed = try validatedName(name)
        let preset = Preset(id: id, name: trimmed, managedApplications: managedApplications)
        presets.append(preset)
        return preset
    }

    /// Renames the Preset with the given identity, preserving its complete stored
    /// snapshot (identity and captured managed applications) and changing only its
    /// name.
    ///
    /// The new name goes through the same gate as creation: it is trimmed and
    /// validated for non-emptiness and case-insensitive uniqueness (the Preset
    /// being renamed is excluded from the uniqueness check, so recapitalizing its
    /// own name is allowed). On a rejected name the library is left unchanged, so a
    /// failed rename never silently loses or replaces a Preset. Renaming a Preset
    /// that is no longer in the library is a harmless no-op — but the name is still
    /// validated first, matching creation. Returns the renamed Preset, or `nil`
    /// when the identity is unknown.
    @discardableResult
    public mutating func rename(id: Preset.ID, to newName: String) throws -> Preset? {
        let trimmed = try validatedName(newName, excluding: id)
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return nil }
        presets[index].name = trimmed
        return presets[index]
    }

    /// Removes the Preset with the given identity from the library, leaving every
    /// other Preset untouched. The final Preset can never be removed. Deleting a
    /// Preset that is no longer in the library, or attempting to delete the sole
    /// remaining Preset, is a harmless no-op. Returns the removed Preset, or `nil`
    /// when blocked or unknown. This concerns Preset storage only — it never
    /// touches the working board's selected-Preset association, which the caller
    /// reconciles.
    @discardableResult
    public mutating func delete(id: Preset.ID) -> Preset? {
        guard presets.count > 1 else { return nil }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return nil }
        return presets.remove(at: index)
    }

    /// Replaces the managed applications of the Preset with the given identity,
    /// leaving its name untouched. This is the explicit-update action: the stored
    /// Preset changes only when the user asks for it. Updating a Preset that is no
    /// longer in the library is a harmless no-op.
    public mutating func update(id: Preset.ID, managedApplications: [ManagedApplication]) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].managedApplications = managedApplications.uniquedByBundleIdentifier()
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
