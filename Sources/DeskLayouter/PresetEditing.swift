import DeskLayouterCore

/// Restores working copies and renames or deletes saved ``Preset``s with the same
/// value-first discipline as `PresetSwitch`.
///
/// These transformations are deliberately isolated from Apply and Arrange: they
/// never enact Assignments, never change the applied baseline, and never move
/// windows. Library mutations are prepared on a copy and persisted *before* they
/// are returned for the caller to commit in memory, so a persistence failure
/// throws and leaves both the stored library and the working board exactly as
/// they were. Revert likewise returns a new board value while leaving its input
/// untouched. `EditorModel` wires the UI to these pure transformations so the
/// full protocol is exercised without a running app.
public enum PresetEditing {
    /// Restores the selected Preset's stored snapshot over the working board.
    ///
    /// The returned board keeps its true applied baseline, so Revert remains
    /// independent of Apply-dirty: a restored snapshot may still have Assignments
    /// waiting to be Applied, or it may become Apply-clean. The selected-Preset
    /// association is retained and the Preset library is never changed. This pure
    /// transformation cannot Apply Assignments or Arrange windows.
    public static func revert(
        to id: Preset.ID,
        library: PresetLibrary,
        board: BoardState
    ) -> BoardState {
        guard let preset = library.preset(for: id) else { return board }
        var revertedBoard = board
        revertedBoard.load(configuration: preset.configuration, selectedPresetID: preset.id)
        return revertedBoard
    }

    /// Renames the Preset with the given identity to `newName`, reusing the exact
    /// creation validation (non-empty, trimmed, case-insensitive uniqueness) and
    /// preserving the Preset's complete stored snapshot.
    ///
    /// Validation runs on a copy *before* any persistence, so a rejected name
    /// (``PresetNameError``) throws without writing anything. The updated library
    /// is then persisted on that copy and only returned if `persist` succeeds; if
    /// it throws, the error propagates and the caller keeps its existing library,
    /// so neither the name nor the stored snapshot is lost. Renaming never touches
    /// the working board — the selected-Preset association is by identity, so a
    /// rename is reflected purely through the library.
    public static func rename(
        id: Preset.ID,
        to newName: String,
        library: PresetLibrary,
        persist: (PresetLibrary) throws -> Void
    ) throws -> PresetLibrary {
        var updatedLibrary = library
        try updatedLibrary.rename(id: id, to: newName)
        try persist(updatedLibrary)
        return updatedLibrary
    }

    /// Deletes the Preset with the given identity, returning the reduced library
    /// and the reconciled working board.
    ///
    /// The reduced library is persisted on a copy **before** any in-memory commit:
    /// `persist` is handed the library with the Preset removed and, only if it
    /// returns without throwing, the reduced library and reconciled board are
    /// returned. If `persist` throws, the error propagates and the caller keeps its
    /// existing library and board, so a persistence failure prevents the delete
    /// without losing the Preset or the working board.
    ///
    /// The library's final Preset cannot be deleted. When the deleted Preset is
    /// currently selected, the working board is associated with the first
    /// remaining Preset in display order while its configuration and applied
    /// baseline are preserved untouched. When an unselected Preset is deleted,
    /// the working board and its selection are returned unchanged.
    public static func delete(
        id: Preset.ID,
        currentSelection: Preset.ID,
        library: PresetLibrary,
        board: BoardState,
        persist: (PresetLibrary) throws -> Void
    ) throws -> (library: PresetLibrary, board: BoardState) {
        guard library.presets.count > 1 else {
            throw PresetDeletionError.lastPreset
        }
        var updatedLibrary = library
        guard updatedLibrary.delete(id: id) != nil else {
            return (library, board)
        }
        try persist(updatedLibrary)
        var updatedBoard = board
        if currentSelection == id {
            updatedBoard.associateSelectedPreset(updatedLibrary.orderedPresets[0].id)
        }
        return (updatedLibrary, updatedBoard)
    }
}
