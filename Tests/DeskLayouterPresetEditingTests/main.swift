import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

@main
struct PresetEditingTestRunner {
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

        let workApps = [app("Writer", "com.example.Writer", desktop: 1), app("Reader", "com.example.Reader", desktop: 2)]
        let playApps = [app("Game", "com.example.Game", desktop: 1)]

        func freshLibrary() -> (PresetLibrary, Preset, Preset) {
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: workApps)
            let play = try! library.add(name: "Play", managedApplications: playApps)
            return (library, work, play)
        }

        struct SaveFailed: Error {}

        // MARK: - Revert

        // Revert restores the selected Preset over the working copy while keeping
        // the true applied baseline and selected-Preset association. Preset-dirty
        // returns to clean, while Apply-dirty remains whatever the restored board
        // versus macOS baseline says it is.
        do {
            let (library, work, _) = freshLibrary()
            let baseline = [
                "com.example.Writer": 3,
                "com.example.Legacy": 4,
            ]
            let editedApps = [
                app("Writer", "com.example.Writer", desktop: 2),
                app("Mail", "com.example.Mail", desktop: 1),
            ]
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: editedApps),
                appliedBaseline: baseline,
                selectedPresetID: work.id
            )

            check("an edited working copy is Preset-dirty before Revert", library.isModified(board.configuration, from: work.id))
            let reverted = PresetEditing.revert(to: work.id, library: library, board: board)
            check("Revert restores the selected Preset snapshot", work.matches(reverted.configuration))
            check("Revert returns the working copy to Preset-clean", !library.isModified(reverted.configuration, from: work.id))
            check("Revert keeps the working copy attached to the selected Preset", reverted.selectedPresetID == work.id)
            check("Revert never changes the applied baseline", reverted.appliedBaseline == baseline, "got \(reverted.appliedBaseline)")
            check("Revert leaves restored Assignments Apply-dirty when they differ from macOS", reverted.pendingChanges == ["com.example.Legacy", "com.example.Reader", "com.example.Writer"], "got \(reverted.pendingChanges)")
            check("Revert seeds deletion of an applied app absent from the Preset", reverted.configuration.pendingRemovals == ["com.example.Legacy"])
            check("Revert never mutates the stored Preset", library.preset(for: work.id)?.managedApplications == workApps)
        }

        // Preset-dirty and Apply-dirty are independent in both directions: a
        // Layout-only edit is Preset-dirty but Apply-clean, while a board matching
        // its Preset can still contain unapplied Assignment changes.
        do {
            let layout = Layout(horizontalDivision: .halves, verticalDivision: .halves, columnSpan: .single(0), rowSpan: .single(0))
            var library = PresetLibrary()
            let preset = try! library.add(
                name: "Focus",
                managedApplications: [app("Writer", "com.example.Writer", desktop: 1)]
            )

            var layoutEdited = BoardState(configuration: preset.configuration, selectedPresetID: preset.id)
            layoutEdited.setLayout(layout, forBundleIdentifier: "com.example.Writer")
            check("a Layout-only edit is Preset-dirty", library.isModified(layoutEdited.configuration, from: preset.id))
            check("a Layout-only edit remains Apply-clean", !layoutEdited.isDirty)

            let applyDirty = BoardState(
                configuration: preset.configuration,
                appliedBaseline: ["com.example.Writer": 2],
                selectedPresetID: preset.id
            )
            check("a board matching its Preset is Preset-clean", !library.isModified(applyDirty.configuration, from: preset.id))
            check("a Preset-clean board can remain Apply-dirty", applyDirty.isDirty)
        }

        // Confirmation cancellation performs no transformation at all. Revert's
        // value semantics also leave the original working board available and
        // untouched until the caller commits the returned copy.
        do {
            let (library, work, _) = freshLibrary()
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: [
                    app("Writer", "com.example.Writer", desktop: 3),
                    app("Reader", "com.example.Reader", desktop: 2),
                ]),
                selectedPresetID: work.id
            )
            let before = board
            _ = PresetEditing.revert(to: work.id, library: library, board: board)
            check("cancelling Revert keeps the working copy untouched", board == before)
        }

        // MARK: - Rename

        // Successful rename: the name changes, the snapshot is preserved, and the
        // updated library is persisted before it is returned to commit.
        do {
            let (library, work, _) = freshLibrary()
            var persisted: PresetLibrary?
            let updated = try? PresetEditing.rename(
                id: work.id,
                to: "  Focus  ",
                library: library,
                persist: { persisted = $0 }
            )
            check("rename succeeds", updated != nil)
            check("rename applies the trimmed new name", updated?.preset(for: work.id)?.name == "Focus", "got \(String(describing: updated?.preset(for: work.id)?.name))")
            check(
                "rename preserves the complete stored snapshot",
                updated?.preset(for: work.id)?.managedApplications == workApps
            )
            check("rename persists the updated library before committing", persisted?.preset(for: work.id)?.name == "Focus")
        }

        // Invalid name (empty): rejected before any persistence, library untouched.
        do {
            let (library, work, _) = freshLibrary()
            var persistCalled = false
            var thrown: PresetNameError?
            do {
                _ = try PresetEditing.rename(id: work.id, to: "   ", library: library, persist: { _ in persistCalled = true })
            } catch let error as PresetNameError {
                thrown = error
            } catch {}
            check("an empty rename is rejected as empty", thrown == .empty, "got \(String(describing: thrown))")
            check("an empty rename never persists", !persistCalled)
            check("an empty rename leaves the stored Preset unchanged", library.preset(for: work.id)?.name == "Work")
        }

        // Invalid name (duplicate): rejected before any persistence, both Presets
        // untouched.
        do {
            let (library, work, play) = freshLibrary()
            var persistCalled = false
            var thrown: PresetNameError?
            do {
                _ = try PresetEditing.rename(id: play.id, to: "WORK", library: library, persist: { _ in persistCalled = true })
            } catch let error as PresetNameError {
                thrown = error
            } catch {}
            check("a duplicate rename is rejected", thrown == .duplicate(existingName: "Work"), "got \(String(describing: thrown))")
            check("a duplicate rename never persists", !persistCalled)
            check("a duplicate rename leaves both Presets unchanged", library.preset(for: work.id)?.name == "Work" && library.preset(for: play.id)?.name == "Play")
        }

        // Rename persistence failure: the error propagates and the stored Preset is
        // not lost or renamed.
        do {
            let (library, work, _) = freshLibrary()
            var threw = false
            do {
                _ = try PresetEditing.rename(id: work.id, to: "Focus", library: library, persist: { _ in throw SaveFailed() })
            } catch {
                threw = true
            }
            check("a rename persistence failure throws", threw)
            check("a rename persistence failure leaves the stored Preset intact", library.preset(for: work.id)?.name == "Work" && library.preset(for: work.id)?.managedApplications == workApps)
        }

        // MARK: - Delete (selected)

        // Deleting the selected Preset: removes it, associates the unchanged board
        // with the remaining Preset, preserves the working configuration AND the
        // applied baseline, and leaves the remaining snapshot untouched.
        do {
            let (library, work, play) = freshLibrary()
            let baseline = ["com.baseline.App": 7]
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: workApps),
                appliedBaseline: baseline,
                selectedPresetID: work.id
            )
            var persisted: PresetLibrary?
            let result = try? PresetEditing.delete(
                id: work.id,
                currentSelection: work.id,
                library: library,
                board: board,
                persist: { persisted = $0 }
            )
            check("deleting the selected Preset succeeds", result != nil)
            check("deleting the selected Preset removes it from the library", result?.library.preset(for: work.id) == nil)
            check("deleting the selected Preset persists the reduced library before committing", persisted?.preset(for: work.id) == nil && persisted?.preset(for: play.id) != nil)
            check("deleting the selected Preset selects the remaining Preset", result?.board.selectedPresetID == play.id)
            check(
                "deleting the selected Preset preserves the working configuration",
                result?.board.configuration.managedApplications == workApps
            )
            check(
                "deleting the selected Preset never changes the applied baseline",
                result?.board.appliedBaseline == baseline,
                "got \(String(describing: result?.board.appliedBaseline))"
            )
            check("deleting the selected Preset leaves other Presets untouched", result?.library.preset(for: play.id)?.managedApplications == playApps)
        }

        // MARK: - Delete (unselected)

        // Deleting an unselected Preset: removes only it and leaves the working
        // board AND its selection unchanged.
        do {
            let (library, work, play) = freshLibrary()
            let board = BoardState(
                configuration: DeskLayouterConfiguration(managedApplications: workApps),
                selectedPresetID: work.id
            )
            let result = try? PresetEditing.delete(
                id: play.id,
                currentSelection: work.id,
                library: library,
                board: board,
                persist: { _ in }
            )
            check("deleting an unselected Preset removes it", result?.library.preset(for: play.id) == nil)
            check("deleting an unselected Preset leaves the selected Preset in the library", result?.library.preset(for: work.id)?.managedApplications == workApps)
            check("deleting an unselected Preset leaves the working board unchanged", result?.board == board)
            check("deleting an unselected Preset leaves the selection unchanged", result?.board.selectedPresetID == work.id)
        }

        // The sole remaining Preset is blocked before persistence and neither the
        // board nor library changes.
        do {
            var library = PresetLibrary()
            let only = try! library.add(name: "Only", managedApplications: workApps)
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: workApps), selectedPresetID: only.id)
            var persisted = false
            var thrown: PresetDeletionError?
            do {
                _ = try PresetEditing.delete(
                    id: only.id,
                    currentSelection: only.id,
                    library: library,
                    board: board,
                    persist: { _ in persisted = true }
                )
            } catch let error as PresetDeletionError {
                thrown = error
            } catch {}
            check("deleting the sole Preset is rejected", thrown == .lastPreset)
            check("a blocked final delete never persists", !persisted)
            check("a blocked final delete leaves the Preset intact", library.preset(for: only.id) == only)
            check("a blocked final delete leaves the board intact", board.selectedPresetID == only.id)
        }

        // MARK: - Delete persistence failure

        // A persistence failure during delete throws and loses neither the Preset
        // nor the working board.
        do {
            let (library, work, _) = freshLibrary()
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: workApps), selectedPresetID: work.id)
            var threw = false
            do {
                _ = try PresetEditing.delete(id: work.id, currentSelection: work.id, library: library, board: board, persist: { _ in throw SaveFailed() })
            } catch {
                threw = true
            }
            check("a delete persistence failure throws", threw)
            check("a delete persistence failure leaves the stored Preset intact", library.preset(for: work.id)?.managedApplications == workApps)
            check("a delete persistence failure leaves the working board intact", board.configuration.managedApplications == workApps && board.selectedPresetID == work.id)
        }

        // Real-store persistence failure: writing to a path blocked by a regular
        // file throws, so the same guarantee holds end-to-end through the store.
        do {
            let (library, work, _) = freshLibrary()
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: workApps), selectedPresetID: work.id)
            let blocker = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterEditBlocker-\(UUID().uuidString)")
            try? Data("x".utf8).write(to: blocker)
            let store = PresetLibraryStore(fileURL: blocker.appendingPathComponent("presets.json"))
            var deleteThrew = false
            do {
                _ = try PresetEditing.delete(id: work.id, currentSelection: work.id, library: library, board: board, persist: { try store.save($0) })
            } catch {
                deleteThrew = true
            }
            check("a real-store persistence failure during delete throws", deleteThrew)
            var renameThrew = false
            do {
                _ = try PresetEditing.rename(id: work.id, to: "Focus", library: library, persist: { try store.save($0) })
            } catch {
                renameThrew = true
            }
            check("a real-store persistence failure during rename throws", renameThrew)
            try? FileManager.default.removeItem(at: blocker)
        }

        // MARK: - Relaunch persistence through the real store

        // Rename and delete survive a real save/load cycle: the mutated library is
        // exactly what a relaunch reads back.
        do {
            let (library, work, play) = freshLibrary()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterEditReload-\(UUID().uuidString)", isDirectory: true)
            let store = PresetLibraryStore(fileURL: dir.appendingPathComponent("presets.json"))

            let renamed = try? PresetEditing.rename(id: work.id, to: "Focus", library: library, persist: { try store.save($0) })
            let reloadedAfterRename = try? store.load()
            check("a rename is what a relaunch reads back", reloadedAfterRename?.preset(for: work.id)?.name == "Focus", "got \(String(describing: reloadedAfterRename?.preset(for: work.id)?.name))")
            check("a rename reload preserves the snapshot", reloadedAfterRename?.preset(for: work.id)?.managedApplications == workApps)

            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: workApps), selectedPresetID: work.id)
            let deleted = try? PresetEditing.delete(id: play.id, currentSelection: work.id, library: renamed ?? library, board: board, persist: { try store.save($0) })
            let reloadedAfterDelete = try? store.load()
            check("a delete is what a relaunch reads back", reloadedAfterDelete?.preset(for: play.id) == nil && reloadedAfterDelete?.preset(for: work.id) != nil)
            check("delete result matches the reloaded library", deleted?.library == reloadedAfterDelete)

            try? FileManager.default.removeItem(at: dir)
        }

        // MARK: - Cancellation

        // Cancelling a rename or delete preserves the working copy and stored
        // library without side effects. Like PresetSwitch's Cancel, this rests on
        // the operations never mutating their inputs (value semantics) — asserted
        // here so the cancellation path is covered: a cancel that simply drops the
        // pending prompt keeps exactly the models the caller already holds.
        do {
            let (library, work, play) = freshLibrary()
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: workApps), selectedPresetID: work.id)
            let libraryBefore = library
            let boardBefore = board

            _ = try? PresetEditing.rename(id: work.id, to: "Focus", library: library, persist: { _ in })
            _ = try? PresetEditing.delete(id: play.id, currentSelection: work.id, library: library, board: board, persist: { _ in })

            check(
                "Cancel keeps the stored library intact (edit ops never mutate their input library)",
                library == libraryBefore
                    && library.preset(for: work.id)?.name == "Work"
                    && library.preset(for: play.id) != nil
            )
            check(
                "Cancel keeps the working board intact (edit ops never mutate their input board)",
                board == boardBefore
                    && board.selectedPresetID == work.id
            )
        }

        if failures.isEmpty {
            print("Preset editing tests passed")
        } else {
            fatalError("Preset editing tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
