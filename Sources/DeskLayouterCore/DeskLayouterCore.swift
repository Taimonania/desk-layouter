public struct Assignment: Equatable, Sendable {
    public let bundleIdentifier: String
    /// `nil` is accepted only for tolerant legacy decoding before migration.
    public let display: DisplayIdentity?
    public let desktopNumber: Int

    public init(
        bundleIdentifier: String,
        display: DisplayIdentity,
        desktopNumber: Int
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.display = display
        self.desktopNumber = desktopNumber
    }

    public static func legacy(
        bundleIdentifier: String,
        desktopNumber: Int
    ) -> Assignment {
        Assignment(
            bundleIdentifier: bundleIdentifier,
            legacyDisplay: nil,
            desktopNumber: desktopNumber
        )
    }

    private init(
        bundleIdentifier: String,
        legacyDisplay: DisplayIdentity?,
        desktopNumber: Int
    ) {
        self.bundleIdentifier = bundleIdentifier
        display = legacyDisplay
        self.desktopNumber = desktopNumber
    }
}

public struct DesktopSnapshot: Equatable, Sendable {
    /// The physical Display whose ordered Desktops were resolved. `nil` supports
    /// older test and adapter callers; production snapshots always carry it.
    public let display: DisplayIdentity?
    public let orderedDesktopUUIDs: [String]

    public init(
        display: DisplayIdentity? = nil,
        orderedDesktopUUIDs: [String]
    ) {
        self.display = display
        self.orderedDesktopUUIDs = orderedDesktopUUIDs
    }

    public func concreteDesktopUUID(at desktopNumber: Int) -> String? {
        let index = desktopNumber - 1
        guard orderedDesktopUUIDs.indices.contains(index) else { return nil }
        return orderedDesktopUUIDs[index]
    }
}

public enum AssignmentPlanningError: Error, Equatable {
    case desktopDoesNotExist(Int)
}

public struct AssignmentPlanner: Sendable {
    public init() {}

    /// Plans a complete multi-Display Apply. Only an explicitly removed managed
    /// app is deleted; a disconnected Display or out-of-range Desktop is a
    /// preservation, never an implicit deletion.
    public func applyPlan(
        configuration: DeskLayouterConfiguration,
        on topology: DisplayTopologySnapshot
    ) -> AssignmentApplyPlan {
        var updates: [String: String] = [:]
        var preservations: Set<String> = []
        for application in configuration.managedApplications {
            guard
                let display = application.display,
                let uuid = topology.concreteDesktopUUID(
                    display: display,
                    desktopNumber: application.desktopNumber
                )
            else {
                preservations.insert(application.bundleIdentifier)
                continue
            }
            updates[application.bundleIdentifier] = uuid
        }
        return AssignmentApplyPlan(
            updates: updates,
            deletions: Set(configuration.pendingRemovals),
            preservations: preservations
        )
    }

    /// Resolves a collection of managed Assignments against a Desktop snapshot
    /// into the logical managed bindings (`bundleID → Desktop UUID`).
    ///
    /// This is the project's primary unit-tested seam: a pure function with no
    /// access to the real store, Dock, WindowServer, or filesystem. It resolves
    /// each Desktop number (1-based) to the Desktop UUID at that position,
    /// emits an entry only for the given (managed) Assignments, and returns an
    /// empty dictionary for an empty configuration.
    ///
    /// Assignments whose Desktop number no longer refers to an existing Desktop
    /// are skipped rather than throwing: per the MVP spec (issue #1, user story
    /// 17) deleting a Desktop must be "skipped safely" so that one stale
    /// Assignment cannot fail the Apply for every other app. The single
    /// Assignment overload below deliberately keeps its throwing behavior for
    /// the single-assignment UI, where the user just picked a specific Desktop
    /// and should be told that exact number is invalid.
    ///
    /// No macOS-specific lowercase bundle-ID normalization or merging with
    /// unmanaged system bindings happens here — those remain the adapter's
    /// responsibility (ADR-0001). Bundle identifiers are emitted verbatim.
    public func appBindings(
        for assignments: [Assignment],
        on desktops: DesktopSnapshot
    ) -> [String: String] {
        var bindings: [String: String] = [:]
        for assignment in assignments {
            guard let desktopUUID = resolvedDesktopUUID(for: assignment, on: desktops) else {
                continue
            }
            bindings[assignment.bundleIdentifier] = desktopUUID
        }
        return bindings
    }

    /// Resolves a single managed Assignment against a Desktop snapshot.
    ///
    /// Unlike the collection overload, this throws
    /// ``AssignmentPlanningError/desktopDoesNotExist(_:)`` when the Desktop
    /// number is out of range, so the single-assignment UI (#3) can surface the
    /// specific invalid Desktop number to the user.
    public func appBindings(
        for assignment: Assignment,
        on desktops: DesktopSnapshot
    ) throws -> [String: String] {
        guard let desktopUUID = resolvedDesktopUUID(for: assignment, on: desktops) else {
            throw AssignmentPlanningError.desktopDoesNotExist(assignment.desktopNumber)
        }

        return [assignment.bundleIdentifier: desktopUUID]
    }

    /// Resolves an Assignment's 1-based Desktop number to the Desktop UUID at
    /// that position, or `nil` when the number falls outside the snapshot.
    private func resolvedDesktopUUID(
        for assignment: Assignment,
        on desktops: DesktopSnapshot
    ) -> String? {
        if let assignmentDisplay = assignment.display,
           let snapshotDisplay = desktops.display,
           !assignmentDisplay.identifiesSameDisplay(as: snapshotDisplay) {
            return nil
        }
        let desktopIndex = assignment.desktopNumber - 1
        guard desktops.orderedDesktopUUIDs.indices.contains(desktopIndex) else {
            return nil
        }
        return desktops.orderedDesktopUUIDs[desktopIndex]
    }
}
