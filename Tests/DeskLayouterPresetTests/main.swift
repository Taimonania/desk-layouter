import DeskLayouterCore
import Foundation

@main
struct PresetTestRunner {
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

        // Creation: saving the current board captures every managed application,
        // its Assignment, and its optional Layout under the chosen name, and the
        // new Preset is retrievable by its identity.
        do {
            let layout = Layout(horizontalDivision: .halves, verticalDivision: .halves, columnSpan: .single(0), rowSpan: .single(0))
            var library = PresetLibrary()
            let apps = [
                app("Writer", "com.example.Writer", desktop: 1, layout: layout),
                app("Reader", "com.example.Reader", desktop: 2),
            ]
            let created = try? library.add(name: "Work", managedApplications: apps)
            check("creating a Preset returns it", created != nil)
            check("created Preset carries the chosen name", created?.name == "Work", "got \(String(describing: created?.name))")
            check("created Preset captures Assignments and Layouts", created?.managedApplications == apps, "got \(String(describing: created?.managedApplications))")
            check("created Preset is retrievable by id", library.preset(for: created?.id ?? UUID())?.name == "Work")
        }

        // Empty Preset: an empty board is a valid Preset — saving with no managed
        // applications succeeds and captures an empty snapshot.
        do {
            var library = PresetLibrary()
            let created = try? library.add(name: "Empty", managedApplications: [])
            check("an empty board saves as a valid Preset", created?.managedApplications.isEmpty == true)
            check("the empty Preset is stored", library.orderedPresets.map(\.name) == ["Empty"], "got \(library.orderedPresets.map(\.name))")
        }

        // Name validation, empty: a name that is empty or only whitespace is
        // rejected, and the library is left unchanged.
        do {
            var library = PresetLibrary()
            var thrown: PresetNameError?
            do { _ = try library.add(name: "   ", managedApplications: []) }
            catch let error as PresetNameError { thrown = error }
            catch {}
            check("an empty name is rejected as empty", thrown == .empty, "got \(String(describing: thrown))")
            check("a rejected empty name adds no Preset", library.presets.isEmpty)
        }

        // Name validation, trimming: a valid name is stored trimmed of
        // surrounding whitespace.
        do {
            var library = PresetLibrary()
            let created = try? library.add(name: "  Focus  ", managedApplications: [])
            check("a name is stored trimmed", created?.name == "Focus", "got \(String(describing: created?.name))")
        }

        // Name validation, case-insensitive uniqueness: a name that collides with
        // an existing Preset ignoring capitalization is rejected without replacing
        // the existing Preset.
        do {
            var library = PresetLibrary()
            _ = try? library.add(name: "Work", managedApplications: [app("A", "com.example.A", desktop: 1)])
            var thrown: PresetNameError?
            do { _ = try library.add(name: "WORK", managedApplications: [app("B", "com.example.B", desktop: 2)]) }
            catch let error as PresetNameError { thrown = error }
            catch {}
            check("a case-insensitive duplicate name is rejected", thrown == .duplicate(existingName: "Work"), "got \(String(describing: thrown))")
            check("a rejected duplicate does not add a second Preset", library.presets.count == 1, "got \(library.presets.count)")
            check(
                "a rejected duplicate leaves the original Preset untouched",
                library.orderedPresets.first?.managedApplications.map(\.bundleIdentifier) == ["com.example.A"],
                "got \(String(describing: library.orderedPresets.first?.managedApplications))"
            )
        }

        // Ordering: Presets appear alphabetically using a locale-aware,
        // Finder-style comparison (so numbers sort naturally and case does not
        // fracture the order), regardless of insertion order.
        do {
            var library = PresetLibrary()
            _ = try? library.add(name: "banana", managedApplications: [])
            _ = try? library.add(name: "Apple", managedApplications: [])
            _ = try? library.add(name: "Desk 10", managedApplications: [])
            _ = try? library.add(name: "Desk 2", managedApplications: [])
            check(
                "Presets are ordered alphabetically, locale-aware",
                library.orderedPresets.map(\.name) == ["Apple", "banana", "Desk 2", "Desk 10"],
                "got \(library.orderedPresets.map(\.name))"
            )
        }

