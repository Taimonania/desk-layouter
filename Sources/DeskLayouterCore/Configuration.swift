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

    /// Where this application's window sits on its Desktop's screen, or `nil`
    /// when the app is not arranged. A missing Layout is the norm: most managed
    /// apps only carry an Assignment (which Desktop), not a Layout (where on it).
    ///
    /// The synthesized `Codable` conformance decodes an optional with
    /// `decodeIfPresent`, so configurations written before Layout existed still
    /// load with `layout == nil` — the same tolerance the ``pendingRemovals``
    /// pattern gives ``DeskLayouterConfiguration``.
    public var layout: Layout?

    public init(
        bundleIdentifier: String,
        displayName: String,
        desktopNumber: Int,
        layout: Layout? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.desktopNumber = desktopNumber
        self.layout = layout
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

    /// Bundle identifiers of applications the user removed whose macOS bindings
    /// have not yet been deleted. Once an app is dropped from
    /// ``managedApplications`` there is nothing left to tell the adapter the key
    /// was ever ours, so a removal is remembered here until the next Apply
    /// deletes its owned key (issue #7) and clears the record. It is persisted so
    /// a removal survives quitting the app before Apply.
    public private(set) var pendingRemovals: [String]

    public init(
        managedApplications: [ManagedApplication] = [],
        pendingRemovals: [String] = []
    ) {
        self.managedApplications = managedApplications
        self.pendingRemovals = pendingRemovals
    }

    private enum CodingKeys: String, CodingKey {
        case managedApplications
        case pendingRemovals
    }

    // Tolerant decoding so configurations written before pending removals
    // existed still load (the key simply defaults to empty).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        managedApplications = try container.decode(
            [ManagedApplication].self,
            forKey: .managedApplications
        )
        pendingRemovals = try container.decodeIfPresent(
            [String].self,
            forKey: .pendingRemovals
        ) ?? []
    }

    /// The managed Assignments, in the order they were added, ready to be
    /// resolved by `AssignmentPlanner.appBindings(for:on:)`.
    public var assignments: [Assignment] {
        managedApplications.map(\.assignment)
    }

    /// The managed application with the given bundle identifier, if any.
    public func managedApplication(for bundleIdentifier: String) -> ManagedApplication? {
        managedApplications.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Every bundle identifier whose macOS key the app owns on the next Apply:
    /// the currently managed apps plus the apps pending removal. Handing this to
    /// the adapter lets removed apps' keys be deleted while unmanaged system
    /// entries are preserved.
    public var ownedBundleIdentifiers: Set<String> {
        Set(managedApplications.map(\.bundleIdentifier)).union(pendingRemovals)
    }

    /// Adds a managed application, or updates the existing one with the same
    /// bundle identifier. This keeps each managed app assigned to exactly one
    /// Desktop, matching how macOS itself models Assignments. Re-adding an app
    /// that was pending removal cancels the removal.
    public mutating func upsert(_ application: ManagedApplication) {
        pendingRemovals.removeAll { $0 == application.bundleIdentifier }
        if let index = managedApplications.firstIndex(
            where: { $0.bundleIdentifier == application.bundleIdentifier }
        ) {
            managedApplications[index] = application
        } else {
            managedApplications.append(application)
        }
    }

    /// Removes the managed application with the given bundle identifier, if
    /// present, and records it as pending removal so the next Apply deletes only
    /// its owned key from the macOS bindings (issue #7).
    public mutating func remove(bundleIdentifier: String) {
        let wasManaged = managedApplications.contains { $0.bundleIdentifier == bundleIdentifier }
        managedApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        if wasManaged, !pendingRemovals.contains(bundleIdentifier) {
            pendingRemovals.append(bundleIdentifier)
        }
    }

    /// Clears the pending removals after a successful Apply has deleted their
    /// keys, so they are not deleted again on subsequent Applies.
    public mutating func clearPendingRemovals() {
        pendingRemovals = []
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
