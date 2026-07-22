import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

@main
struct PresetStartupTestRunner {
    static func main() {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok: \(name)")
            } else {
                let detailText = detail()
                let suffix = detailText.isEmpty ? "" : " — \(detailText)"
                failures.append("\(name)\(suffix)")
                print("  FAIL: \(name)\(suffix)")
            }
        }

        func stores(in directory: URL) -> (BoardStateStore, PresetLibraryStore) {
            (
                BoardStateStore(fileURL: directory.appendingPathComponent("board-state.json")),
                PresetLibraryStore(fileURL: directory.appendingPathComponent("presets.json"))
            )
        }

        func app(_ name: String, _ bundle: String, desktop: Int) -> ManagedApplication {
            ManagedApplication(
                bundleIdentifier: bundle,
                displayName: name,
                desktopNumber: desktop
            )
        }

        // A fresh install gets one selected, persisted Default Preset seeded from
        // the empty current board.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterPresetStartup-\(UUID().uuidString)", isDirectory: true)
            let (boardStore, libraryStore) = stores(in: directory)
            let session = PresetStartup.load(
                boardStateStore: boardStore,
                presetLibraryStore: libraryStore
            )
            let selected = session.library.preset(for: session.selectedPresetID)
            check("a fresh install seeds exactly one Preset", session.library.presets.count == 1)
            check("the fresh Preset is named Default", selected?.name == "Default")
            check("the fresh Default captures the current empty board", selected?.managedApplications == [])
            check("the fresh board selects Default", session.board.selectedPresetID == selected?.id)

            let persistedBoard = try? boardStore.load()
            let persistedLibrary = try? libraryStore.load()
            check("the fresh selection is persisted", persistedBoard?.selectedPresetID == selected?.id)
            check("the fresh Default is persisted", persistedLibrary == session.library)
            try? FileManager.default.removeItem(at: directory)
        }

        // A board written before required Preset association is migrated from its
        // exact working copy. The applied baseline is deliberately different to
        // prove startup neither Applies nor resets pending state.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterPresetStartup-\(UUID().uuidString)", isDirectory: true)
            let (boardStore, libraryStore) = stores(in: directory)
            let working = [
                app("Writer", "com.example.Writer", desktop: 2),
                app("Mail", "com.example.Mail", desktop: 3),
            ]
            let baseline = ["com.example.Writer": 1, "com.example.Old": 4]
            let legacyBoard = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: working),
                appliedBaseline: baseline,
                selectedPresetID: nil
            )
            try? boardStore.save(legacyBoard)

            let session = PresetStartup.load(
                boardStateStore: boardStore,
                presetLibraryStore: libraryStore
            )
            let selected = session.library.preset(for: session.selectedPresetID)
            check("migration seeds Default from the working board", selected?.name == "Default" && selected?.managedApplications == working)
            check("migration preserves the working configuration exactly", session.board.configuration == legacyBoard.configuration)
            check("migration never changes the applied baseline", session.board.appliedBaseline == baseline, "got \(session.board.appliedBaseline)")
            check("migration leaves pending state intact", session.board.pendingChanges == legacyBoard.pendingChanges)
            check("the migrated selected identity is non-nil and resolvable", session.board.selectedPresetID == session.selectedPresetID && selected != nil)
            try? FileManager.default.removeItem(at: directory)
        }

        // A valid existing association needs no repair and leaves both value
        // models byte-for-byte equivalent in memory.
        do {
            let working = [app("Writer", "com.example.Writer", desktop: 2)]
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: working)
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: working),
                appliedBaseline: ["com.example.Writer": 1],
                selectedPresetID: work.id
            )
            let session = PresetStartup.reconcile(board: board, library: library)
            check("a valid selected Preset is preserved", session == LoadedPresetSession(board: board, library: library, selectedPresetID: work.id))
        }

        // If the library reached disk on a previous attempt but its board
        // association did not, the matching Default is reused without duplication.
        do {
            let working = [app("Writer", "com.example.Writer", desktop: 2)]
            var library = PresetLibrary()
            let seeded = try! library.add(name: "Default", managedApplications: working)
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: working),
                selectedPresetID: nil
            )
            let session = PresetStartup.reconcile(board: board, library: library)
            check("a matching persisted Default is reused", session.library.presets.count == 1 && session.selectedPresetID == seeded.id)
            check("reusing Default changes no board data beyond association", session.board.configuration == board.configuration && session.board.appliedBaseline == board.appliedBaseline)
        }

        // Existing named Presets do not prevent migration: an unassociated board
        // gets its own Default snapshot without altering the existing Preset.
        do {
            let currentWorking = [app("Current", "com.example.Current", desktop: 3)]
            let savedWorking = [app("Saved", "com.example.Saved", desktop: 1)]
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: savedWorking)
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: currentWorking),
                selectedPresetID: nil
            )
            let session = PresetStartup.reconcile(board: board, library: library)
            check("an existing library still receives a seeded Default", session.library.preset(for: session.selectedPresetID)?.name == "Default")
            check("the added Default captures the current working board", session.library.preset(for: session.selectedPresetID)?.managedApplications == currentWorking)
            check("migration leaves existing Presets untouched", session.library.preset(for: work.id)?.managedApplications == savedWorking)
        }

        // A dangling identity is repaired as well, and remains stable when used as
        // the new Preset's identity.
        do {
            let danglingID = UUID()
            let board = BoardState(selectedPresetID: danglingID)
            let session = PresetStartup.reconcile(board: board, library: PresetLibrary())
            check("a dangling selection is repaired", session.selectedPresetID == danglingID && session.library.preset(for: danglingID) != nil)
            check("a repaired board has a resolvable non-nil selection", session.board.selectedPresetID == danglingID)
        }

        if failures.isEmpty {
            print("Preset startup tests passed")
        } else {
            fatalError("Preset startup tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