        // Explicit update: updating a Preset replaces its captured board while
        // keeping its name and identity, and does not touch any other Preset.
        do {
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: [app("A", "com.example.A", desktop: 1)])
            _ = try? library.add(name: "Play", managedApplications: [app("B", "com.example.B", desktop: 2)])
            library.update(id: work.id, managedApplications: [app("A", "com.example.A", desktop: 3), app("C", "com.example.C", desktop: 1)])
            let updated = library.preset(for: work.id)
            check("update keeps the Preset name and identity", updated?.name == "Work" && updated?.id == work.id)
            check(
                "update replaces the captured board",
                updated?.managedApplications == [app("A", "com.example.A", desktop: 3), app("C", "com.example.C", desktop: 1)],
                "got \(String(describing: updated?.managedApplications))"
            )
            check(
                "update leaves other Presets untouched",
                library.orderedPresets.first(where: { $0.name == "Play" })?.managedApplications.map(\.bundleIdentifier) == ["com.example.B"]
            )
        }

        // Update no-op: updating an id that is not in the library changes nothing.
        do {
            var library = PresetLibrary()
            _ = try? library.add(name: "Work", managedApplications: [app("A", "com.example.A", desktop: 1)])
            let before = library
            library.update(id: UUID(), managedApplications: [app("Z", "com.example.Z", desktop: 9)])
            check("updating an unknown id changes nothing", library == before)
        }

        // Serialization compatibility: a library round-trips through JSON so
        // Presets and their captured Layouts survive relaunch, and a document
        // without a `presets` key decodes as empty rather than failing.
        do {
            let layout = Layout(horizontalDivision: .thirds, verticalDivision: .halves, columnSpan: .single(2), rowSpan: .single(0))
            var library = PresetLibrary()
            _ = try? library.add(name: "Work", managedApplications: [app("Writer", "com.example.Writer", desktop: 1, layout: layout)])
            _ = try? library.add(name: "Play", managedApplications: [])
            let decoded = try? PresetLibrarySerialization.decode(from: PresetLibrarySerialization.encode(library))
            check("a Preset library round-trips through serialization", decoded == library, "got \(String(describing: decoded))")
            check(
                "a Preset's captured Layout survives serialization",
                decoded?.preset(for: library.orderedPresets.first(where: { $0.name == "Work" })!.id)?.managedApplications.first?.layout == layout
            )

            let emptyDoc = Data("{}".utf8)
            let empty = try? PresetLibrarySerialization.decode(from: emptyDoc)
            check("a library document without presets decodes as empty", empty == PresetLibrary(), "got \(String(describing: empty))")
        }

        // Dirty-relative-to-Preset detection: the switching-protection safeguard
        // keys off whether the complete working board (managed apps, Assignments,
        // Layouts) still matches the selected Preset. This is distinct from pending
        // Assignments awaiting Apply.
        do {
            let layout = Layout(horizontalDivision: .halves, verticalDivision: .halves, columnSpan: .single(0), rowSpan: .single(0))
            let base = [
                app("Writer", "com.example.Writer", desktop: 1, layout: layout),
                app("Reader", "com.example.Reader", desktop: 2),
            ]
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: base)

            func config(_ apps: [ManagedApplication]) -> DeskLayouterConfiguration {
                DeskLayouterConfiguration(managedApplications: apps)
            }

            check(
                "an unchanged working copy is not modified relative to its Preset",
                library.isModified(config(base), from: work.id) == false
            )
            check(
                "a reordered working copy is not modified (order is not semantic)",
                library.isModified(config(base.reversed()), from: work.id) == false
            )
            check(
                "pendingRemovals alone do not count as a Preset modification",
                library.isModified(
                    DeskLayouterConfiguration(managedApplications: base, pendingRemovals: ["com.example.Gone"]),
                    from: work.id
                ) == false
            )
            check(
                "an Assignment-only change is detected as modified",
                library.isModified(
                    config([app("Writer", "com.example.Writer", desktop: 1, layout: layout), app("Reader", "com.example.Reader", desktop: 3)]),
                    from: work.id
                )
            )
            check(
                "a Layout-only change is detected as modified",
                library.isModified(
                    config([app("Writer", "com.example.Writer", desktop: 1), app("Reader", "com.example.Reader", desktop: 2)]),
                    from: work.id
                )
            )
            check(
                "adding an application is detected as modified",
                library.isModified(
                    config(base + [app("Mail", "com.example.Mail", desktop: 1)]),
                    from: work.id
                )
            )
            check(
                "removing an application is detected as modified",
                library.isModified(config([base[0]]), from: work.id)
            )
            check(
                "a legacy nil selection is not modified relative to a Preset before reconciliation",
                library.isModified(config(base), from: nil) == false
            )
            check(
                "a legacy dangling selection is not modified relative to a Preset before reconciliation",
                library.isModified(config(base), from: UUID()) == false
            )
        }

        // Empty boards: an empty working copy matches an empty Preset, and adding
        // to an empty Preset is a modification.
        do {
            var library = PresetLibrary()
            let empty = try! library.add(name: "Empty", managedApplications: [])
            check(
                "an empty working copy matches an empty Preset",
                library.isModified(DeskLayouterConfiguration(), from: empty.id) == false
            )
            check(
                "populating an empty Preset's working copy is a modification",
                library.isModified(
                    DeskLayouterConfiguration(managedApplications: [app("A", "com.example.A", desktop: 1)]),
                    from: empty.id
                )
            )
        }

        // Rename: succeeds, preserves the complete stored snapshot (identity and
        // captured board), and reuses the exact creation validation — non-empty,
        // trimmed, case-insensitive uniqueness.
        do {
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: [app("A", "com.example.A", desktop: 1, layout: Layout(horizontalDivision: .halves, verticalDivision: .halves, columnSpan: .single(0), rowSpan: .single(0)))])
            let renamed = try? library.rename(id: work.id, to: "  Focus  ")
            check("rename returns the renamed Preset", renamed?.name == "Focus", "got \(String(describing: renamed?.name))")
            check("rename keeps the Preset identity", library.preset(for: work.id)?.id == work.id)
            check(
                "rename preserves the complete stored snapshot",
                library.preset(for: work.id)?.managedApplications == work.managedApplications,
                "got \(String(describing: library.preset(for: work.id)?.managedApplications))"
            )
            check("rename applies the new name", library.preset(for: work.id)?.name == "Focus")
        }

        // Rename, recapitalization: a Preset can be renamed to a different
        // capitalization of its own name — it does not collide with itself.
        do {
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: [])
            let renamed = try? library.rename(id: work.id, to: "WORK")
            check("a Preset can be recapitalized without colliding with itself", renamed?.name == "WORK", "got \(String(describing: renamed?.name))")
        }

        // Rename, empty: an empty or whitespace-only name is rejected and the
        // Preset keeps its old name.
        do {
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: [])
            var thrown: PresetNameError?
            do { _ = try library.rename(id: work.id, to: "   ") }
            catch let error as PresetNameError { thrown = error }
            catch {}
            check("renaming to an empty name is rejected as empty", thrown == .empty, "got \(String(describing: thrown))")
            check("a rejected empty rename keeps the old name", library.preset(for: work.id)?.name == "Work")
        }

        // Rename, duplicate: renaming onto another Preset's name (ignoring
        // capitalization) is rejected and neither Preset changes.
        do {
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: [app("A", "com.example.A", desktop: 1)])
            let play = try! library.add(name: "Play", managedApplications: [app("B", "com.example.B", desktop: 2)])
            var thrown: PresetNameError?
            do { _ = try library.rename(id: play.id, to: "WORK") }
            catch let error as PresetNameError { thrown = error }
            catch {}
            check("renaming onto another Preset's name is rejected as duplicate", thrown == .duplicate(existingName: "Work"), "got \(String(describing: thrown))")
            check("a rejected duplicate rename leaves the renamed Preset unchanged", library.preset(for: play.id)?.name == "Play")
            check("a rejected duplicate rename leaves the collided Preset unchanged", library.preset(for: work.id)?.name == "Work")
        }

        // Rename, unknown id: validates the name first, then no-ops (nil) for an
        // id no longer in the library, changing nothing.
        do {
            var library = PresetLibrary()
            _ = try! library.add(name: "Work", managedApplications: [])
            let before = library
            let renamed = try? library.rename(id: UUID(), to: "Ghost")
            check("renaming an unknown id returns nil", renamed == nil)
            check("renaming an unknown id changes nothing", library == before)
        }

        // Delete: removes only the named Preset and returns it; other Presets
        // remain untouched.
        do {
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: [app("A", "com.example.A", desktop: 1)])
            let play = try! library.add(name: "Play", managedApplications: [app("B", "com.example.B", desktop: 2)])
            let removed = library.delete(id: work.id)
            check("delete returns the removed Preset", removed?.id == work.id)
            check("delete removes the Preset from the library", library.preset(for: work.id) == nil)
            check("delete leaves other Presets untouched", library.orderedPresets.map(\.name) == ["Play"], "got \(library.orderedPresets.map(\.name))")
            check("delete leaves the other Preset's board intact", library.preset(for: play.id)?.managedApplications.map(\.bundleIdentifier) == ["com.example.B"])
        }

        // Delete, unknown id: deleting an id no longer in the library is a no-op
        // returning nil.
        do {
            var library = PresetLibrary()
            _ = try! library.add(name: "Work", managedApplications: [])
            let before = library
            let removed = library.delete(id: UUID())
            check("deleting an unknown id returns nil", removed == nil)
            check("deleting an unknown id changes nothing", library == before)
        }

        // Delete last: the library refuses to reach zero Presets.
        do {
            var library = PresetLibrary()
            let only = try! library.add(name: "Only", managedApplications: [])
            let removed = library.delete(id: only.id)
            check("deleting the last Preset is blocked", removed == nil)
            check("the last Preset remains intact", library.presets == [only])
        }

        // Relaunch persistence of a rename/delete: the mutated library survives a
        // serialization round-trip with names and snapshots intact.
        do {
            var library = PresetLibrary()
            let work = try! library.add(name: "Work", managedApplications: [app("A", "com.example.A", desktop: 1)])
            _ = try! library.add(name: "Play", managedApplications: [app("B", "com.example.B", desktop: 2)])
            _ = try! library.rename(id: work.id, to: "Focus")
            let decoded = try? PresetLibrarySerialization.decode(from: PresetLibrarySerialization.encode(library))
            check("a renamed library survives serialization", decoded?.preset(for: work.id)?.name == "Focus", "got \(String(describing: decoded?.preset(for: work.id)?.name))")
            check("a renamed Preset keeps its snapshot across serialization", decoded?.preset(for: work.id)?.managedApplications.map(\.bundleIdentifier) == ["com.example.A"])
        }

        if failures.isEmpty {
            print("Preset tests passed")
        } else {
            fatalError("Preset tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
