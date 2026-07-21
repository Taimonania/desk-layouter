import Foundation

/// One application offered in the app picker: its display name, its bundle
/// identifier, and whether it is currently running.
///
/// This is a pure value type with no AppKit dependency. The side-effectful
/// enumeration of installed apps (`/Applications` and system locations) and the
/// query of `NSWorkspace.shared.runningApplications` live behind a provider in
/// the macOS layer; this type is what that provider produces and what the pure
/// filtering/merge logic below operates on.
public struct InstalledApplication: Equatable, Sendable, Identifiable {
    public let displayName: String
    public let bundleIdentifier: String
    public let isRunning: Bool

    public init(displayName: String, bundleIdentifier: String, isRunning: Bool) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
    }

    /// Stable identity for list selection: the bundle identifier uniquely
    /// identifies an application.
    public var id: String { bundleIdentifier }

    /// The name to show the user — the raw ``displayName`` with any trailing
    /// `.app` removed (issue #39). ``displayName`` stays raw for search,
    /// sorting, and matching; only presentation uses this.
    public var presentedName: String { ApplicationDisplayName.presented(displayName) }
}

/// Pure catalog logic for the app picker: merging installed apps with the
/// currently-running set, and filtering the merged list by search text and the
/// "Currently running" toggle.
///
/// This is the picker's unit-tested seam. It has no filesystem, no NSWorkspace,
/// and no UI — it operates only on the fabricated `InstalledApplication` values
/// its callers pass in, so it can be exercised directly in tests.
public enum ApplicationCatalog {
    /// Merges the enumerated installed applications with the currently-running
    /// applications into one deduplicated, name-sorted list.
    ///
    /// Every installed application is marked `isRunning` when its bundle
    /// identifier appears among the running set. Running applications that are
    /// not among the installed locations are still included (marked running), so
    /// the "Currently running" toggle can offer everything the user has open,
    /// even apps launched from unusual locations. Duplicate bundle identifiers
    /// keep their first occurrence. The result is sorted case-insensitively by
    /// display name for a stable picker order.
    public static func merge(
        installed: [InstalledApplication],
        running: [InstalledApplication]
    ) -> [InstalledApplication] {
        let runningIdentifiers = Set(running.map(\.bundleIdentifier))

        var merged: [String: InstalledApplication] = [:]
        var order: [String] = []

        func insertIfNew(_ application: InstalledApplication) {
            guard merged[application.bundleIdentifier] == nil else { return }
            merged[application.bundleIdentifier] = application
            order.append(application.bundleIdentifier)
        }

        for application in installed {
            insertIfNew(
                InstalledApplication(
                    displayName: application.displayName,
                    bundleIdentifier: application.bundleIdentifier,
                    isRunning: runningIdentifiers.contains(application.bundleIdentifier)
                )
            )
        }
        for application in running {
            insertIfNew(
                InstalledApplication(
                    displayName: application.displayName,
                    bundleIdentifier: application.bundleIdentifier,
                    isRunning: true
                )
            )
        }

        return order
            .compactMap { merged[$0] }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    /// Filters the merged application list for display.
    ///
    /// When `runningOnly` is true only currently-running applications remain.
    /// When `searchText` is non-empty (ignoring surrounding whitespace) only
    /// applications whose display name contains it, case-insensitively, remain.
    /// The two filters compose: a search within the running-only subset. Input
    /// order is preserved.
    public static func filtered(
        _ applications: [InstalledApplication],
        searchText: String,
        runningOnly: Bool
    ) -> [InstalledApplication] {
        var result = applications
        if runningOnly {
            result = result.filter(\.isRunning)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
        return result
    }
}
