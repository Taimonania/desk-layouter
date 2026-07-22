import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

@main
struct PresetSwitchTestRunner {
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

        func app(_ name: String, _ bundle: String, desktop: Int, layout: Layout? = nil) -> ManagedApplication {
            ManagedApplication(bundleIdentifier: bundle, displayName: name, desktopNumber: desktop, layout: layout)
        }

        // A library with two Presets and a board whose working copy has diverged
        // from the currently selected Preset ("Work").
        let workApps = [app("Writer", "com.example.Writer", desktop: 1), app("Reader", "com.example.Reader", desktop: 2)]
        let playApps = [app("Game", "com.example.Game", desktop: 1)]

        func freshLibrary() -> (PresetLibrary, Preset, Preset) {
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: workApps)
            let play = try! library.add(name: "Play", managedApplications: playApps)
            return (library, work, play)
        }

        // The modified working copy: Reader moved to Desktop 3, associated with Work.
        let modifiedApps = [app("Writer", "com.example.Writer", desktop: 1), app("Reader", "com.example.Reader", desktop: 3)]

        // decide: unchanged fast path and the three-way confirm gate.
        do {
            let (library, work, play) = freshLibrary()
            let clean = BoardState(configuration: work.configuration, selectedPresetID: work.id)
            check(
                "an unchanged working copy switches immediately",
                PresetSwitch.decide(target: play.id, currentSelection: work.id, configuration: clean.configuration, library: library) == .switchImmediately
            )
            let legacyUnassociated = BoardState(configuration: DeskLayouterConfiguration(managedApplications: modifiedApps), selectedPresetID: nil)
            check(
                "a legacy unassociated working copy switches immediately before startup reconciliation",
                PresetSwitch.decide(target: play.id, currentSelection: nil, configuration: legacyUnassociated.configuration, library: library) == .switchImmediately
            )
            let modified = BoardState(configuration: DeskLayouterConfiguration(managedApplications: modifiedApps), selectedPresetID: work.id)
            check(
                "re-selecting the same Preset never needs confirmation (the UI no-ops it)",
                PresetSwitch.decide(target: work.id, currentSelection: work.id, configuration: modified.configuration, library: library) == .switchImmediately
            )
            check(
                "a modified working copy must confirm and names the current Preset",
                PresetSwitch.decide(target: play.id, currentSelection: work.id, configuration: modified.configuration, library: library) == .confirm(currentPresetName: "Work")
            )
        }

        // Update and Switch: stores the working board in the current Preset, then
        // loads the target. The applied baseline is never touched.
        do {
            let (library, work, play) = freshLibrary()
            let baseline = ["com.baseline.App": 7]
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: modifiedApps),
                appliedBaseline: baseline,
                selectedPresetID: work.id
            )
            var persisted: PresetLibrary?
            let result = try? PresetSwitch.updateAndSwitch(
                target: play.id,
                currentSelection: work.id,
                library: library,
                board: board,
                persist: { persisted = $0 }
            )
            check("Update and Switch succeeds", result != nil)
            check(
                "Update and Switch stores the working board in the current Preset",
                result?.library.preset(for: work.id)?.managedApplications == modifiedApps,
                "got \(String(describing: result?.library.preset(for: work.id)?.managedApplications))"
            )
            check(
                "Update and Switch persists the updated library before committing",
                persisted?.preset(for: work.id)?.managedApplications == modifiedApps
            )
            check(
                "Update and Switch loads the requested Preset",
                result?.board.configuration.managedApplications == playApps,
                "got \(String(describing: result?.board.configuration.managedApplications))"
            )
            check("Update and Switch associates the requested Preset", result?.board.selectedPresetID == play.id)
            check(
                "Update and Switch never changes the applied baseline",
                result?.board.appliedBaseline == baseline,
                "got \(String(describing: result?.board.appliedBaseline))"
            )
        }

        // Persistence failure during Update and Switch: the switch is prevented and
        // neither working nor stored data is lost.
        do {
            let (library, work, play) = freshLibrary()
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: modifiedApps), selectedPresetID: work.id)
            struct SaveFailed: Error {}
            var threw = false
            do {
                _ = try PresetSwitch.updateAndSwitch(
                    target: play.id,
                    currentSelection: work.id,
                    library: library,
                    board: board,
                    persist: { _ in throw SaveFailed() }
                )
            } catch {
                threw = true
            }
            check("a persistence failure during Update and Switch throws", threw)
            check(
                "a persistence failure leaves the stored Preset unchanged",
                library.preset(for: work.id)?.managedApplications == workApps
            )
            check(
                "a persistence failure leaves the working board unchanged",
                board.configuration.managedApplications == modifiedApps && board.selectedPresetID == work.id
            )
        }

        // Persistence failure through the real store: writing to a path blocked by
        // a regular file throws, so the same guarantee holds end-to-end.
        do {
            let (library, work, play) = freshLibrary()
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: modifiedApps), selectedPresetID: work.id)
            let blocker = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterSwitchBlocker-\(UUID().uuidString)")
            try? Data("x".utf8).write(to: blocker)
            let store = PresetLibraryStore(fileURL: blocker.appendingPathComponent("presets.json"))
            var threw = false
            do {
                _ = try PresetSwitch.updateAndSwitch(
                    target: play.id,
                    currentSelection: work.id,
                    library: library,
                    board: board,
                    persist: { try store.save($0) }
                )
            } catch {
                threw = true
            }
            check("a real-store persistence failure during Update and Switch throws", threw)
            try? FileManager.default.removeItem(at: blocker)
        }

        // Discard and Switch: leaves the stored current Preset unchanged and loads
        // the requested Preset over the working copy.
        do {
            let (library, work, play) = freshLibrary()
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: modifiedApps), selectedPresetID: work.id)
            let switched = PresetSwitch.discardAndSwitch(target: play.id, board: board, library: library)
            check(
                "Discard and Switch leaves the stored current Preset unchanged",
                library.preset(for: work.id)?.managedApplications == workApps
            )
            check(
                "Discard and Switch loads the requested Preset",
                switched.configuration.managedApplications == playApps
            )
            check("Discard and Switch associates the requested Preset", switched.selectedPresetID == play.id)
        }

        // Cancel: the third choice preserves the working copy and stored Preset
        // without side effects. Cancel simply keeps the models the caller already
        // holds, so its no-side-effects guarantee rests on the switch operations
        // never mutating their inputs (value semantics) — asserted here so all
        // three choices are covered.
        do {
            let (library, work, play) = freshLibrary()
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: modifiedApps), selectedPresetID: work.id)
            let libraryBefore = library
            let boardBefore = board

            _ = PresetSwitch.discardAndSwitch(target: play.id, board: board, library: library)
            _ = try? PresetSwitch.updateAndSwitch(
                target: play.id,
                currentSelection: work.id,
                library: library,
                board: board,
                persist: { _ in }
            )

            check(
                "Cancel keeps the working copy intact (switch ops never mutate their input board)",
                board == boardBefore
                    && board.configuration.managedApplications == modifiedApps
                    && board.selectedPresetID == work.id
            )
            check(
                "Cancel keeps the stored Preset intact (switch ops never mutate their input library)",
                library == libraryBefore
                    && library.preset(for: work.id)?.managedApplications == workApps
            )
        }

        if failures.isEmpty {
            print("Preset switch tests passed")
        } else {
            fatalError("Preset switch tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
