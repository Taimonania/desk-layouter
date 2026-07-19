public struct Assignment: Equatable, Sendable {
    public let bundleIdentifier: String
    public let desktopNumber: Int

    public init(bundleIdentifier: String, desktopNumber: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.desktopNumber = desktopNumber
    }
}

public struct DesktopSnapshot: Equatable, Sendable {
    public let orderedDesktopUUIDs: [String]

    public init(orderedDesktopUUIDs: [String]) {
        self.orderedDesktopUUIDs = orderedDesktopUUIDs
    }
}

public enum AssignmentPlanningError: Error, Equatable {
    case desktopDoesNotExist(Int)
}

public struct AssignmentPlanner: Sendable {
    public init() {}

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
        let desktopIndex = assignment.desktopNumber - 1
        guard desktops.orderedDesktopUUIDs.indices.contains(desktopIndex) else {
            return nil
        }
        return desktops.orderedDesktopUUIDs[desktopIndex]
    }
}
