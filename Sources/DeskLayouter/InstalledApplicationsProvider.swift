import AppKit
import DeskLayouterCore
import Foundation

/// Supplies the merged list of applications the picker offers.
///
/// This is the side-effectful boundary for the picker, mirroring how
/// `SpacesAdapter` and `ConfigurationStore` isolate their side effects: it is
/// the only place that scans the filesystem for installed apps and queries
/// `NSWorkspace.shared.runningApplications`. Injecting a fabricated conforming
/// type lets the model be driven without touching the real system; the pure
/// merge/filter logic lives in `ApplicationCatalog` in Core.
public protocol InstalledApplicationsProviding {
    /// The installed applications merged with the currently-running set, sorted
    /// and deduplicated for display.
    func applications() -> [InstalledApplication]
}

/// The production provider: enumerates application bundles in `/Applications`
/// and the standard system locations, queries the running applications, and
/// merges them through `ApplicationCatalog`.
public struct SystemInstalledApplicationsProvider: InstalledApplicationsProviding {
    /// The directories scanned for installed application bundles. These are the
    /// standard user- and system-level application locations.
    private static let searchDirectories: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSString(string: "~/Applications").expandingTildeInPath,
    ]

    private let fileManager: FileManager
    private let workspace: NSWorkspace

    public init(fileManager: FileManager = .default, workspace: NSWorkspace = .shared) {
        self.fileManager = fileManager
        self.workspace = workspace
    }

    public func applications() -> [InstalledApplication] {
        ApplicationCatalog.merge(
            installed: scanInstalledApplications(),
            running: runningApplications()
        )
    }

    /// Enumerates `.app` bundles in the search directories that expose a bundle
    /// identifier. Directories that do not exist are skipped.
    private func scanInstalledApplications() -> [InstalledApplication] {
        var applications: [InstalledApplication] = []
        for directory in Self.searchDirectories {
            let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries where entry.pathExtension == "app" {
                guard let bundleIdentifier = Bundle(url: entry)?.bundleIdentifier else {
                    continue
                }
                let displayName = fileManager.displayName(atPath: entry.path)
                applications.append(
                    InstalledApplication(
                        displayName: displayName,
                        bundleIdentifier: bundleIdentifier,
                        isRunning: false
                    )
                )
            }
        }
        return applications
    }

    /// The currently-running applications that expose a bundle identifier.
    private func runningApplications() -> [InstalledApplication] {
        workspace.runningApplications.compactMap { application in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return nil
            }
            let displayName = application.localizedName ?? bundleIdentifier
            return InstalledApplication(
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                isRunning: true
            )
        }
    }
}
