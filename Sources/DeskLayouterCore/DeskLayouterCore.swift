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

    public func appBindings(
        for assignment: Assignment,
        on desktops: DesktopSnapshot
    ) throws -> [String: String] {
        let desktopIndex = assignment.desktopNumber - 1
        guard desktops.orderedDesktopUUIDs.indices.contains(desktopIndex) else {
            throw AssignmentPlanningError.desktopDoesNotExist(assignment.desktopNumber)
        }

        return [
            assignment.bundleIdentifier: desktops.orderedDesktopUUIDs[desktopIndex],
        ]
    }
}
