import DeskLayouterCore

/// Protects a modified Preset working copy when the user selects another Preset.
///
/// This concerns **Preset storage only**. It is deliberately isolated from Apply
/// and Arrange: switching, updating, and discarding never enact Assignments, never
/// change the applied baseline, and never move windows. `EditorModel` wires the
/// UI to these pure decisions and transformations so the full protocol — the
/// unchanged fast path, the three explicit choices, and the persistence-failure
/// guarantee — is exercised without a running app.
public enum PresetSwitch {
    /// What selecting a Preset should do, given the current working copy.
    public enum Decision: Equatable, Sendable {
        /// The working copy matches the selected Preset, no Preset is selected, or
        /// the same Preset was re-selected: load the target immediately.
        case switchImmediately
        /// The working copy has unsaved changes to the selected Preset: present the
        /// "Update and Switch" / "Discard and Switch" / "Cancel" choice first.
        case confirm(currentPresetName: String)
    }

    /// Decides whether selecting `target` can switch immediately or must first
    /// confirm because the working copy has been modified relative to its Preset.
    public static func decide(
        target: Preset.ID,
        currentSelection: Preset.ID?,
        configuration: DeskLayouterConfiguration,
        library: PresetLibrary
    ) -> Decision {
        guard target != currentSelection else { return .switchImmediately }
        guard
            let currentSelection,
            let current = library.preset(for: currentSelection),
            !current.matches(configuration)
        else {
            return .switchImmediately
        }
        return .confirm(currentPresetName: current.name)
    }

    /// "Update and Switch": store the complete working board in the currently
    /// selected Preset, then load the requested Preset.
    ///
    /// Persistence runs on a copy **before** any in-memory commit: `persist` is
    /// handed the updated library and, only if it returns without throwing, the
    /// updated library and switched board are returned. If `persist` throws, the
    /// error propagates and the caller keeps its existing library and board, so a
    /// persistence failure prevents the switch without losing working or stored
    /// data.
    public static func updateAndSwitch(
        target: Preset.ID,
        currentSelection: Preset.ID,
        library: PresetLibrary,
        board: BoardState,
        persist: (PresetLibrary) throws -> Void
    ) throws -> (library: PresetLibrary, board: BoardState) {
        var updatedLibrary = library
        updatedLibrary.update(
            id: currentSelection,
            managedApplications: board.configuration.managedApplications
        )
        try persist(updatedLibrary)
        return (updatedLibrary, switched(board, to: target, in: updatedLibrary))
    }

    /// "Discard and Switch": leave the stored current Preset untouched and load the
    /// requested Preset over the working copy.
    public static func discardAndSwitch(
        target: Preset.ID,
        board: BoardState,
        library: PresetLibrary
    ) -> BoardState {
        switched(board, to: target, in: library)
    }

    private static func switched(
        _ board: BoardState,
        to target: Preset.ID,
        in library: PresetLibrary
    ) -> BoardState {
        guard let preset = library.preset(for: target) else { return board }
        var switchedBoard = board
        switchedBoard.load(configuration: preset.configuration, selectedPresetID: preset.id)
        return switchedBoard
    }
}
