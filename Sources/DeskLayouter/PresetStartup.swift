import DeskLayouterCore
import Foundation

/// The board and Preset library after launch-time reconciliation.
///
/// A loaded session always has a selected Preset whose identity resolves in the
/// library. The non-optional ``selectedPresetID`` makes that post-load invariant
/// explicit even though ``BoardState`` still decodes the optional field written
/// by versions that predate Presets.
public struct LoadedPresetSession: Equatable, Sendable {
    public let board: BoardState
    public let library: PresetLibrary
    public let selectedPresetID: Preset.ID

    public init(
        board: BoardState,
        library: PresetLibrary,
        selectedPresetID: Preset.ID
    ) {
        self.board = board
        self.library = library
        self.selectedPresetID = selectedPresetID
    }
}

/// Loads and repairs the board/Preset pair used by the editor at launch.
///
/// Reconciliation is deliberately limited to the two persisted app models. It
/// never calls the Spaces adapter or window arranger, and associating the seeded
/// Preset leaves both the working configuration and applied baseline untouched.
public enum PresetStartup {
    public static let defaultPresetName = "Default"

    /// Loads both stores tolerantly, repairs a missing or dangling selection, and
    /// best-effort persists the repair so it survives the next launch.
    public static func load(
        boardStateStore: BoardStateStore,
        presetLibraryStore: PresetLibraryStore
    ) -> LoadedPresetSession {
        let loadedBoard = (try? boardStateStore.load()) ?? BoardState()
        let loadedLibrary = (try? presetLibraryStore.load()) ?? PresetLibrary()
        let result = reconcile(board: loadedBoard, library: loadedLibrary)

        // Save the library first. A board must never be persisted pointing at a
        // newly seeded Preset that failed to reach disk. If only the association
        // needed repair, the already-persisted library need not be rewritten.
        if result.library != loadedLibrary {
            if (try? presetLibraryStore.save(result.library)) != nil {
                try? boardStateStore.save(result.board)
            }
        } else if result.board != loadedBoard {
            try? boardStateStore.save(result.board)
        }

        return result
    }

    /// Repairs an already-loaded pair without touching persistence.
    ///
    /// A valid existing association is returned unchanged. Otherwise the current
    /// working board is captured in a new `Default` Preset and selected. If a
    /// previous launch already wrote that exact `Default` snapshot but failed to
    /// write the board association, it is reused rather than creating a duplicate.
    public static func reconcile(
        board: BoardState,
        library: PresetLibrary
    ) -> LoadedPresetSession {
        if let selectedPresetID = board.selectedPresetID,
           library.preset(for: selectedPresetID) != nil {
            return LoadedPresetSession(
                board: board,
                library: library,
                selectedPresetID: selectedPresetID
            )
        }

        var repairedBoard = board
        var repairedLibrary = library

        if let existingDefault = library.presets.first(where: {
            $0.name.localizedCaseInsensitiveCompare(defaultPresetName) == .orderedSame
                && $0.matches(board.configuration)
        }) {
            repairedBoard.associateSelectedPreset(existingDefault.id)
            return LoadedPresetSession(
                board: repairedBoard,
                library: repairedLibrary,
                selectedPresetID: existingDefault.id
            )
        }

        let id = board.selectedPresetID ?? UUID()
        let seeded = try! repairedLibrary.add(
            name: availableDefaultName(in: library),
            managedApplications: board.configuration.managedApplications,
            id: id
        )
        repairedBoard.associateSelectedPreset(seeded.id)
        return LoadedPresetSession(
            board: repairedBoard,
            library: repairedLibrary,
            selectedPresetID: seeded.id
        )
    }

    /// `Default` is the normal migration name. Numbered fallbacks preserve every
    /// existing snapshot if an inconsistent legacy library already owns that name.
    private static func availableDefaultName(in library: PresetLibrary) -> String {
        let names = library.presets.map(\.name)
        func isAvailable(_ candidate: String) -> Bool {
            !names.contains {
                $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame
            }
        }

        guard !isAvailable(defaultPresetName) else { return defaultPresetName }
        var suffix = 2
        while !isAvailable("\(defaultPresetName) \(suffix)") {
            suffix += 1
        }
        return "\(defaultPresetName) \(suffix)"
    }
}
