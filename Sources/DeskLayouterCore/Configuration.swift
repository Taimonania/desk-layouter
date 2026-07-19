import Foundation

/// One application the user has added to Desk Layouter, together with the
/// Desktop it is assigned to open on.
///
/// The `bundleIdentifier` is stored exactly as the user added it (not
/// lowercased). This is deliberate: it is the persisted managed-app identity
/// that lets the adapter compute the owned normalized `app-bindings` key later,
/// so a previously applied Assignment can be removed (issue #7) without treating
/// unmanaged system bindings as managed. macOS-specific lowercase normalization
/// stays in the adapter (ADR-0001), never in this source-of-truth model.
public struct ManagedApplication: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public var desktopNumber: Int

    public init(bundleIdentifier: String, displayName: String, desktopNumber: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.desktopNumber = desktopNumber
    }

    /// The managed application's Assignment, as consumed by the planner.
    public var assignment: Assignment {
        Assignment(bundleIdentifier: bundleIdentifier, desktopNumber: desktopNumber)
    }
}

/// The persisted Desk Layouter configuration: the applications the app manages
/// and their Assignments.
///
/// This is the single source of truth for what the app owns. Both macOS
/// representations (persistent `com.apple.spaces` `app-bindings` and the
/// current-session WindowServer binding table) are derived from it on each
/// Apply. It is only ever written from user actions — it is never seeded by
/// reading the macOS Spaces store, so unmanaged system bindings never enter it.
public struct DeskLayouterConfiguration: Codable, Equatable, Sendable {
    public var managedApplications: [ManagedApplication]

    public init(managedApplications: [ManagedApplication] = []) {
        self.managedApplications = managedApplications
    }

    /// The managed Assignments, in the order they were added, ready to be
    /// resolved by `AssignmentPlanner.appBindings(for:on:)`.
    public var assignments: [Assignment] {
        managedApplications.map(\.assignment)
    }

    /// Adds a managed application, or updates the existing one with the same
    /// bundle identifier. This keeps each managed app assigned to exactly one
    /// Desktop, matching how macOS itself models Assignments.
    public mutating func upsert(_ application: ManagedApplication) {
        if let index = managedApplications.firstIndex(
            where: { $0.bundleIdentifier == application.bundleIdentifier }
        ) {
            managedApplications[index] = application
        } else {
            managedApplications.append(application)
        }
    }
}

/// Pure JSON serialization for the configuration — the encode/decode seam,
/// with no filesystem access. File I/O lives behind `ConfigurationStore` in the
/// macOS adapter layer.
public enum ConfigurationSerialization {
    public static func encode(_ configuration: DeskLayouterConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configuration)
    }

    public static func decode(from data: Data) throws -> DeskLayouterConfiguration {
        try JSONDecoder().decode(DeskLayouterConfiguration.self, from: data)
    }
}
