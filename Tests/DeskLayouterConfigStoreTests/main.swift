import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

@main
struct ConfigStoreTestRunner {
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

        // Pure serialization round-trip: a configuration encoded to JSON and
        // decoded back is identical. This is the primary unit-tested seam for
        // the source-of-truth config, with no filesystem involved.
        do {
            let configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(
                    bundleIdentifier: "com.example.Writer",
                    displayName: "Writer",
                    desktopNumber: 2
                ),
                ManagedApplication(
                    bundleIdentifier: "com.example.Reader",
                    displayName: "Reader",
                    desktopNumber: 1
                ),
            ])
            let decoded = try? ConfigurationSerialization.decode(
                from: ConfigurationSerialization.encode(configuration)
            )
            check(
                "encode/decode round-trips a configuration",
                decoded == configuration,
                "got \(String(describing: decoded))"
            )
        }

        // Ownership retention: the bundle identifier is persisted exactly as the
        // user added it (including mixed case). Lowercase normalization is the
        // adapter's job, never the source of truth's, so the config keeps the
        // identity needed to later compute the owned normalized key.
        do {
            let configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(
                    bundleIdentifier: "com.Example.MixedCase",
                    displayName: "Mixed Case",
                    desktopNumber: 3
                ),
            ])
            let decoded = try? ConfigurationSerialization.decode(
                from: ConfigurationSerialization.encode(configuration)
            )
            check(
                "managed-app bundle identifier is retained verbatim for ownership",
                decoded?.managedApplications.first?.bundleIdentifier == "com.Example.MixedCase",
                "got \(String(describing: decoded?.managedApplications.first?.bundleIdentifier))"
            )
        }

        // The configuration exposes its managed Assignments for the planner, in
        // the same order they were added.
        do {
            let configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
                ManagedApplication(bundleIdentifier: "com.example.B", displayName: "B", desktopNumber: 2),
            ])
            check(
                "configuration derives Assignments for the planner",
                configuration.assignments == [
                    Assignment(bundleIdentifier: "com.example.A", desktopNumber: 1),
                    Assignment(bundleIdentifier: "com.example.B", desktopNumber: 2),
                ],
                "got \(configuration.assignments)"
            )
        }

        // Upsert: adding an application already managed updates its Assignment
        // (matched by bundle identifier) rather than creating a duplicate, so a
        // managed app is assigned to exactly one Desktop.
        do {
            var configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
            ])
            configuration.upsert(
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 4)
            )
            check(
                "upsert replaces an existing managed app rather than duplicating",
                configuration.managedApplications == [
                    ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 4),
                ],
                "got \(configuration.managedApplications)"
            )
        }

        // Remove: removing a managed app by bundle identifier drops exactly that
        // app, leaving the others in place so only its owned key is deleted on
        // the next Apply.
        do {
            var configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
                ManagedApplication(bundleIdentifier: "com.example.B", displayName: "B", desktopNumber: 2),
            ])
            configuration.remove(bundleIdentifier: "com.example.A")
            check(
                "remove drops only the named managed app",
                configuration.managedApplications == [
                    ManagedApplication(bundleIdentifier: "com.example.B", displayName: "B", desktopNumber: 2),
                ],
                "got \(configuration.managedApplications)"
            )
        }

        // Remove: removing an unknown bundle identifier is a harmless no-op and
        // records no pending removal.
        do {
            var configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
            ])
            configuration.remove(bundleIdentifier: "com.example.Unknown")
            check(
                "removing an unknown bundle identifier changes nothing",
                configuration.managedApplications == [
                    ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
                ] && configuration.pendingRemovals.isEmpty,
                "got \(configuration.managedApplications), pending \(configuration.pendingRemovals)"
            )
        }

        // Ownership across a removal: a removed app is remembered as pending so it
        // stays in the owned set (managed ∪ pending). This is what lets Apply
        // delete a removed app's key even though it is no longer managed.
        do {
            var configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
                ManagedApplication(bundleIdentifier: "com.example.B", displayName: "B", desktopNumber: 2),
            ])
            configuration.remove(bundleIdentifier: "com.example.A")
            check(
                "a removed app is recorded as pending removal",
                configuration.pendingRemovals == ["com.example.A"],
                "got \(configuration.pendingRemovals)"
            )
            check(
                "owned identifiers include managed apps and pending removals",
                configuration.ownedBundleIdentifiers == ["com.example.A", "com.example.B"],
                "got \(configuration.ownedBundleIdentifiers)"
            )
        }

        // Re-adding an app that was pending removal cancels the removal, so its
        // key is not deleted on the next Apply.
        do {
            var configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
            ])
            configuration.remove(bundleIdentifier: "com.example.A")
            configuration.upsert(
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 3)
            )
            check(
                "re-adding a pending-removal app cancels the removal",
                configuration.pendingRemovals.isEmpty
                    && configuration.ownedBundleIdentifiers == ["com.example.A"],
                "pending \(configuration.pendingRemovals), owned \(configuration.ownedBundleIdentifiers)"
            )
        }

        // Clearing pending removals after a successful Apply stops the keys being
        // deleted again.
        do {
            var configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
            ])
            configuration.remove(bundleIdentifier: "com.example.A")
            configuration.clearPendingRemovals()
            check(
                "clearing pending removals empties the owned set once applied",
                configuration.pendingRemovals.isEmpty
                    && configuration.ownedBundleIdentifiers.isEmpty,
                "pending \(configuration.pendingRemovals), owned \(configuration.ownedBundleIdentifiers)"
            )
        }

        // Pending removals persist across encode/decode, so a removal survives
        // quitting the app before Apply. Older files without the key still load.
        do {
            var configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
                ManagedApplication(bundleIdentifier: "com.example.B", displayName: "B", desktopNumber: 2),
            ])
            configuration.remove(bundleIdentifier: "com.example.A")
            let decoded = try? ConfigurationSerialization.decode(
                from: ConfigurationSerialization.encode(configuration)
            )
            check(
                "pending removals round-trip through serialization",
                decoded == configuration && decoded?.pendingRemovals == ["com.example.A"],
                "got \(String(describing: decoded))"
            )

            let legacyJSON = Data(#"{"managedApplications":[]}"#.utf8)
            let legacy = try? ConfigurationSerialization.decode(from: legacyJSON)
            check(
                "a configuration without pendingRemovals decodes with none",
                legacy == DeskLayouterConfiguration(),
                "got \(String(describing: legacy))"
            )
        }

        // File store, missing file: loading before anything is saved yields an
        // empty configuration rather than an error. The store never seeds itself
        // from the macOS Spaces store.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let store = ConfigurationStore(
                fileURL: directory.appendingPathComponent("configuration.json")
            )
            let loaded = try? store.load()
            check(
                "loading a missing config file yields an empty configuration",
                loaded == DeskLayouterConfiguration(),
                "got \(String(describing: loaded))"
            )
        }

        // File store, end-to-end persistence: saving a configuration and loading
        // it back from disk returns an identical configuration.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let fileURL = directory.appendingPathComponent("configuration.json")
            let store = ConfigurationStore(fileURL: fileURL)
            let configuration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.Writer", displayName: "Writer", desktopNumber: 2),
                ManagedApplication(bundleIdentifier: "com.example.Reader", displayName: "Reader", desktopNumber: 1),
            ])

            var reloaded: DeskLayouterConfiguration?
            var wroteToDisk = false
            do {
                try store.save(configuration)
                wroteToDisk = FileManager.default.fileExists(atPath: fileURL.path)
                reloaded = try store.load()
            } catch {
                reloaded = nil
            }

            check("save writes the config file to disk", wroteToDisk)
            check(
                "save then load round-trips through the filesystem",
                reloaded == configuration,
                "got \(String(describing: reloaded))"
            )
            try? FileManager.default.removeItem(at: directory)
        }

        // File store, atomic overwrite: saving again replaces the previous
        // contents, so the file is a faithful mirror of the latest config.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let store = ConfigurationStore(
                fileURL: directory.appendingPathComponent("configuration.json")
            )
            let first = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
            ])
            let second = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.B", displayName: "B", desktopNumber: 2),
            ])
            var reloaded: DeskLayouterConfiguration?
            do {
                try store.save(first)
                try store.save(second)
                reloaded = try store.load()
            } catch {
                reloaded = nil
            }
            check(
                "saving twice overwrites the earlier configuration",
                reloaded == second,
                "got \(String(describing: reloaded))"
            )
            try? FileManager.default.removeItem(at: directory)
        }

        // Board state store, round-trip: saving a board and loading it back from
        // disk returns an identical board, so the pending-versus-applied state
        // survives relaunch.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let store = BoardStateStore(
                fileURL: directory.appendingPathComponent("board-state.json")
            )
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
            ]))
            board.move(bundleIdentifier: "com.example.A", toDesktop: 2)

            var reloaded: BoardState?
            do {
                try store.save(board)
                reloaded = try store.load()
            } catch {
                reloaded = nil
            }
            check("board state save then load round-trips through the filesystem", reloaded == board, "got \(String(describing: reloaded))")
            check("a reloaded dirty board is still dirty", reloaded?.isDirty == true)
            try? FileManager.default.removeItem(at: directory)
        }

        // Board state store, missing everything: loading before anything is saved,
        // with no legacy configuration, yields an empty clean board.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let store = BoardStateStore(
                fileURL: directory.appendingPathComponent("board-state.json")
            )
            let loaded = try? store.load()
            check("loading a missing board yields an empty board", loaded == BoardState(), "got \(String(describing: loaded))")
        }

        // Board state store, legacy migration: with no board-state file but a
        // legacy configuration.json present, the configuration is migrated in as a
        // clean, already-applied board so nothing is lost or falsely pending.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let legacyURL = directory.appendingPathComponent("configuration.json")
            let legacyStore = ConfigurationStore(fileURL: legacyURL)
            let legacyConfiguration = DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.Legacy", displayName: "Legacy", desktopNumber: 2),
            ])
            let store = BoardStateStore(
                fileURL: directory.appendingPathComponent("board-state.json"),
                legacyConfigurationStore: legacyStore
            )
            var migrated: BoardState?
            do {
                try legacyStore.save(legacyConfiguration)
                migrated = try store.load()
            } catch {
                migrated = nil
            }
            check(
                "legacy configuration migrates into the board",
                migrated?.configuration == legacyConfiguration,
                "got \(String(describing: migrated?.configuration))"
            )
            check("a migrated legacy configuration loads clean", migrated?.isDirty == false)
            try? FileManager.default.removeItem(at: directory)
        }

        // Board state store, precedence: when a board-state file exists it is used
        // rather than migrating the legacy configuration.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let legacyStore = ConfigurationStore(
                fileURL: directory.appendingPathComponent("configuration.json")
            )
            let store = BoardStateStore(
                fileURL: directory.appendingPathComponent("board-state.json"),
                legacyConfigurationStore: legacyStore
            )
            let board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.Current", displayName: "Current", desktopNumber: 1),
            ]))
            var loaded: BoardState?
            do {
                try legacyStore.save(DeskLayouterConfiguration(managedApplications: [
                    ManagedApplication(bundleIdentifier: "com.example.Legacy", displayName: "Legacy", desktopNumber: 3),
                ]))
                try store.save(board)
                loaded = try store.load()
            } catch {
                loaded = nil
            }
            check("board-state file takes precedence over legacy migration", loaded == board, "got \(String(describing: loaded))")
            try? FileManager.default.removeItem(at: directory)
        }

        // Preset library store, missing file: loading before any Preset is saved
        // yields an empty library rather than an error, so a fresh install starts
        // with no Presets (and the board shows "Custom Setup").
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let store = PresetLibraryStore(fileURL: directory.appendingPathComponent("presets.json"))
            let loaded = try? store.load()
            check("loading a missing Preset library yields an empty library", loaded == PresetLibrary(), "got \(String(describing: loaded))")
        }

        // Preset library store, relaunch restoration: saving a library and loading
        // it back returns an identical library, so saved Presets and their captured
        // Layouts survive quitting and relaunching.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let fileURL = directory.appendingPathComponent("presets.json")
            let store = PresetLibraryStore(fileURL: fileURL)
            var library = PresetLibrary()
            let layout = Layout(horizontalDivision: .halves, verticalDivision: .halves, columnSpan: .single(0), rowSpan: .single(0))
            _ = try? library.add(name: "Work", managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.Writer", displayName: "Writer", desktopNumber: 1, layout: layout),
            ])
            _ = try? library.add(name: "Play", managedApplications: [])

            var reloaded: PresetLibrary?
            var wroteToDisk = false
            do {
                try store.save(library)
                wroteToDisk = FileManager.default.fileExists(atPath: fileURL.path)
                reloaded = try store.load()
            } catch {
                reloaded = nil
            }
            check("save writes the Preset library file to disk", wroteToDisk)
            check("Preset library save then load round-trips through the filesystem", reloaded == library, "got \(String(describing: reloaded))")
            try? FileManager.default.removeItem(at: directory)
        }

        // Preset library store, tolerant of a damaged file: a partial document
        // decodes to an empty library rather than throwing, so a corrupt Presets
        // file never blocks launch or destroys the working board.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("presets.json")
            try? Data("{}".utf8).write(to: fileURL)
            let store = PresetLibraryStore(fileURL: fileURL)
            let loaded = try? store.load()
            check("a partial Preset library file decodes as empty", loaded == PresetLibrary(), "got \(String(describing: loaded))")
            try? FileManager.default.removeItem(at: directory)
        }

        // Board state store, selected-Preset association: the working copy's
        // selected-Preset association survives quitting and relaunching.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            let store = BoardStateStore(fileURL: directory.appendingPathComponent("board-state.json"))
            let presetID = UUID()
            var board = BoardState(configuration: DeskLayouterConfiguration(managedApplications: [
                ManagedApplication(bundleIdentifier: "com.example.A", displayName: "A", desktopNumber: 1),
            ]))
            board.associateSelectedPreset(presetID)

            var reloaded: BoardState?
            do {
                try store.save(board)
                reloaded = try store.load()
            } catch {
                reloaded = nil
            }
            check("the selected-Preset association survives relaunch", reloaded?.selectedPresetID == presetID, "got \(String(describing: reloaded?.selectedPresetID))")
            check("a relaunched board with an association is not dirtied by it", reloaded?.isDirty == false)
            try? FileManager.default.removeItem(at: directory)
        }

        // Board state store, migration keeps Custom Setup: an existing board-state
        // file written before Presets existed loads with no selected Preset (shown
        // as "Custom Setup"), and no Preset is created for it.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskLayouterTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("board-state.json")
            let legacyBoardJSON = Data(#"{"configuration":{"managedApplications":[{"bundleIdentifier":"com.example.A","displayName":"A","desktopNumber":1}]},"appliedBaseline":{"com.example.A":1}}"#.utf8)
            try? legacyBoardJSON.write(to: fileURL)
            let store = BoardStateStore(fileURL: fileURL)
            let loaded = try? store.load()
            check("a pre-Presets board migrates with no selected Preset", loaded?.selectedPresetID == nil)
            check("a migrated pre-Presets board loads clean", loaded?.isDirty == false)
            try? FileManager.default.removeItem(at: directory)
        }

        if failures.isEmpty {
            print("Config store tests passed")
        } else {
            fatalError("Config store tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
