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

        if failures.isEmpty {
            print("Config store tests passed")
        } else {
            fatalError("Config store tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
